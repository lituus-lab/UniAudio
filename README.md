<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniAudio

Audio containers, tags and decoders for formats carrying no active patent, plus
the acoustic fingerprint built on them. Nim, with a C ABI and a Python binding
like every other engine in the family.

## Scope, and what is deliberately absent

A media catalogue needs three things from an audio file: what it is, how long
it is, and something it can be recognised by. None of that requires a licensed
codec — most of what a personal library holds is decodable freely:

| Decoded here | Why it is free to implement |
|---|---|
| WAV, AIFF | uncompressed |
| MP3 | patents expired in 2017 |
| FLAC | royalty-free, reference implementation is BSD |
| Vorbis, Opus | royalty-free by design |
| ALAC | published by Apple under Apache-2.0 |

**AAC and WMA are not decoded**, and will not be. AAC is under an active
licence for a marginal function; WMA is proprietary. A file this library cannot
decode is reported as such rather than guessed at — an `.m4a` holding ALAC is
read, the same file holding AAC is not.

This is the same line the family draws for video: see the codec amendment in
`UNI_FAMILY_STRUCTURE.md`.

## Layout

```
src/UniAudio.nim            umbrella module
src/UniAudio/pcm.nim        sample buffers, channel and rate conversion
src/UniAudio/riff.nim       RIFF/WAVE read and write
src/UniAudio/c_api.nim      C ABI (uaud_)
include/UniAudio.h          hand-written C header
tests/                      Nim tests
tests/c/                    C ABI test (links the header against the lib)
py/                         Cython binding + pytest
ADRs/                       0001 DAG, 0002 license, 0003 engine&shell, 0004 conventions
```

## Build

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest
nimble lint
nimble checkVGraph
```

## Status

Early. `pcm` and `riff` are complete and tested; the remaining decoders and the
fingerprint are the work in progress. The WAV reader and writer come from
`UniMusicIO`, which now consumes this library rather than carrying its own.
