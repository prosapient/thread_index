#!/usr/bin/env python3
"""Encode and decode the Outlook Thread-Index header (MAPI PidTagConversationIndex).

Self-contained reference implementation (stdlib only) mirroring the Elixir
`thread_index` library — see the README in this repository for the full
format write-up.

Key facts the implementation encodes:

* Two header variants exist. Classic (desktop Outlook, base64 "Ac"/"Ad"):
  bytes 0-5 = FILETIME >> 16. Modern (Exchange 2013+/Exchange Online/OWA/
  Graph, base64 "AQH"): byte 0 = 0x01 reserved, bytes 1-5 = FILETIME >> 24.
* Child (reply) blocks are 5 bytes: 1 bit delta code, 31 bits time delta,
  8 bits random. DC=0 stores delta >> 18 (26.2 ms units), DC=1 stores
  delta >> 23 (0.84 s units).
* Deltas are cumulative (relative to the previous block, not the header) and
  are chained from the *classic* read of the header bytes even for modern
  headers — where that read lands around year 1831, forcing DC=1 and
  wrapping the 31-bit value mod 2^31 (~57-year windows). Decoding recovers
  true reply dates by adding back the minimal number of wrap windows needed
  to land at/after the header date.

Usage:
    python thread_index.py decode "AQHWLRNo4NaOjvXU8EODe0ZotrA8B6itzaxf"
    python thread_index.py root --time 2025-01-01T10:00:00Z
    python thread_index.py reply "<base64>" --time 2025-01-01T11:00:00Z
"""

import argparse
import base64
import datetime as dt
import os
import sys

EPOCH_1601 = dt.datetime(1601, 1, 1, tzinfo=dt.timezone.utc)

DC0_SHIFT = 18  # DC=0 stores delta bits 48..18
DC1_SHIFT = 23  # DC=1 stores delta bits 53..23

# Slack (~107s in FILETIME ticks) absorbing delta down-truncation for replies
# composed moments after the original message.
WRAP_SLACK = 1 << 30


def _to_filetime(t: dt.datetime) -> int:
    """100ns ticks since 1601-01-01 00:00:00 UTC."""
    delta = t.astimezone(dt.timezone.utc) - EPOCH_1601
    return (delta.days * 86_400 + delta.seconds) * 10**7 + delta.microseconds * 10


