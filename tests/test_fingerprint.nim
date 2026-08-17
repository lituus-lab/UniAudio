# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The transform, and the fingerprint built on it.
##
## The FFT is checked against a direct DFT computed here from the definition,
## not against itself. The fingerprint is checked against the property it
## exists for: the same recording, louder or re-encoded, must fingerprint the
## same; a different recording must not.
import std/[unittest, os]
import UniMath/native_float
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

proc directDft(samples: seq[float64]): seq[Complex[float64]] =
  ## The definition, O(n^2), used only to check the fast version.
  let n = samples.len
  result = newSeq[Complex[float64]](n)
  for k in 0 ..< n:
    var re = 0.0
    var im = 0.0
    for t in 0 ..< n:
      let angle = -2.0 * PI * float(k) * float(t) / float(n)
      re += samples[t] * cos(angle)
      im += samples[t] * sin(angle)
    result[k] = complex(re, im)

proc tone(rate, frames: int; hz, amplitude: float): AudioBuffer =
  result = initAudioBuffer(rate, 1, frames)
  for index in 0 ..< frames:
    result.samples[index] =
      float32(amplitude * sin(2.0 * PI * hz * float(index) / float(rate)))

suite "fft":
  test "the fast transform agrees with the definition":
    var samples = newSeq[float64](16)
    for index in 0 ..< 16:
      samples[index] = sin(float(index) * 0.7) + 0.3 * cos(float(index) * 2.1)
    let reference = directDft(samples)
    var values = newSeq[Complex[float64]](16)
    for index in 0 ..< 16:
      values[index] = complex(samples[index])
    fft(values)
    for index in 0 ..< 16:
      check abs(values[index].re - reference[index].re) < 1e-9
      check abs(values[index].im - reference[index].im) < 1e-9

  test "a pure tone puts its energy in one bin":
    # 8 cycles across 64 samples lands exactly on bin 8, with no leakage.
    var frame = newSeq[float32](64)
    for index in 0 ..< 64:
      frame[index] = float32(sin(2.0 * PI * 8.0 * float(index) / 64.0))
    var flat = newSeq[float64](64)
    for index in 0 ..< 64: flat[index] = 1.0
    let spectrum = powerSpectrum(frame, flat)
    var loudest = 0
    for index in 1 ..< spectrum.len:
      if spectrum[index] > spectrum[loudest]: loudest = index
    check loudest == 8

  test "the window tapers to zero at both ends":
    let window = hannWindow(64)
    check abs(window[0]) < 1e-12
    check abs(window[63]) < 1e-12
    check abs(window[32] - 1.0) < 0.01

suite "fingerprint":
  test "a recording fingerprints the same however loud it is":
    # The property the double difference exists for: a uniform gain change
    # moves every band energy by the same factor and cancels out.
    let quiet = tone(44100, 44100, 440.0, 0.1)
    let loud = tone(44100, 44100, 440.0, 0.8)
    let a = fingerprint(quiet)
    let b = fingerprint(loud)
    check a.words.len > 0
    check a.words == b.words

  test "a different recording fingerprints differently":
    let a = fingerprint(tone(44100, 44100, 440.0, 0.5))
    let b = fingerprint(tone(44100, 44100, 1100.0, 0.5))
    check a.words.len == b.words.len
    check a.words != b.words
    check similarity(a, b) < 0.95

  test "a recording is identical to itself":
    let a = fingerprint(tone(44100, 44100, 660.0, 0.5))
    check abs(similarity(a, a) - 1.0) < 1e-12

  test "a recording survives being re-encoded losslessly":
    # The same samples through WAV and through FLAC must agree exactly.
    let fromWave = fingerprint(readWaveFile(Fixtures / "sweep.wav"))
    let fromFlac = fingerprint(readFlacFile(Fixtures / "sweep.flac"))
    check fromWave.words.len > 0
    check fromWave.words == fromFlac.words

  test "something too short to compare yields nothing rather than noise":
    let brief = tone(44100, 4000, 440.0, 0.5)
    let print = fingerprint(brief)
    check print.words.len == 0
    check abs(print.durationSeconds - 4000.0 / 44100.0) < 1e-9

  test "similarity of nothing is zero, not one":
    check similarity(Fingerprint(), Fingerprint()) == 0.0

  test "the duration reported is the recording's own":
    let print = fingerprint(tone(8000, 16000, 440.0, 0.5))
    check abs(print.durationSeconds - 2.0) < 1e-9
