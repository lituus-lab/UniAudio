# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The sample representation, and the WAV round trip that pins it.
import std/[unittest, os, math, streams]
import UniAudio

proc tone(rate, channels, frames: int): AudioBuffer =
  ## A different frequency per channel, so a channel swap cannot pass.
  result = initAudioBuffer(rate, channels, frames)
  for index in 0 ..< frames:
    for channel in 0 ..< channels:
      let hz = 440.0 * float(channel + 1)
      result.samples[index * channels + channel] =
        float32(0.5 * sin(2.0 * PI * hz * float(index) / float(rate)))

suite "pcm":
  test "a buffer knows its own shape":
    let buffer = initAudioBuffer(44100, 2, 100)
    check buffer.format.isValid
    check buffer.format.sampleCount == 200
    check buffer.samples.len == 200
    check abs(buffer.format.durationSeconds - 100.0 / 44100.0) < 1e-9

  test "mono averages the channels rather than keeping one":
    var buffer = initAudioBuffer(8000, 2, 2)
    buffer.samples = @[1.0'f32, 0.0'f32, -0.5'f32, 0.5'f32]
    let mono = buffer.toMono()
    check mono.format.channels == 1
    check mono.format.frames == 2
    # A vocal on one side must not vanish because the other side was kept.
    check abs(mono.samples[0] - 0.5'f32) < 1e-6
    check abs(mono.samples[1] - 0.0'f32) < 1e-6

  test "mono of a mono buffer is the same buffer":
    let buffer = tone(8000, 1, 16)
    check buffer.toMono().samples == buffer.samples

  test "resampling halves the frames when it halves the rate":
    let buffer = tone(8000, 1, 800)
    let reduced = buffer.resample(4000)
    check reduced.format.sampleRate == 4000
    check reduced.format.frames == 400
    # A 440 Hz tone stays a 440 Hz tone: compared against the same tone
    # generated at the lower rate, allowing for linear interpolation error.
    let reference = tone(4000, 1, 400)
    var worst = 0.0'f32
    for index in 0 ..< 400:
      worst = max(worst, abs(reduced.samples[index] - reference.samples[index]))
    check worst < 0.05'f32

  test "resampling to the same rate changes nothing":
    let buffer = tone(8000, 2, 32)
    check buffer.resample(8000).samples == buffer.samples

  test "integer conversions land on the ends of the range":
    check abs(fromPcm16(-32768'i16) - -1.0'f32) < 1e-7
    check abs(fromPcm16(0'i16)) < 1e-7
    check abs(fromPcm8(128'u8)) < 1e-7
    check abs(fromPcm8(0'u8) - -1.0'f32) < 1e-7
    # 24-bit, little-endian, sign-extended: 0x800000 is the negative extreme.
    check abs(fromPcm24(0'u8, 0'u8, 0x80'u8) - -1.0'f32) < 1e-7
    check abs(fromPcm24(0'u8, 0'u8, 0'u8)) < 1e-7

suite "wav":
  test "a written file reads back as what was written":
    let path = getTempDir() / "uniaudio_roundtrip.wav"
    let original = tone(44100, 2, 1000)
    writeWaveFile(path, original)
    defer: removeFile(path)
    let reloaded = readWaveFile(path)

    check reloaded.format.sampleRate == 44100
    check reloaded.format.channels == 2
    check reloaded.format.frames == 1000
    # 16-bit quantisation is the only loss allowed: one step is 1/32768.
    var worst = 0.0'f32
    for index in 0 ..< original.samples.len:
      worst = max(worst, abs(reloaded.samples[index] - original.samples[index]))
    check worst < 2.0'f32 / 32768.0'f32

  test "24-bit keeps more of the signal than 16":
    let path16 = getTempDir() / "uniaudio_depth16.wav"
    let path24 = getTempDir() / "uniaudio_depth24.wav"
    let original = tone(44100, 1, 500)
    writeWaveFile(path16, original, 16)
    writeWaveFile(path24, original, 24)
    defer:
      removeFile(path16)
      removeFile(path24)
    proc worstError(path: string): float32 =
      let reloaded = readWaveFile(path)
      for index in 0 ..< original.samples.len:
        result = max(result,
          abs(reloaded.samples[index] - original.samples[index]))
    check worstError(path24) < worstError(path16)

  test "a chunk claiming more than the file holds is refused":
    # The data chunk announces 4 GiB; nothing must be allocated for it.
    let raw = "RIFF" & "\0\0\0\0" & "WAVE" & "fmt " &
      "\16\0\0\0" & "\1\0" & "\1\0" & "\68\172\0\0" & "\136\88\1\0" &
      "\2\0" & "\16\0" & "data" & "\255\255\255\255"
    expect AudioError:
      discard readWave(newStringStream(raw))

  test "a file with no data chunk is refused rather than read as silence":
    let raw = "RIFF" & "\0\0\0\0" & "WAVE" & "fmt " &
      "\16\0\0\0" & "\1\0" & "\1\0" & "\68\172\0\0" & "\136\88\1\0" &
      "\2\0" & "\16\0"
    expect AudioError:
      discard readWave(newStringStream(raw))

  test "something that is not RIFF is refused":
    expect AudioError:
      discard readWave(newStringStream("OggS not a wave at all"))

  test "an unsupported bit depth says so instead of guessing":
    let raw = "RIFF" & "\0\0\0\0" & "WAVE" & "fmt " &
      "\16\0\0\0" & "\1\0" & "\1\0" & "\68\172\0\0" & "\136\88\1\0" &
      "\2\0" & "\12\0" & "data" & "\4\0\0\0" & "\0\0\0\0"
    expect AudioError:
      discard readWave(newStringStream(raw))

suite "the wav writer checks its arguments in either build":
  test "a depth it does not implement is refused, release included":
    let tone = initAudioBuffer(8000, 1, 10)
    for bits in [1, 8, 12, 32]:
      expect AudioError:
        writeWaveFile(getTempDir() / "uniaudio-bad.wav", tone, bits)
