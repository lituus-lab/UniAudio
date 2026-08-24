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

```text
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

`UniMath` carries the native float façade. Arithmetic is extended there, never
rewritten here.

`UniContainer` carries container framing, and the ALAC writer muxes through it
rather than assembling an MP4 a second time here — an `.m4a` is an ISO base
media file, and how one is shaped is not an audio question.

Both edges point downward, which is the property this repository has to keep:
each is a capability it would otherwise duplicate, not a stack it drags in for
its own sake. Neither is optional, though: `alac` imports the muxer at module
level and the umbrella re-exports `alac`, so a build that only ever decodes
still links both.

`NimContracts` is a build-time dependency for the pre- and postconditions,
which compile away under `-d:release`.
