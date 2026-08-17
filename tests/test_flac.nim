# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## FLAC, checked against the reference encoder rather than against itself.
##
## Each fixture is a synthetic WAV encoded by the `flac` reference encoder at
## level 0 (fixed predictors) and level 8 (high-order LPC). FLAC is lossless,
## so decoding the FLAC must reproduce the WAV: the only difference allowed is
## the integer-to-float scale, one step apart between the two readers.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

## One step of 16-bit quantisation, the widest the two readers' scales differ.
const Tolerance = 1.0 / 30000.0

proc worstDelta(a, b: AudioBuffer): float =
  for index in 0 ..< a.samples.len:
    result = max(result, abs(float(a.samples[index]) - float(b.samples[index])))

suite "flac against the reference encoder":
  for kind in ["tone16", "stereo16", "silence16", "noise16", "deep24"]:
    for level in ["lvl0", "lvl8"]:
      test kind & " at " & level & " decodes to the samples it was made from":
        let reference = readWaveFile(Fixtures / (kind & ".wav"))
        let decoded = readFlacFile(Fixtures / (kind & "-" & level & ".flac"))
        check decoded.format.sampleRate == reference.format.sampleRate
        check decoded.format.channels == reference.format.channels
        check decoded.format.frames == reference.format.frames
        check worstDelta(decoded, reference) < Tolerance

  test "a stream longer than one block decodes every block":
    # 9000 frames is three of the encoder's 4096-sample blocks.
    let decoded = readFlacFile(Fixtures / "tone16-lvl8.flac")
    check decoded.format.frames == 9000
    # The tail is real signal, not the zeros a truncated decode would leave.
    var tailEnergy = 0.0
    for index in 8000 ..< 9000:
      tailEnergy += abs(float(decoded.samples[index]))
    check tailEnergy > 100.0

  test "silence decodes as silence, not as noise":
    let decoded = readFlacFile(Fixtures / "silence16-lvl8.flac")
    for sample in decoded.samples:
      check sample == 0.0'f32

suite "flac refuses what it cannot decode":
  test "a file without the fLaC marker":
    expect AudioError:
      discard readFlac("OggS and then some padding to pass the length check")

  test "a truncated metadata header":
    expect AudioError:
      discard readFlac("fLaC\x00\x00")

  test "a metadata block claiming more than the file holds":
    # STREAMINFO announcing 0xFFFFFF bytes in a file that has none.
    expect AudioError:
      discard readFlac("fLaC" & "\x80\xFF\xFF\xFF")

  test "a stream with no STREAMINFO block":
    # One last metadata block, type 1 (PADDING), and nothing else.
    expect AudioError:
      discard readFlac("fLaC" & "\x81\x00\x00\x04" & "\x00\x00\x00\x00")

  test "a frame that lost synchronisation":
    let good = readFile(Fixtures / "silence16-lvl8.flac")
    # Corrupt the first frame's sync code, leaving the metadata intact.
    let syncAt = good.find("\xFF\xF8")
    check syncAt > 0
    var broken = good
    broken[syncAt] = '\x00'
    expect AudioError:
      discard readFlac(broken)
