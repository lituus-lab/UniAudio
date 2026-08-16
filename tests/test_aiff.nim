# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## AIFF and AIFF-C, built byte by byte so the decoder is checked against a
## file this test wrote rather than against itself.
import std/[unittest, math, streams]
import UniAudio

proc beU16(value: int): string =
  result = newString(2)
  result[0] = char((value shr 8) and 0xFF)
  result[1] = char(value and 0xFF)

proc beU32(value: int): string =
  result = newString(4)
  for index in 0 .. 3:
    result[index] = char((value shr (8 * (3 - index))) and 0xFF)

proc extended80(rate: int): string =
  ## The inverse of the decoder's reader: normalise the rate so its top bit
  ## sits at position 63, and bias the exponent by 16383.
  if rate == 0: return newString(10)
  var mantissa = uint64(rate)
  var exponent = 16383 + 63
  while (mantissa and 0x8000_0000_0000_0000'u64) == 0:
    mantissa = mantissa shl 1
    dec exponent
  result = beU16(exponent)
  for index in 0 .. 7:
    result.add char(int((mantissa shr (8 * (7 - index))) and 0xFF'u64))

proc chunk(id, payload: string): string =
  result = id & beU32(payload.len) & payload
  if (payload.len and 1) == 1: result.add '\0'

proc aiff(channels, frames, bits, rate: int; samples: string;
          compression = ""): string =
  var comm = beU16(channels) & beU32(frames) & beU16(bits) & extended80(rate)
  if compression.len > 0: comm.add compression & "\0\0" # name is a pstring
  let form = (if compression.len > 0: "AIFC" else: "AIFF") &
    chunk("COMM", comm) & chunk("SSND", beU32(0) & beU32(0) & samples)
  "FORM" & beU32(form.len) & form

suite "aiff":
  test "16-bit big-endian round trips through the extended sample rate":
    # Two frames, mono: +1/2 full scale then -1/2, stored big-endian.
    let samples = "\x40\x00" & "\xC0\x00"
    let buffer = readAiff(newStringStream(aiff(1, 2, 16, 44100, samples)))
    check buffer.format.sampleRate == 44100
    check buffer.format.channels == 1
    check buffer.format.frames == 2
    check abs(buffer.samples[0] - 0.5'f32) < 1e-4
    check abs(buffer.samples[1] - -0.5'f32) < 1e-4

  test "an unusual rate survives the 80-bit encoding":
    for rate in [8000, 11025, 22050, 44100, 48000, 96000, 192000]:
      let buffer = readAiff(newStringStream(aiff(1, 1, 16, rate, "\x00\x00")))
      check buffer.format.sampleRate == rate

  test "sowt means the samples are little-endian after all":
    # The same +1/2 sample, bytes reversed, declared as sowt.
    let buffer = readAiff(newStringStream(
      aiff(1, 1, 16, 44100, "\x00\x40", "sowt")))
    check abs(buffer.samples[0] - 0.5'f32) < 1e-4

  test "8-bit AIFF is signed, unlike WAV":
    let buffer = readAiff(newStringStream(aiff(1, 2, 8, 8000, "\x40\xC0")))
    check abs(buffer.samples[0] - 0.5'f32) < 1e-2
    check abs(buffer.samples[1] - -0.5'f32) < 1e-2

  test "a declared frame count longer than the data does not invent silence":
    # COMM says 10 frames, SSND carries 2.
    let buffer = readAiff(newStringStream(
      aiff(1, 10, 16, 8000, "\x00\x00\x00\x00")))
    check buffer.format.frames == 2

  test "a compressed variant is named rather than approximated":
    expect AudioError:
      discard readAiff(newStringStream(
        aiff(1, 1, 16, 44100, "\x00\x00", "ima4")))

  test "something that is not FORM is refused":
    expect AudioError:
      discard readAiff(newStringStream("RIFF....WAVE"))

  test "a file with no SSND chunk is refused rather than read as silence":
    let comm = beU16(1) & beU32(4) & beU16(16) & extended80(44100)
    let form = "AIFF" & chunk("COMM", comm)
    expect AudioError:
      discard readAiff(newStringStream("FORM" & beU32(form.len) & form))

  test "a chunk claiming more than the file holds is refused":
    let form = "AIFF" & "SSND" & "\xFF\xFF\xFF\xFF"
    expect AudioError:
      discard readAiff(newStringStream("FORM" & beU32(form.len) & form))
