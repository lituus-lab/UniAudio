<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Security Policy

Report vulnerabilities privately (email the maintainer — see git history), not
via a public issue. Include: description and impact, a minimal reproducer, and
the version from `uaud_version()`.

Nothing has been released yet. The `0.1.x` C ABI is not frozen.

## Surface

Every decoder here parses bytes that came from a file, so a malformed or
hostile file is the surface that matters.

- **A damaged file is reported, not fatal.** The library separates bytes that
  are wrong, which raise `AudioError` and return `UAUD_ERR_FORMAT`, from a file
  that is not there, which returns `UAUD_ERR_IO`. An index out of range or an
  arithmetic overflow would be a bug in this library, and
  `tests/test_robustness.nim` keeps that line enforced: it mutates every
  fixture from fixed seeds and fails on any `Defect`.
- **The C ABI validates its arguments and rejects them.** A null pointer, an
  empty path, a rate or channel count out of range, a bit depth the writer
  named does not implement — each returns `UAUD_ERR_ARG`, with the reason in
  `uaud_last_error()`. The depths differ by format and each entry point states
  its own; nothing is clamped into range, so a caller that passed nonsense is
  told so rather than handed a file it did not ask for.
- **What the ABI cannot check** is a length that disagrees with a pointer. The
  three writers and `uaud_similarity` are told how many values they were
  handed; a caller that lies about that reads past its own buffer, and no
  in-process check can catch it.
- **Allocation ownership is explicit.** Anything the library allocates —
  decoded samples, fingerprint words, the tag JSON — is released with
  `uaud_free`, and with nothing else.
- **No global mutable state**, beyond a per-thread string holding the last
  error. The lookup tables are compile-time constants, so two threads decoding
  two files share nothing.
- **The Python binding checks shapes the ABI cannot** and raises `ValueError`
  before crossing — a sample count that is not a whole number of frames, for
  instance.

## Scope of a report

Memory safety and input handling, as above. Timing is outside it: this library
decodes media and holds no secrets.
