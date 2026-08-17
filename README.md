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

| Codec | Read | Write | Limitations |
|---|:---:|:---:|---|
| WAV (RIFF) | yes | yes | Reads integer PCM at 8, 16, 24 and 32 bits and IEEE float at 32 and 64, including `WAVE_FORMAT_EXTENSIBLE`. Writes 16- or 24-bit integer PCM, clamping samples outside [-1, 1] rather than letting them wrap. |
| AIFF, AIFF-C | yes | no | Uncompressed only — `NONE`, `twos`, `sowt`, `fl32`. Any other AIFF-C compression is refused, named. 8, 16, 24 and 32 bits. |
| FLAC | yes | yes | Reads a native stream, 1 to 8 channels, 4 to 32 bits; FLAC inside Ogg is refused. Writes a native stream at 8, 16 or 24 bits with fixed predictors — the size `flac -0` gives, where `flac -8` is 1.2 to 1.6 times smaller because it fits an LPC model per frame. |
| ALAC | yes | no | Inside MP4. Mono and stereo only; 16, 20, 24 or 32 bits. |
| Vorbis | yes | no | Inside Ogg. Floor type 0 is refused rather than approximated — no encoder has produced it since 2004. Up to 16 channels. |
| MP3 | yes | no | Layer III only; Layers I and II are refused, named. MPEG-1, 2 and 2.5. Encoder padding is trimmed when a LAME or Xing tag records it, and left alone when nothing does. |
| Opus | no | no | Not implemented. No licence stands in the way. An Ogg holding it is refused with the codec named. |
| Speex, Theora | no | no | Not implemented. Recognised by the same check that names Opus, so an Ogg holding one is refused rather than misread as Vorbis. |
| AAC | no | no | Not implemented. It carries an active patent licence, which every consumer of this library would inherit. An MP4 holding it says `mp4a`. |
| WMA | no | no | Not implemented. The format is proprietary and has no published specification to work from. |

Where a format is free to implement, that is why it is here: FLAC and Vorbis are
royalty-free by design, Apple published the ALAC reference decoder under Apache
2.0 with the patent grant that licence carries, and MP3's last patents expired
in 2017.

A file this library cannot decode is reported rather than guessed at, and the
report names what was found. An `.m4a` holding ALAC is read; the same file
holding AAC says `mp4a`. An Ogg holding Opus says so, instead of failing as
though it were broken Vorbis.

## What's inside

- **Sample buffers** — `src/UniAudio/pcm.nim`. One interleaved float32 shape
  every decoder produces, plus channel mixing and rate conversion.
- **Uncompressed containers** — `src/UniAudio/riff.nim`,
  `src/UniAudio/aiff.nim`. WAV is the one format written as well as read.
- **Lossless codecs** — `src/UniAudio/flac.nim`, `src/UniAudio/alac.nim` over
  `src/UniAudio/isobmff.nim`, which finds the coded frames inside an MP4.
- **Lossy codecs** — `src/UniAudio/vorbis.nim` over `src/UniAudio/ogg.nim`,
  and `src/UniAudio/mp3.nim` with its tables in
  `src/UniAudio/mp3_tables.nim`.
- **Tags** — `src/UniAudio/tags.nim`. ID3v1 and v2, Vorbis comments, iTunes
  atoms, read into one shape.
- **Recognition** — `src/UniAudio/fingerprint.nim` over
  `src/UniAudio/fft.nim`: what a recording sounds like, not what its bytes
  are.
- **Dispatch** — `src/UniAudio/decode.nim` names a container from its bytes
  and decodes it; `src/UniAudio/c_api.nim` is the same library in C.

## The Uni* family

UniAudio is layer 3 of `lituus-lab`'s `Uni*` family: a set of Nim libraries,
each with a C ABI and a Python binding, unified by a shared dependency DAG and
documentation and testing conventions. See
[lituus-lab/.github](https://github.com/lituus-lab/.github) for the family's
purpose and philosophy. UniAudio depends on UniMath (layer 2) for its native
float façade, and on nothing else in the family — a single edge, so that an
application decoding audio does not pull in a stack it has no use for.

## Provenance & development

The codecs are ports, not original work, and each names its source in
[NOTICE](NOTICE): ALAC from Apple's reference decoder (Apache 2.0), MP3 from
minimp3 (CC0), Vorbis written against the Xiph specification with `stb_vorbis`
consulted alongside it. FLAC, AIFF and RIFF are written from their published
formats. The fingerprint is Haitsma and Kalker's, cited in the module that
implements it.

Development used LLM/agent assistance extensively, on the terms described
below. One visible consequence: this repo's git history is short and linear,
with commits landing close together — that reflects an agent pass over formats
and reference implementations that have existed for decades, not these codecs
being worked out at that speed from a blank page.

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
ADRs/                         0001 layers, 0002 licence, 0003 C ABI, 0004 conventions
```

## Build

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest
nimble lint
nimble checkVGraph
```

## Benchmarks

`nimble bench` measures what each decoder costs; it is not part of the gate.
`nimble benchReadme` runs it and writes the numbers into
[bench/README.md](bench/README.md), tagged by machine, so nothing there is
retyped by hand. That file also explains why the per-frame cost is the
comparable figure and the realtime multiple is not.

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

## CI

`test`, `cabi` and `python` on ubuntu/macOS/Windows. `consume-cabi` and
`consume-wheel` rebuild against the published artifacts on a machine without
Nim, so what ships is what was tested — the wheel one decodes a fixture from
outside the checkout, because importing the extension would succeed while the
library it needs stayed behind. `coverage`, `docs` and `bench` run on ubuntu;
`bench` is a smoke test, and no number a shared runner produces is recorded.

`dco` blocks PRs missing a `Signed-off-by` trailer; `commitizen` blocks PRs
whose commits or title are not
[Conventional Commits](https://www.conventionalcommits.org/)
(`CONTRIBUTING.md`).

The same gates run locally with pre-commit: `pip install pre-commit && pre-commit install`
(`CONTRIBUTING.md`).

`docs` publishes to GitHub Pages only from a public repo.

## AI-assisted contributions

Assistance from AI/LLM tools is welcome on the same terms as any other
contribution.

- **Accountability.** The human contributor is the author and remains fully
  responsible for the change. The DCO sign-off (`Signed-off-by`) is the
  mechanism: by signing you certify the content is yours or properly licensed
  — this covers AI-assisted work, provided you can stand behind it.
- **No third-party contamination.** Ensure AI output introduces no code from a
  third party without a compatible license and attribution. If an LLM
  reproduced protected material, do not submit it. Every port in this library
  names its source in [NOTICE](NOTICE).
- **Correctness is yours.** The gates (tests, `nimble lint`, conventional
  commits) catch a lot, but you own the result — review and verify what you
  commit.
- **Atomic commits.** Each commit is one logical change. A PR may stack
  several atomic commits (one per element, say) — one monolithic big-bang
  commit is not.
- **Disclosure.** State in the PR whether AI assistance was used (see the PR
  template). It is not a hard requirement — the DCO remains the gate.

## License

Apache-2.0 (`LICENSE`). DCO sign-off on every commit (`CONTRIBUTING.md`).

## Status

Unreleased. Every module above is written and tested; nothing has been
published to a registry, and the C ABI is not frozen.
