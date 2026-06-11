# ThreadIndex

Encode and decode the Outlook **`Thread-Index`** email header — also known as the MAPI
**`PidTagConversationIndex`** property and the Microsoft Graph **`conversationIndex`**
field — in pure Elixir, with a self-contained [Python reference script](examples/thread_index.py)
included.

This library handles **both** on-the-wire variants of the format (desktop Outlook *and*
Exchange Online/OWA/Graph), recovers **correct reply dates** from child blocks — including
the Exchange-generated blocks that no public parser decoded correctly before — and encodes
reply blocks **byte-compatible** with what Outlook/Exchange themselves produce, so threads
keep grouping and ordering correctly in Outlook.

```elixir
{:ok, index} = ThreadIndex.decode("AQHWLRNo4NaOjvXU8EODe0ZotrA8B6itzaxf")
index.format          #=> :modern
index.date            #=> ~U[2020-05-18 12:54:02.646732Z]
index.guid            #=> <<126, 19, 71, 171, ...>> (16-byte conversation GUID)
hd(index.replies).date #=> ~U[2020-05-18 12:57:39.754393Z]

root  = ThreadIndex.encode_root(time: ~U[2025-01-01 10:00:00Z])
reply = ThreadIndex.encode_reply(root, time: ~U[2025-01-01 11:00:00Z])
```

## Installation

```elixir
def deps do
  [
    {:thread_index, "~> 0.1.0"}
  ]
end
```

Docs: <https://hexdocs.pm/thread_index>. Not an Elixir shop? Copy
[`examples/thread_index.py`](examples/thread_index.py) — a dependency-free Python port of
the same algorithm with a small CLI:

```console
$ python examples/thread_index.py decode "AQHWLRNo4NaOjvXU8EODe0ZotrA8B6itzaxf"
format:  modern
date:    2020-05-18 12:54:02.646732 UTC
guid:    7e1347abc447fa1327db1c16fa410b21
reply[ 0] 2020-05-18 12:57:39.754393 UTC  dc=1 random=0x5f
```

## Why this library exists

