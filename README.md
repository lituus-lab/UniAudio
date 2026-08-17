<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniAudio

Audio containers, tags and decoders for formats carrying no active patent, plus
an acoustic fingerprint built on them. Nim, with a C ABI and a Python binding
like every other engine in the family.

Give it a file and it gives you samples, whatever the file turned out to be.

## Scope, and what is deliberately absent

A media catalogue needs three things from an audio file: what it is, how long
it is, and something it can be recognised by. None of that requires a licensed
codec — most of what a personal library holds is decodable freely.

| Decoded | Why it is free to implement |
|---|---|
| WAV, AIFF | uncompressed |
| FLAC | royalty-free, reference implementation is BSD |
| ALAC | Apple published the reference decoder under Apache 2.0 |
| Vorbis | royalty-free by design |
| MP3 | last patents expired in 2017 |

**AAC and WMA are not decoded**, and will not be. AAC is under an active
licence for a marginal gain here; WMA is proprietary. Opus and Speex are absent
for a different reason — no licence stands in their way, they simply are not
written yet.

A file this library cannot decode is reported rather than guessed at, and the
report names what was found: an `.m4a` holding ALAC is read, the same file
holding AAC says `mp4a`; an Ogg holding Opus says so instead of failing as
though it were broken Vorbis.

## Layout

```
src/UniAudio.nim              umbrella module
src/UniAudio/pcm.nim          sample buffers, channel and rate conversion
src/UniAudio/riff.nim         RIFF/WAVE read and write
src/UniAudio/aiff.nim         AIFF and AIFF-C
src/UniAudio/flac.nim         FLAC
src/UniAudio/isobmff.nim      MP4 boxes: where the coded frames are
src/UniAudio/alac.nim         Apple Lossless
src/UniAudio/ogg.nim          Ogg pages into packets
src/UniAudio/vorbis.nim       Vorbis I
src/UniAudio/mp3.nim          MPEG-1/2 Layer III
src/UniAudio/tags.nim         ID3, Vorbis comments, MP4 atoms
src/UniAudio/fft.nim          the transform the fingerprint and Vorbis share
src/UniAudio/fingerprint.nim  acoustic fingerprint
src/UniAudio/decode.nim       one entry point over every container
src/UniAudio/c_api.nim        C ABI (uaud_)
include/UniAudio.h            hand-written C header
tests/ tests/c/               Nim and C ABI tests
bench/                        timings, not part of the gate
py/                           Cython binding + pytest + notebook
book/index.nim                nimib book, compiled at docs build
ADRs/                         0001 DAG, 0002 license, 0003 engine&shell, 0004 conventions
```

## Build

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest
nimble lint
nimble checkVGraph
```

`nimble bench` measures what each decoder costs; it is not part of the gate.
See [bench/README.md](bench/README.md) for the numbers and how to read them.

## How the decoders are checked

Never against themselves. Each fixture is a synthetic signal put through a
reference encoder, and the decode is compared with what went in, or with what
an independent decoder makes of the same file:

- FLAC against the reference `flac` encoder, at level 0 and level 8.
- ALAC against ffmpeg's encoder and Apple's own — bit-exact on the six files
  in `tests/fixtures`, which take both encoders because neither reaches every
  frame shape alone.
- Vorbis against libvorbis, MP3 against ffmpeg. Both are lossy, so agreement
  with another decoder is the only definition of correct there is; both land
  within one 16-bit quantisation step.
- The FFT against a transform written straight from its definition, and the
  inverse MDCT against the sum it is supposed to compute.

`nimble coverage` merges a run of every suite and reports coverage per module.
No module sits below 73% of its lines; the whole library is a little under 89%.
The figure is not pinned here to a decimal place, because one would go stale on
the next edit and stop being a measurement.

## Status

Unreleased. Every module above is written and tested; nothing has been
published to a registry, and the C ABI is not frozen.
