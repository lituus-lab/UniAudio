<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: The C ABI, and what it must reach

- Status: Accepted
- Date: 2026-07-15
- Scope: UniAudio

## Decision

The library is pure Nim with a thin C ABI in `src/UniAudio/c_api.nim`, built
`--app:staticlib` / `--app:lib --noMain --mm:arc -d:release` into
`libUniAudio.a` / `libUniAudio.so`. `--mm:arc` gives a foreign caller a
deterministic memory model with no cycle collector; `--noMain` means C never
has to call `NimMain()`.

`include/UniAudio.h` is written by hand and kept level with `c_api.nim`.
`tests/c` links the header against the library, so a renamed or retyped symbol
fails to link rather than at some consumer's site. Generating the header from
the source would remove exactly that check.

No Nim exception crosses the boundary: every entry point returns a status, and
the reason is available from `uaud_last_error`. The status distinguishes a file
that is not there from bytes that are not what they claim, because a caller
acts differently on each.

The Python binding is Cython over the shared library, with an `$ORIGIN` rpath
so the bundled library travels inside the wheel.

## Completeness

The ABI covers the library's whole subject, not the parts a first consumer
happened to ask for. Reachable from C, and from Python:

| capability | entry point |
|---|---|
| name a container without decoding it | `uaud_sniff`, `uaud_container_name` |
| shape of any decodable file | `uaud_probe`, `uaud_wave_probe` |
| the samples themselves | `uaud_decode` |
| samples mixed to mono, or at another rate | `uaud_decode_resampled` |
| write a WAV | `uaud_write_wave` |
| write a WAV of unknown length | `uaud_wave_writer_open`, `uaud_wave_writer_write`, `uaud_wave_writer_frames`, `uaud_wave_writer_close` |
| write a FLAC | `uaud_write_flac` |
| write an ALAC | `uaud_write_alac` |
| tags, whichever scheme the file uses | `uaud_tags_json` |
| fingerprint, and compare two of them | `uaud_fingerprint`, `uaud_similarity`, `uaud_offset_similarity` |
| release what the library allocated | `uaud_free` |

## What stays Nim-side

These are reachable from Nim only, because the ABI covers what they are for by
a better route:

- **Per-format readers** — `readFlac`/`readFlacFile`, `readAlac`/
  `readAlacFile`, `readVorbis`/`readVorbisFile`, `readMp3`/`readMp3File`,
  `readWave`/`readWaveFile`, `readAiff`/`readAiffFile`, and the `sniff`,
  `decode` and `decodes` overloads behind the `*File` ones the ABI calls.
  `uaud_decode` identifies the container from its bytes
  and dispatches. A C caller naming a format it guessed from a file extension
  would be choosing worse information over better. Writing is the other way
  round: a caller does have to say which format it wants, so each writer has
  its own entry point.
- **Container plumbing** — `oggPackets`, `oggStreams`, `readAudioTrack`,
  `sampleData`, `boxes`, `findBox`, `parseMagicCookie`. These exist so the
  codecs above them
  can be written; they describe a file's internal structure, which is not what
  a consumer of decoded audio is after.
- **Per-scheme tag readers** — `readId3v1`, `readId3v2`, `readVorbisComment`,
  `readFlacTags`, `readOggTags`, `readMp4Tags`, `readTags`, and `isEmpty` on
  what they return. `uaud_tags_json` reads
  whichever scheme the file uses; choosing one by hand can only be wrong.
- **Signal-processing helpers** — `fft`, `hannWindow`, `powerSpectrum`,
  `isPowerOfTwo`. Building blocks for the fingerprint, not a DSP library this
  repository offers.
- **Buffer ergonomics** — `initAudioBuffer`, `sampleAt`, `sampleCount`,
  `durationSeconds`, `fromPcm8`/`16`/`24`/`32`. A C caller holds a plain float
  array and its shape, so these have no work left to do; duration is frames
  over rate, and both are already returned. `isValid` states an invariant the
  ABI enforces at its own boundary instead, and `fromPcm16`/`fromPcm24`/
  `fromPcm32` decode integer PCM the decoders have already applied.
- **Bit-level plumbing** — `put`, `putSigned`, `alignByte`, `bitLength`,
  `quantise`. The encoders are written against these; what a consumer wants is
  the file they produce.
- **Stream-taking writer overloads** — `writeWave`, `writeFlac`, `writeAlac`
  and `frameCount` over a `Stream`. C has no `Stream` to pass; the ABI takes a
  path and calls the `*File` overload beside each of them.
- **`iterator boxes`** — C has no iterator protocol to bind to.

A capability added to the library gets an entry point in the same change, or
its reason for not having one in this list.
