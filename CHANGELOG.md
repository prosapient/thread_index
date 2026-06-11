# Changelog

## v0.1.0 (2026-06-11)

Initial release.

* Decode both conversation index header variants: classic (desktop Outlook,
  `FILETIME >> 16` in bytes 0-5) and modern (Exchange 2013+/Exchange
  Online/OWA/Graph, `0x01` + `FILETIME >> 24` in bytes 1-5).
* Recover true reply dates from child blocks, including Exchange-generated
  blocks whose 31-bit deltas wrap mod 2^31 against the classic misread of
  modern headers.
* Encode root indexes (both formats) and reply child blocks byte-compatible
  with Microsoft's own encoders.
* Self-contained Python reference implementation in `examples/thread_index.py`.
