<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# UniAudio

Audio containers, tags and decoders, plus an acoustic fingerprint built on
them. Nim, with a C ABI and a Python binding like every other engine in the
family.

Give it a file and it gives you samples, whatever the file turned out to be.

## Codecs

| Codec | Read | Write | Limitations |
|---|:---:|:---:|---|
| WAV (RIFF) | yes | yes | Reads integer PCM at 8, 16, 24 and 32 bits and IEEE float at 32 and 64, including `WAVE_FORMAT_EXTENSIBLE`. Writes 16- or 24-bit integer PCM, clamping samples outside [-1, 1] rather than letting them wrap. |
| AIFF, AIFF-C | yes | no | Uncompressed only — `NONE`, `twos`, `sowt`, `fl32`. Any other AIFF-C compression is refused, named. 8, 16, 24 and 32 bits. |
| FLAC | yes | yes | Reads a native stream, 1 to 8 channels, 4 to 32 bits; FLAC inside Ogg is refused. Writes a native stream at 8, 16 or 24 bits with fixed predictors — the size `flac -0` gives, where `flac -8` is 1.2 to 1.6 times smaller because it fits an LPC model per frame. |
| ALAC | yes | yes | Inside MP4. Mono and stereo only. Reads 16, 20, 24 or 32 bits; writes 16 or 24, with the reference encoder's own parameters — eight predictor taps, its mid/side weight search, and a raw frame wherever coding one would come to more. |
| Vorbis | yes | no | Inside Ogg. Floor type 1 only; type 0 is refused rather than approximated. Up to 16 channels. |
| MP3 | yes | no | Layer III only; Layers I and II are refused, named. MPEG-1, 2 and 2.5. Encoder padding is trimmed when a LAME or Xing tag records it, and left alone when nothing does. |

MP4 and Ogg are containers, and each carries more codecs than the table lists.
Both are read as containers either way: a file holding a codec this build does
not decode is refused with that codec named, so the error says which one it
found instead of reading as a damaged file.

## What's inside

- **Sample buffers** — `src/UniAudio/pcm.nim`. One interleaved float32 shape
  every decoder produces, plus channel mixing and rate conversion.
- **Uncompressed containers** — `src/UniAudio/riff.nim`,
  `src/UniAudio/aiff.nim`. WAV is written as well as read, either from a whole
  buffer or as the samples arrive; AIFF is read.
- **Lossless codecs** — `src/UniAudio/flac.nim`, `src/UniAudio/alac.nim` over
  `src/UniAudio/isobmff.nim`, which finds the coded frames inside an MP4 and
  builds the MP4 the written ones travel in. Both codecs encode as well as
  decode, over the shared bit writer in `src/UniAudio/bitio.nim`.
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
purpose and philosophy. UniAudio depends downward on UniMath (layer 2) for its
native float façade. It also depends sideways, within layer 3, on UniMovie for
the ISOBMFF muxing the ALAC writer needs to put its stream in an MP4, and
through it on UniImage for the box writer those two share. Both sideways edges
are recorded in `vgraph.cfg`, and neither is optional at build time: `alac`
imports the muxer at module level and the umbrella re-exports `alac`, so every
build needs them whether or not a caller ever writes an MP4.

## Provenance & development

The codecs are ports, not original work, and each names its source in
[NOTICE](NOTICE): ALAC from Apple's reference implementation (Apache 2.0), both
its decoder and its encoder; MP3 from minimp3 (CC0); Vorbis written against the
Xiph specification with `stb_vorbis` consulted alongside it. FLAC, AIFF and RIFF
are written from their published formats. The fingerprint is Haitsma and
Kalker's, cited in the module that implements it.

Development used LLM/agent assistance extensively, on the terms described
below.

## Layout

```text
src/UniAudio.nim              umbrella module
src/UniAudio/pcm.nim          sample buffers, channel and rate conversion
src/UniAudio/bitio.nim        writing bits, most significant first
src/UniAudio/riff.nim         RIFF/WAVE read and write
src/UniAudio/aiff.nim         AIFF and AIFF-C
src/UniAudio/flac.nim         FLAC read and write
src/UniAudio/isobmff.nim      MP4 boxes: reading them, and building one
src/UniAudio/alac.nim         Apple Lossless read and write
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

## How the codecs are checked

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

The two lossless encoders are checked the same way round — against a reference
*decoder*, so a mistake shared between this library's own reader and writer
cannot hide:

- FLAC by `flac -t`, which decodes the stream and checks it against the MD5 in
  the STREAMINFO the encoder wrote, covering the framing, both CRCs and every
  sample in one command; and by `flac -d`, whose output is compared with the
  samples that went in.
- ALAC by decoding the written file with ffmpeg and comparing its checksum of
  the samples with ffmpeg's checksum of the original WAV — so the MP4 tables,
  the frame headers, the mid/side weights and the samples are all covered by
  an implementation sharing nothing with this one.

Each needs its tool installed. Without `flac` or `ffmpeg` the round trip through
this library's own reader still runs and the reference check does not, so such a
machine tests less.

`nimble coverage` merges a run of every suite and reports coverage per module.
No module sits below 73% of its lines; the whole library is a little under 90%.
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