If you build email automation against Microsoft Graph or raw SMTP and want your replies to
thread correctly in Outlook, you need to emit a `Thread-Index` header that extends the
parent's conversation index. The format is only partially documented: the official spec
([MS-OXOMSG 2.2.1.3]) describes one header layout while shipping Outlook clients use
another (admitted in the spec's Appendix A footnote `<2>`), the child-block "time delta"
prose contradicts what Microsoft's own encoders do, and Exchange-generated child blocks
(footnote `<3>`: *"Exchange 2013, Exchange 2016, and Exchange 2019 set the Delta Code field
to 1 and do not calculate the Time Delta field based on TimeDiff"*) decode to nonsense
dates with every published parser we could find — including the forensic tools that
documented the format in the first place.

This library is the result of reverse-engineering the actual behavior from Microsoft's own
implementations (the MAPI SDK sample `cindex.c` and the decompiled
`Microsoft.Exchange.Data.Storage.ConversationIndex`) and validating it against published
forensic ground-truth vectors and live Exchange Online threads. The complete findings are
below.

## The format

A conversation index is a 22-byte header block followed by one 5-byte child block per
reply. In the `Thread-Index` MIME header it is base64-encoded; in MAPI/Graph it is the raw
binary (Graph also serves it base64-encoded as `conversationIndex`).

```text
+--------------------------- header (22 bytes) ---------------------------+
| 6 bytes time-derived | 16 bytes conversation GUID                       |
+--------------------------------------------------------------------------+
| 5-byte child block per reply: [1 bit DC | 31 bits delta | 8 bits random] |
+--------------------------------------------------------------------------+
```

### Finding 1 — there are two header layouts in the wild

| | `:classic` | `:modern` |
|---|---|---|
| Producers | desktop Outlook 2007–2019, Exchange 2007–2010 | Exchange 2013+, Exchange Online, OWA, Graph |
| Layout | bytes 0–5 = `FILETIME >> 16` | byte 0 = `0x01`, bytes 1–5 = `FILETIME >> 24` |
| Precision | 6.55 ms | 1.68 s |
| Base64 starts with | `Ac` / `Ad` / `Ae` | `AQ` (typically `AQH`) |
| Documented in | MS-OXOMSG Appendix A footnote `<2>` | MS-OXOMSG 2.2.1.3 main body |

(`FILETIME` = 100 ns ticks since 1601-01-01 UTC. Its top byte is `0x01` for all dates
between 1829 and 2057, which is why the classic layout's first byte *looks like* the
documented "reserved 0x01 byte" — it is actually part of the timestamp.)

Detection: if byte 0 is `0x01` and byte 1 is small (`< 0x80`), it is `:modern`; under the
classic reading byte 1 holds FILETIME bits 55–48, which is ≥ `0xB0` for any date after
1990, so the two layouts cannot collide. Reading a `:modern` header with the classic rule
yields a date around **year 1831** — that misread is the root cause of most broken parsers
(and, it turns out, part of how the format actually works — see finding 3).

### Finding 2 — child deltas are cumulative

Each child block stores a time delta. The spec prose says it is "the difference between the
current time and the time stored in the conversation index header". It is not: both of
Microsoft's own encoders compute each new delta against the **accumulated time of all
previous child blocks** (see `ExtractLastFileTime` in `cindex.c` and `GetLastFileTime` in
Exchange's `ConversationIndex`, both of which run a cumulative sum). The Meridian Discovery
forensic analysis and Joachim Metz's libfmapi documentation observed the same empirically.

The delta encoding itself (from the delta in FILETIME ticks):

| DC bit | Stored value | Unit | Max range |
|---|---|---|---|
| 0 | `delta >> 18`, 31 bits | 26.2 ms | ~1.78 years |
| 1 | `delta >> 23`, 31 bits | 0.84 s | ~57.09 years |

DC is 0 when the delta is below 2⁴⁹ ticks (the spec phrases this as testing the high dword
against `0x00FE0000`). The 5th byte is an implementation-specific uniqueness value (legacy
MAPI docs describe it as 4 random bits + 4 sequence bits; Exchange uses the low byte of the
message timestamp).

### Finding 3 — modern child blocks wrap mod 2³¹ (the previously unsolved part)

Here is the subtle one. When *any* Microsoft implementation appends a child block — desktop
Outlook or Exchange — it computes the chain anchor by reading header bytes 0–5 **the
classic way**, even when the header is `:modern`. For a modern header that read lands
around **year 1831**, so the first reply's delta is a ~195-year value. It doesn't fit in
31 bits after `>> 23`, so it silently truncates mod 2³¹ — wrapping modulo ~57.09 years of
time. That is why:

* every Exchange-generated child block has its first bit set (`0x80`-prefixed bytes) —
  footnote `<3>`'s "always set the Delta Code to 1" is a *consequence* of the 195-year
  virtual delta;
* the first child of a modern thread decodes to a date ~24 years in the future with the
  naive algorithm (195.2 ≡ 24.0 mod 57.09), which is exactly the "2038 nonsense" reported
  in public parser bug trackers;
* subsequent children look normal again, because after the first block the (wrapped)
  cumulative anchor is congruent to the previous reply's true time.

Crucially, the truncation is harmless for Microsoft's encode-only usage — a multiple of
2⁵⁶ ticks vanishes mod 2³¹ after either shift, so every client computes identical bytes
regardless of how it (mis)reads the header. Only *decoders* ever notice.

**Decoding fix:** run the same chain arithmetic (classic-read anchor + cumulative raw
deltas), then for each child add the minimal `k × 2^(31+shift)` ticks needed to land at or
after the true header date (minus ~107 s of slack for truncation effects). This recovers
correct reply dates for both variants with one code path.

**Encoding fix:** none needed — compute the delta against the classic-read cumulative
anchor and mask to 31 bits, exactly like Outlook/Exchange. This library's `encode_reply/2`
reproduces real Exchange Online and desktop Outlook child blocks **byte-for-byte** (it's in
the test suite: strip the last child block of a captured index, re-encode it from the
decoded timestamp, compare).

### What the timestamps mean

Child block timestamps record when each reply was **composed** (the moment the reply draft
was created — "Reply" clicked, or `createReply` called), not when it was sent or delivered.
Expect decoded reply dates to precede the times displayed in Outlook by the composition
duration (typically minutes). Forensic examiners use exactly this gap to estimate how long
a reply took to write. All times are UTC; the encoder's local clock is the source, so
cross-machine skew shows up as-is. Deltas are unsigned — a reply composed "before" the
previous block (clock skew) wraps into a bogus positive delta, in this library exactly as
in Outlook.

## API

* `ThreadIndex.decode(base64)` / `decode!(base64)` / `decode_binary(raw)` →
  `%ThreadIndex{format, date, guid, replies: [%ThreadIndex.Reply{date, delta_code, random}]}`
* `ThreadIndex.encode_root(time:, guid:, format:)` → base64 root index
  (classic by default, `format: :modern` for the Exchange layout)
* `ThreadIndex.encode_reply(parent_base64, time:, random:)` → base64 index with one more
  child block, byte-compatible with Microsoft's encoders

## Validation

The test suite pins:

* the published [Meridian Discovery worked example][meridian] (header + 2 children, exact
  to the published values);
* the published [Metaspike desktop vector][metaspike] (exact to the 100 ns digit);
* the Metaspike **OWA vector whose child block was publicly unsolved** (the thread's own
  tooling errored on it) — decodes to a reply 3 m 37 s after the original message;
* two real Exchange Online (Graph) conversation indexes spanning 14 and 4 replies, with
  byte-identical re-encoding of the final Exchange-generated child block of each.

## Provenance

The research and this prototype were built by **Claude Fable** (Anthropic's Claude
Fable 5 model, working in [Claude Code](https://claude.com/claude-code)): reverse-engineering
the format from Microsoft's own implementations, cross-checking the forensic literature,
deriving the wrap model from live Exchange Online thread indexes, and producing the Elixir
library, the Python port, and the test suite.

An earlier prototype of the same idea was written with OpenAI Codex and failed in ways
that are instructive about this format:

* it assumed a single header layout and read every header with the classic 6-byte
  `FILETIME >> 16` rule, so Exchange/Graph (`AQH...`) threads decoded to header dates
  around **year 1831** and every reply date came out centuries off;
* the child-block wrap behavior (finding 3) went undiagnosed, so even where the header
  was right, the first reply of a modern thread decoded ~24 years into the future;
* when the numbers didn't line up, the attempted fixes introduced ad-hoc shift/"salt"
  constants to nudge the output toward expected dates instead of identifying the
  structural cause — which can never converge, since the discrepancies are modular
  wraps, not offsets.

Fable's rework replaced the guesswork with the findings documented above — the dual
header layout, the cumulative chain anchored at the classic read, and the mod-2³¹ wrap
recovery — each pinned by published ground-truth vectors and byte-identical re-encoding
tests against real Outlook and Exchange output.

## References

* [MS-OXOMSG 2.2.1.3 PidTagConversationIndex][MS-OXOMSG 2.2.1.3] — and its Appendix A
  footnotes `<2>` (Outlook header layout) and `<3>` (Exchange 2013+ child blocks)
* [MAPI: Tracking Conversations](https://learn.microsoft.com/en-us/office/client-developer/outlook/mapi/tracking-conversations)
* Microsoft MAPI SDK sample [`cindex.c`](https://github.com/joncampbell123/windows_sdk_collection/blob/master/win/winnt4/sdk-1996-11-26/mstools/samples/mapi/common/cindex.c)
  (the canonical desktop implementation of `ScCreateConversationIndex`)
* Decompiled `Microsoft.Exchange.Data.Storage.ConversationIndex` (the Exchange implementation)
* [Meridian Discovery: E-mail Conversation Index Analysis for Computer Forensics][meridian]
* [Metaspike community: Thread-Index Header Field][metaspike]
* [Joachim Metz, libfmapi: MAPI definitions](https://github.com/libyal/libfmapi/blob/main/documentation/MAPI%20definitions.asciidoc)

[MS-OXOMSG 2.2.1.3]: https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxomsg/9e994fbb-b839-495f-84e3-2c8c02c7dd9b
[meridian]: https://www.meridiandiscovery.com/how-to/e-mail-conversation-index-metadata-computer-forensics/
[metaspike]: https://community.metaspike.com/t/thread-index-header-field/175

## License

MIT — see [LICENSE](LICENSE).
