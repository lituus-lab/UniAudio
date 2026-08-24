<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# AGENTS.md — UniAudio

## Build & gates

```bash
nimble install -y
nimble testAll    # Nim debug + release + C ABI
nimble pyTest     # Cython + pytest (needs libUniAudio.so)
nimble coverage   # gcov + lcov -> coverage/ (needs lcov; linux/macOS)
nimble docs       # nimib book + API reference -> pages/ (needs nimib)
nimble bench      # decode + fingerprint timings; not part of the gate
nimble benchReadme # bench, then splice its output into bench/README.md
```

`nimble docs` needs a complete Nim distribution: `--project` builds `dochack`,
which Homebrew's `nim` omits (no `tools/`). choosenim and the CI action ship it.

CI, twelve jobs: `dco` and `spdx`; `test`, `cabi` and `python` on
ubuntu/macOS/Windows; `consume-cabi` and `consume-wheel`, which rebuild against
the published artifacts on a machine with no Nim; `lint`, `docs`, `pages`,
`coverage` and `bench` on ubuntu.

## Conventions

- English comments, terse, describe what is done. No "deprecated".
- **Every routine carries a docstring**, private ones included: what it does,
  and the non-obvious constraint a reader would otherwise have to derive. A
  group of one-line accessors may share a comment above the group, but each
  still says what it selects. `nimble lint` does not check this; review does.
- **Maths comes from `UniMath`, never from `std/math`.**
  `UniMath/native_float` re-exports `std/math`, so the difference is the import
  line. `UniMath/complex` provides `Complex[T]`. An operation missing there is
  added there, not written here. `nimble lint` fails on a `src/` module
  importing `std/math`.
- NimContracts `{.contractual.}` + `require:`/`ensure:`/`body:`, compiled away
  under `-d:release`. A precondition states what a correct caller must not do;
  input that arrives from outside — a bit depth, a channel count — is checked in
  the `body:` and raises, because a precondition disappears in release and would
  leave a release build writing a malformed file in silence. A postcondition
  that restates the body earns nothing and is left out. No exception crosses the
  C ABI: an entry point returns a status and puts the reason in
  `uaud_last_error`. Out-of-range input is rejected with `UAUD_ERR_ARG`, never
  clamped into range.
- A postcondition is cheaper than the body: never re-derives the result by
  calling the function itself.
- C ABI: hand-written `include/UniAudio.h` kept in sync with
  `src/UniAudio/c_api.nim`; `tests/c` links the header against the lib.
  Built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release`.
- C symbols carry the `uaud_` prefix; lib `libUniAudio`; header `UniAudio.h`.
- `book/index.nim` is nimib: its code blocks are compiled and run at docs build,
  so prose that outlives its API breaks the build. `py/notebooks/quickstart.ipynb`
  plays the same role for Python and renders natively on GitHub.
- End every file under `src/` with two blank lines, and more where the compiler
  asks for it. Nim maps a trailing statement one line past EOF, and some final
  constructs — a `{.contractual.}` proc, an `if`/`else` expression as a proc's
  last line — push it one further still; `genhtml` refuses coverage data
  pointing past a file's last line, so `nimble coverage` fails on a source that
  stops too soon, naming the file and the line it wanted. That task passes no
  `--ignore-errors`, so the failure stays visible rather than being suppressed.
  `nimble lint` checks the convention, so it is not left to memory.

## Scope

Audio containers, tags, decoders and the acoustic fingerprint. Which codecs are
implemented is a licensing question before a technical one; ADR-0002 records the
rule. A format this library does not decode is reported with the codec named,
never approximated.

`UniMath` carries the `native_float` façade; arithmetic is never rewritten
here: extend `UniMath`. `UniMovie` supplies ISOBMFF muxing to the ALAC writer,
and brings `UniImage` with it for the box writer they share. Both are needed
to build at all: `alac` imports the muxer at module level, and the umbrella
re-exports `alac`.

## Verification

A writer is checked against the reference *decoder*, never against this
library's own reader — a mistake shared by both would otherwise pass. `flac -t`
decodes the stream and compares it with the MD5 in the STREAMINFO the encoder
wrote, so one command verifies the framing, both CRCs and every sample. For
ALAC the equivalent is `ffmpeg … -f crc`, whose checksum of the decoded samples
must equal its checksum of the WAV that went in; that covers the MP4 tables and
the frame headers as well as the samples. When the tool is absent the round trip
through this library still runs and the reference check does not, so a machine
without `flac` or `ffmpeg` tests less.

A codec is checked against the reference encoder, never against itself:
`tests/fixtures/` holds synthetic WAVs and the FLAC the reference `flac`
encoder made from them, at level 0 (fixed predictors) and level 8 (LPC). The
FFT is checked against a direct DFT written from the definition.

`tagged.*` are one set of values — accents included — written into all four
tagging schemes, so a reader that ignores an encoding byte fails on one of
them. `tagged-v1.mp3` carries only the 128-byte tag.

`*-mp3.mp3` come from `lame`, and each `*-mp3-ref.wav` is that file decoded by
ffmpeg. `src/UniAudio/mp3_tables.nim` was extracted from minimp3's source by
script, rows of a ragged two-dimensional table padded as C would pad them —
never hand-edit it.

`*-vorbis.ogg` come from `oggenc`, and each `*-vorbis-ref.wav` beside one is
that file decoded by ffmpeg. A lossy codec has no lossless reference, so the
test compares two independent decoders and allows one 16-bit step.

`*-alac.m4a` come from `ffmpeg -c:a alac`; `deep24-apple.m4a` from Apple's own
`alacconvert`, remuxed with `ffmpeg -c copy`. Both encoders are kept because
neither reaches every frame shape alone — choose fixtures for the shapes they
contain (partial frame, mid/side pair, shifted bytes, escape frame,
zero-coefficient predictor), not for how they sound.
