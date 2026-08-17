<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: Module layers, and the one dependency out

- Status: Accepted
- Date: 2026-07-15
- Scope: UniAudio

## Decision

Modules under `src/UniAudio/` are ordered in layers. A module may import its
own layer and any lower one, never a higher one. The order is declared in
`vgraph.cfg` and checked by `nimble checkVGraph`, which fails on a back-edge
rather than leaving it to review.

The order, lowest first:

```
pcm  fft  riff  aiff  flac  isobmff  alac  ogg  vorbis  mp3_tables  mp3
tags  decode  fingerprint  c_api
```

`pcm` is the bottom because every decoder produces the same buffer and little
else is shared between them. `decode` sits above the readers because it
dispatches to them. `c_api` is the top: it consumes the library, and nothing
consumes it.

## Why layers rather than a free graph

A cycle between two decoders would stay invisible until one of them needed to
change. Declaring the order makes the question mechanical — a new import
either fits under its layer or the check fails — instead of a judgement made
once and forgotten.

## The dependency out

`UniMath` is the only external engine this library depends on, for its native
float façade. Arithmetic is extended there, never rewritten here.

That single edge is deliberate. More would mean a consumer of this library
pulls in a stack it has no use for, which is the reason audio decoding lives
in a repository of its own rather than inside a larger one.

`NimContracts` is a build-time dependency for the pre- and postconditions,
which compile away under `-d:release`.
