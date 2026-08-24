# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The chroma fingerprint, checked against the property it exists for: a
## recording re-encoded through a lossy codec must still be recognised.
##
## `test_fingerprint.nim` covers the band-energy fingerprint beside it, which
## is exact through a lossless re-encode and drifts through a lossy one. This
## one is the other way round by design, so the two are tested apart.
import std/[os, math, unittest]
import UniAudio

const Fixtures = currentSourcePath().parentDir / "fixtures"

proc tone(rate, frames: int; frequency, amplitude: float): AudioBuffer =
  result = initAudioBuffer(rate, 1, frames)
  for index in 0 ..< frames:
    result.samples[index] = float32(amplitude *
      sin(2.0 * PI * frequency * float(index) / float(rate)))

suite "chroma fingerprint":
  test "a recording is identical to itself":
    let print = chromaFingerprint(readWaveFile(Fixtures / "sweep.wav"))
    check print.words.len > 0
    check abs(chromaSimilarity(print, print) - 1.0) < 1e-12

  test "a lossless re-encode fingerprints identically":
    let fromWave = chromaFingerprint(readWaveFile(Fixtures / "sweep.wav"))
    let fromFlac = chromaFingerprint(readFlacFile(Fixtures / "sweep.flac"))
    check fromWave.words.len > 0
    check fromWave.words == fromFlac.words

  test "a lossy re-encode is still recognised":
    # The reason this module exists. The band-energy fingerprint scores these
    # two around 0.7; staying above 0.95 is what lets a caller keep a strict
    # threshold.
    let original = chromaFingerprint(decodeFile(Fixtures / "sweep.wav"))
    for encoded in ["sweep-mp3.mp3", "sweep-vorbis.ogg", "sweep-alac.m4a"]:
      let copy = chromaFingerprint(decodeFile(Fixtures / encoded))
      check copy.words.len > 0
      check chromaSimilarity(original, copy) > 0.95

  test "a different recording scores well below a re-encode":
    let a = chromaFingerprint(tone(44100, 44100 * 6, 440.0, 0.5))
    let b = chromaFingerprint(tone(44100, 44100 * 6, 660.0, 0.5))
    check a.words.len > 0
    check a.words != b.words
    check chromaSimilarity(a, b) < 0.95

  test "a volume change leaves the fingerprint alone":
    # Each frame is normalised, so a uniform gain divides out.
    let quiet = chromaFingerprint(tone(44100, 44100 * 6, 440.0, 0.1))
    let loud = chromaFingerprint(tone(44100, 44100 * 6, 440.0, 0.8))
    check quiet.words.len > 0
    check quiet.words == loud.words

  test "something too short yields nothing rather than noise":
    # The widest filter spans 16 rows and the smoothing costs four frames, so
    # a recording under about three seconds produces no word at all.
    let brief = chromaFingerprint(tone(44100, 44100 * 2, 440.0, 0.5))
    check brief.words.len == 0
    check abs(brief.durationSeconds - 2.0) < 1e-9

  test "similarity of nothing is zero, not one":
    check chromaSimilarity(ChromaFingerprint(), ChromaFingerprint()) == 0.0

  test "the duration reported is the recording's own":
    let print = chromaFingerprint(tone(8000, 16000, 440.0, 0.5))
    check abs(print.durationSeconds - 2.0) < 1e-9

