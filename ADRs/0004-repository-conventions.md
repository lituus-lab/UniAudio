<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0004: UniAudio conventions

- Status: Accepted
- Date: 2026-07-15
- Scope: layout, naming and gates for this repository

## Layout

```text
UniAudio.nimble               package + tasks
config.nims                   arch-conditional build flags
src/UniAudio.nim              umbrella, re-exports every public submodule
src/UniAudio/pcm.nim          the sample buffer every decoder produces
src/UniAudio/bitio.nim        writing bits, most significant first
src/UniAudio/riff.nim         RIFF/WAVE read and write
src/UniAudio/aiff.nim         AIFF and AIFF-C
src/UniAudio/flac.nim         FLAC read and write
src/UniAudio/isobmff.nim      MP4 boxes: reading them, and building one
src/UniAudio/alac.nim         Apple Lossless read and write
src/UniAudio/ogg.nim          Ogg pages into packets
src/UniAudio/vorbis.nim       Vorbis I
src/UniAudio/mp3_tables.nim   the constant tables Layer III needs
src/UniAudio/mp3.nim          MPEG-1/2 Layer III
src/UniAudio/tags.nim         ID3, Vorbis comments, MP4 atoms
src/UniAudio/fft.nim          the transform the fingerprint and Vorbis share
src/UniAudio/fingerprint.nim  acoustic fingerprint
src/UniAudio/decode.nim       one entry point over every container
src/UniAudio/c_api.nim        C ABI
include/UniAudio.h            hand-written C header
tests/ tests/c/               Nim + C ABI tests
bench/                        timings, not part of the gate
examples/                     Nim + C demos
py/                           Cython binding + pytest + notebook
book/index.nim                nimib book, compiled at docs build
ADRs/                         0001–0004
.github/workflows/ci.yml      3-OS Nim + C ABI + Python
LICENSE NOTICE CONTRIBUTING.md SECURITY.md .gitignore README.md AGENTS.md CLAUDE.md
```

## Naming

- Nim package and umbrella module: `UniAudio`.
- C library `libUniAudio`, header `UniAudio.h`, symbol prefix `uaud_`.
- Python package `uniaudio`.

## Conventions

- NimContracts `{.contractual.}` with `require:`/`ensure:`/`body:`, compiled
  away under `-d:release`. No Nim exception crosses the C ABI: every entry
  point returns a status, with the reason from `uaud_last_error`.
- A postcondition is cheaper than the body; it never re-derives the result.
- English comments, terse, describing what is done.
- Module layers are declared in `vgraph.cfg` and checked by `nimble
  checkVGraph`: a module may import its own layer and any lower one, never a
  higher one. `pcm` is the bottom, `c_api` the top.
- `UniMath` carries the native float façade; arithmetic is extended there,
  never rewritten here. `UniContainer` carries container framing, which is
  what the ALAC writer muxes its stream through.
- A format that is recognised but not decoded is named in the error, never
  approximated. Which codecs are implemented is ADR-0002's subject.
- A decoder is checked against the reference encoder or an independent
  decoder, never against itself.

## CI gates

- `nimble testCi` + `testCiRelease` on ubuntu/macOS/Windows.
- `nimble ctest` on linux/macOS, plus a consumer that compiles the published
  header and static library on a machine with no Nim.
- `nimble pyTest` on linux, plus a consumer that installs the wheel and
  decodes a fixture outside the checkout.
- `nimble lint` and `nimble checkVGraph`.
- `nimble bench` as a smoke test; numbers from a shared runner are not
  recorded.
