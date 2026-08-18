# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Writing a WAV as its samples arrive.
##
## The check that matters is that this writer and the batch one produce the
## same bytes: they share `quantise`, and a library with two writers that round
## differently gives two different files from one buffer — which is a trap in
## any round-trip test, and the reason this module exists rather than each
## caller keeping its own.
import std/[unittest, os, streams, math, strutils]
import UniAudio

proc probeBuffer(channels, frames: int): AudioBuffer =
  result = initAudioBuffer(44100, channels, frames)
  for index in 0 ..< result.samples.len:
    result.samples[index] = float32(sin(float(index) * 0.031) * 0.97)
  # The values the two paths could most easily disagree on.
  if result.samples.len > 4:
    result.samples[0] = -1.0'f32
    result.samples[1] = 1.0'f32
    result.samples[2] = -0.99999'f32
    result.samples[3] = 0.30001'f32

suite "the two writers agree":
  test "byte for byte, at every depth and channel count":
    for bits in [16, 24]:
      for channels in [1, 2]:
        let buffer = probeBuffer(channels, 500)
        let batch = getTempDir() / "uniaudio-batch.wav"
        let streamed = getTempDir() / "uniaudio-streamed.wav"
        defer:
          removeFile(batch)
          removeFile(streamed)
        writeWaveFile(batch, buffer, bits)
        var writer = newWaveWriter(streamed, 44100, channels, bits)
        # Ragged blocks, because a caller streams whatever it has.
        var at = 0
        while at < buffer.samples.len:
          let take = min(channels * (1 + (at mod 7)), buffer.samples.len - at)
          writer.writeFrames(buffer.samples.toOpenArray(at, at + take - 1))
          at += take
        writer.close()
        check readFile(batch) == readFile(streamed)

  test "quantise rounds and keeps the format's asymmetry":
    # -1 reaches the most negative code; +1 clamps one short, as the format is.
    check quantise(-1.0'f32, 16) == -32768
    check quantise(1.0'f32, 16) == 32767
    check quantise(0.0'f32, 16) == 0
    # Rounding, not truncation: these two used to land on the same magnitude.
    check quantise(0.30001'f32, 16) == 9831
    check quantise(-0.30001'f32, 16) == -9831
    check quantise(-1.0'f32, 24) == -8388608
    check quantise(1.0'f32, 24) == 8388607

  test "out-of-range samples are clamped, not wrapped":
    check quantise(5.0'f32, 16) == 32767
    check quantise(-5.0'f32, 16) == -32768

suite "what comes back":
  test "a streamed file reads back as what went in":
    let buffer = probeBuffer(2, 1000)
    let path = getTempDir() / "uniaudio-roundtrip.wav"
    defer: removeFile(path)
    var writer = newWaveWriter(path, 44100, 2, 16)
    writer.writeFrames(buffer.samples)
    check writer.frameCount == 1000
    writer.close()

    let back = readWaveFile(path)
    check back.format.sampleRate == 44100
    check back.format.channels == 2
    check back.format.frames == 1000
    for index in 0 ..< buffer.samples.len:
      check abs(back.samples[index] - buffer.samples[index]) < 1.0 / 32000.0

  test "the sizes in the header are patched to the truth":
    let path = getTempDir() / "uniaudio-sizes.wav"
    defer: removeFile(path)
    var writer = newWaveWriter(path, 8000, 1, 16)
    writer.writeFrames(@[0.5'f32, -0.5'f32, 0.25'f32])
    writer.close()
    let raw = readFile(path)
    check raw.len == 44 + 6
    # RIFF size at 4, data size at 40, both little-endian.
    proc leU32(at: int): int =
      for index in countdown(3, 0):
        result = (result shl 8) or int(uint8(raw[at + index]))
    check leU32(4) == raw.len - 8
    check leU32(40) == 6

  test "a file with no frame is still a valid WAV":
    # An empty recording is a fact, not an error.
    let path = getTempDir() / "uniaudio-empty.wav"
    defer: removeFile(path)
    var writer = newWaveWriter(path, 44100, 1, 16)
    writer.close()
    let back = readWaveFile(path)
    check back.format.frames == 0

  test "writing into memory gives the bytes back":
    # The stream is the caller's, so close must not discard it.
    let sink = newStringStream()
    var writer = newWaveWriter(sink, 22050, 1, 16)
    writer.writeFrames(@[0.1'f32, 0.2'f32])
    writer.close()
    check sink.data.len == 44 + 4
    check sink.data[0 .. 3] == "RIFF"

suite "the writer refuses what it cannot write":
  test "a depth it does not implement, in either build":
    for bits in [8, 12, 32, 64]:
      expect AudioError:
        discard newWaveWriter(getTempDir() / "uniaudio-bad.wav", 44100, 1, bits)

  test "a partial frame":
    let path = getTempDir() / "uniaudio-partial.wav"
    defer: removeFile(path)
    var writer = newWaveWriter(path, 44100, 2, 16)
    expect AudioError:
      writer.writeFrames(@[0.1'f32]) # one value for a stereo file
    writer.writeFrames(@[0.1'f32, 0.2'f32])
    writer.close()

  test "a rate or channel count out of range":
    expect AudioError:
      discard newWaveWriter(getTempDir() / "uniaudio-bad.wav", 0, 1, 16)
    expect AudioError:
      discard newWaveWriter(getTempDir() / "uniaudio-bad.wav", 44100, 0, 16)

suite "a writer that is never closed":
  test "leaves a file that does not read back as a WAV":
    # `close` patches the two size fields and flushes; without it the header
    # keeps the sizes it declared provisionally, whatever reached the disk.
    let path = getTempDir() / "uniaudio-abandoned-writer.wav"
    removeFile(path)
    block:
      var writer = newWaveWriter(path, 8000, 1)
      writer.writeFrames(@[0.1'f32, 0.2, 0.3, 0.4])
      check writer.frameCount == 4
    expect AudioError:
      discard readWaveFile(path)
    removeFile(path)