def _from_filetime(ticks: int) -> dt.datetime:
    return EPOCH_1601 + dt.timedelta(microseconds=ticks // 10)


def decode(b64: str) -> dict:
    """Decode a base64 Thread-Index value.

    Returns {"format", "date", "guid", "replies": [{"date", "delta_code", "random"}]}.
    """
    raw = base64.b64decode(b64)
    if len(raw) < 22 or (len(raw) - 22) % 5 != 0:
        raise ValueError(f"invalid length: {len(raw)} bytes (expected 22 + 5n)")

    # Modern headers: reserved 0x01 followed by the FILETIME high byte (0x01
    # until 2057). Under the classic read byte 1 is >= 0xB0 for any date
    # after 1990, so a small byte 1 identifies the modern variant.
    modern = raw[0] == 0x01 and raw[1] < 0x80

    if modern:
        header_ft = int.from_bytes(raw[1:6], "big") << 24
    else:
        header_ft = int.from_bytes(raw[0:6], "big") << 16

    # The anchor all real appenders chain child deltas from: the classic
    # read, regardless of the actual header variant (for modern headers this
    # is ~year 1831 — see module docstring).
    anchor = int.from_bytes(raw[0:6], "big") << 16

    replies = []
    for off in range(22, len(raw), 5):
        block = raw[off : off + 5]
        head = int.from_bytes(block[:4], "big")
        dc = head >> 31
        shift = DC1_SHIFT if dc else DC0_SHIFT
        anchor += (head & 0x7FFF_FFFF) << shift

        # Undo the mod-2^31 truncation: add the minimal number of wrap
        # windows required to land at/after the true header date.
        window = 1 << (31 + shift)
        target = header_ft - WRAP_SLACK
        k = 0 if anchor >= target else -((anchor - target) // window)

        replies.append(
            {
                "date": _from_filetime(anchor + k * window),
                "delta_code": dc,
                "random": block[4],
            }
        )

    return {
        "format": "modern" if modern else "classic",
        "date": _from_filetime(header_ft),
        "guid": raw[6:22].hex(),
        "replies": replies,
    }


def encode_root(time: dt.datetime | None = None, guid: bytes | None = None, fmt: str = "classic") -> str:
    """Encode a 22-byte root conversation index for a new thread."""
    time = time or dt.datetime.now(dt.timezone.utc)
    guid = guid if guid is not None else os.urandom(16)
    if len(guid) != 16:
        raise ValueError("guid must be exactly 16 bytes")

    ft = _to_filetime(time)
    if fmt == "classic":
        header = (ft >> 16).to_bytes(6, "big")
    elif fmt == "modern":
        header = b"\x01" + (ft >> 24).to_bytes(5, "big")
    else:
        raise ValueError("fmt must be 'classic' or 'modern'")

    return base64.b64encode(header + guid).decode()


def encode_reply(parent_b64: str, time: dt.datetime | None = None, random_byte: int | None = None) -> str:
    """Append a reply child block, byte-compatible with Outlook/Exchange."""
    time = time or dt.datetime.now(dt.timezone.utc)
    random_byte = random_byte if random_byte is not None else os.urandom(1)[0]

    raw = base64.b64decode(parent_b64)
    if len(raw) < 22 or (len(raw) - 22) % 5 != 0:
        raise ValueError(f"invalid length: {len(raw)} bytes (expected 22 + 5n)")

    # Advance the cumulative chain from the classic header read.
    anchor = int.from_bytes(raw[0:6], "big") << 16
    for off in range(22, len(raw), 5):
        head = int.from_bytes(raw[off : off + 4], "big")
        shift = DC1_SHIFT if head >> 31 else DC0_SHIFT
        anchor += (head & 0x7FFF_FFFF) << shift

    # Mirror Microsoft's encoders: current time with the low 16 bits masked
    # off, absolute difference; DC=0 only below 2^49 ticks (~1.78 years).
    diff = abs((_to_filetime(time) & ~0xFFFF) - anchor)
    dc, shift = (0, DC0_SHIFT) if diff < 1 << 49 else (1, DC1_SHIFT)
    delta31 = (diff >> shift) & 0x7FFF_FFFF

    block = ((dc << 31 | delta31) << 8 | random_byte).to_bytes(5, "big")
    return base64.b64encode(raw + block).decode()


def _parse_time(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description="Outlook Thread-Index encoder/decoder")
    sub = parser.add_subparsers(dest="command", required=True)

    p_decode = sub.add_parser("decode", help="decode a base64 Thread-Index value")
    p_decode.add_argument("value")

    p_root = sub.add_parser("root", help="encode a new root conversation index")
    p_root.add_argument("--time", type=_parse_time, default=None, help="ISO-8601 timestamp")
    p_root.add_argument("--guid", default=None, help="32 hex chars (16 bytes)")
    p_root.add_argument("--format", choices=["classic", "modern"], default="classic")

    p_reply = sub.add_parser("reply", help="append a reply child block")
    p_reply.add_argument("parent")
    p_reply.add_argument("--time", type=_parse_time, default=None, help="ISO-8601 timestamp")
    p_reply.add_argument("--random", type=int, default=None, help="random byte 0..255")

    args = parser.parse_args()

    if args.command == "decode":
        result = decode(args.value)
        print(f"format:  {result['format']}")
        print(f"date:    {result['date']:%Y-%m-%d %H:%M:%S.%f} UTC")
        print(f"guid:    {result['guid']}")
        for i, reply in enumerate(result["replies"]):
            print(
                f"reply[{i:2d}] {reply['date']:%Y-%m-%d %H:%M:%S.%f} UTC"
                f"  dc={reply['delta_code']} random=0x{reply['random']:02x}"
            )
    elif args.command == "root":
        guid = bytes.fromhex(args.guid) if args.guid else None
        print(encode_root(time=args.time, guid=guid, fmt=args.format))
    elif args.command == "reply":
        print(encode_reply(args.parent, time=args.time, random_byte=args.random))

    return 0


if __name__ == "__main__":
    sys.exit(main())
