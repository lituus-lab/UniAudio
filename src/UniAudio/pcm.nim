# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Decoded audio, and what a caller needs in order to read it.
##
## Every decoder here produces the same thing: interleaved 32-bit float samples
## in [-1, 1], with the rate and channel count that give them meaning. Fixing
## one representation at the boundary keeps the decoders independent of each
## other and of whatever consumes them — a fingerprint wants mono at a rate it
## chooses, a waveform wants peaks, and neither should care that one file was
## FLAC and the next WAV.

import UniMath/native_float
import contracts

type
  AudioFormat* = object
    ## What the samples mean. `frames` counts per channel, so a buffer holds
    ## `frames * channels` samples.
    sampleRate*: int
    channels*: int
    frames*: int

  AudioBuffer* = object
    ## Interleaved samples, `format.frames * format.channels` of them.
    format*: AudioFormat
    samples*: seq[float32]

  AudioError* = object of CatchableError
    ## A container this library cannot read, a truncated file, or a codec it
    ## does not implement.

const
  MaxChunkBytes* = 512 * 1024 * 1024
    ## Largest chunk any reader here will allocate for. A header claiming more
    ## is refused rather than believed. Shared so RIFF and AIFF cannot drift
    ## apart, and so a caller naming it gets one constant rather than an
    ## ambiguity between two.
  MaxSampleRate* = 768_000
    ## Past any real recording; a header claiming more is malformed.
  MaxChannels* = 64
    ## More than any format here codes. A header claiming more is malformed.

func isValid*(format: AudioFormat): bool =
  ## Whether the three numbers describe a buffer that can exist: a rate and a
  ## channel count inside this library's ceilings, and a frame count that is not
  ## negative. Zero frames is valid — an empty file decodes to an empty buffer.
  ## Every proc taking an `AudioBuffer` requires this, so a caller building a
  ## format by hand should check it first.
  format.sampleRate in 1 .. MaxSampleRate and
    format.channels in 1 .. MaxChannels and format.frames >= 0

func sampleCount*(format: AudioFormat): int =
  ## How many values a buffer of this shape holds — `frames * channels`, not
  ## `frames`. Confusing the two halves or doubles a duration, which is why the
  ## count has a name of its own.
  format.frames * format.channels

func durationSeconds*(format: AudioFormat): float {.contractual.} =
  ## Playing time in seconds, from the frame count and the rate. Frames count
  ## per channel, so the channel count does not enter it.
  require:
    format.isValid
  body:
    float(format.frames) / float(format.sampleRate)

proc initAudioBuffer*(sampleRate, channels, frames: int): AudioBuffer
    {.contractual.} =
  ## A zeroed buffer of the given shape.
  require:
    sampleRate in 1 .. MaxSampleRate
    channels in 1 .. MaxChannels
    frames >= 0
  ensure:
    result.samples.len == result.format.sampleCount
  body:
    result.format = AudioFormat(sampleRate: sampleRate, channels: channels,
      frames: frames)
    result.samples = newSeq[float32](frames * channels)

func sampleAt*(buffer: AudioBuffer; frame, channel: int): float32 {.inline.} =
  ## One sample, addressed by frame and channel rather than by its index in the
  ## interleaved sequence. Bounds are Nim's: an out-of-range frame or channel
  ## raises `IndexDefect` rather than reading a neighbouring channel.
  buffer.samples[frame * buffer.format.channels + channel]

proc toMono*(buffer: AudioBuffer): AudioBuffer {.contractual.} =
  ## Average the channels.
  ##
  ## Averaged rather than left-channel-only: a fingerprint of a track whose
  ## vocal sits on one side must not depend on which side was kept.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  ensure:
    result.format.channels == 1
    result.format.frames == buffer.format.frames
  body:
    if buffer.format.channels == 1: return buffer
    result = initAudioBuffer(buffer.format.sampleRate, 1, buffer.format.frames)
    let channels = buffer.format.channels
    for index in 0 ..< buffer.format.frames:
      var total = 0.0'f32
      for channel in 0 ..< channels:
        total += buffer.samples[index * channels + channel]
      result.samples[index] = total / float32(channels)

proc resample*(buffer: AudioBuffer; rate: int): AudioBuffer {.contractual.} =
  ## Linear resampling to `rate`.
  ##
  ## Linear rather than windowed sinc: what consumes this is a fingerprint that
  ## reduces the signal to a coarse spectral envelope, where the interpolation
  ## error sits far below the quantisation the fingerprint applies anyway. A
  ## resampler meant for listening would be a different proc, and would say so.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
    rate in 1 .. MaxSampleRate
  ensure:
    result.format.sampleRate == rate
    result.format.channels == buffer.format.channels
  body:
    if rate == buffer.format.sampleRate: return buffer
    let channels = buffer.format.channels
    let ratio = float(buffer.format.sampleRate) / float(rate)
    let frames = if buffer.format.frames == 0: 0
                 else: int(floor(float(buffer.format.frames) / ratio))
    result = initAudioBuffer(rate, channels, max(frames, 0))
    for index in 0 ..< result.format.frames:
      let source = float(index) * ratio
      let left = int(floor(source))
      let right = min(left + 1, buffer.format.frames - 1)
      let weight = float32(source - float(left))
      for channel in 0 ..< channels:
        let a = buffer.samples[left * channels + channel]
        let b = buffer.samples[right * channels + channel]
        result.samples[index * channels + channel] = a + (b - a) * weight

func fromPcm8*(value: uint8): float32 {.inline.} =
  ## 8-bit as WAV stores it: unsigned, 128 is silence.
  (float32(value) - 128.0'f32) / 128.0'f32

func fromPcm16*(value: int16): float32 {.inline.} =
  ## Divided by 32768 so -32768 maps to exactly -1 and nothing exceeds the
  ## range; +32767 falls a step short of +1, which is the asymmetry the format
  ## itself has.
  float32(value) / 32768.0'f32

func fromPcm24*(low, mid, high: uint8): float32 {.inline.} =
  ## Three little-endian bytes, sign-extended from 24 bits.
  var raw = int32(low) or (int32(mid) shl 8) or (int32(high) shl 16)
  if (raw and 0x0080_0000) != 0: raw = raw or cast[int32](0xFF00_0000'u32)
  float32(raw) / 8_388_608.0'f32

func fromPcm32*(value: int32): float32 {.inline.} =
  ## Divided by 2^31, the same asymmetry as the narrower widths. The division
  ## happens at float64 and only then narrows: at float32 the divisor and most
  ## inputs share an exponent range where the quotient would lose low bits.
  float32(float64(value) / 2_147_483_648.0)


