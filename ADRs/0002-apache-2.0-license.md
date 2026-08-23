<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0002: Apache License 2.0, and what NOTICE has to record

- Status: Accepted
- Date: 2026-07-15
- Scope: UniAudio

## Decision

Apache-2.0 (`LICENSE`), with DCO sign-off on every commit
(`CONTRIBUTING.md`). Apache-2.0 grants an explicit patent licence, which
matters more here than in most of the family: this library implements codecs,
and a permissive licence with no patent grant would leave a consumer worse
informed than the licence text suggests.

`NimContracts`, a build-time dependency, keeps its upstream MIT.

## What NOTICE records

Every port names its source and licence there, because this library is largely
ports rather than original work:

- `alac.nim` — Apple's reference decoder, Apache-2.0. The patent grant in that
  licence is the basis on which ALAC is implemented here at all.
- `mp3.nim`, `mp3_tables.nim` — minimp3, CC0-1.0. Its tables were extracted by
  script, not retyped.
- `vorbis.nim` — written against the Xiph specification, with `stb_vorbis`
  (public domain or MIT) consulted alongside it.

FLAC, RIFF and AIFF are written from their published formats, so they add no
attribution of their own.

## What the licence decides

A codec is implemented here when its licence leaves a consumer owing nothing.
That question is settled before the technical one, and it is settled in this
record rather than in the code. A consumer who only wanted to read a WAV
inherits the terms of everything else in the library, so the bar is the same for
every format.
