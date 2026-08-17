# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## RIFF/WAVE, read and written.
##
## The simplest container this library handles, and the one every other decoder
## is checked against: a WAV of known samples is the fixture that says whether
## a FLAC or MP3 decode landed where it should.
##
## Bounds come first. A chunk header is attacker-controlled, so a declared size
## is checked against a ceiling and against what the file actually holds before
## a single byte is allocated.

import std/[streams, strutils, math]
import contracts
import ./pcm

const
  MaxChunkBytes* = 512 * 1024 * 1024
    ## A chunk larger than this is refused rather than allocated. Half a
    ## gigabyte is hours of CD-quality audio; a header claiming more is either
    ## damaged or hostile.
  FormatPcm = 1
  FormatFloat = 3
  FormatExtensible = 0xFFFE

type WaveFormat = object
  encoding: int
  channels: int
  sampleRate: int
  bitsPerSample: int

proc readU16(stream: Stream): int = int(stream.readUint16())
proc readU32(stream: Stream): int64 = int64(stream.readUint32())

proc parseFmt(stream: Stream; size: int): WaveFormat =
  if size < 16:
    raise newException(AudioError, "wav: fmt chunk is too short")
  result.encoding = stream.readU16()
  result.channels = stream.readU16()
  result.sampleRate = int(stream.readU32())
  discard stream.readU32() # byte rate, derivable
  discard stream.readU16() # block align, derivable
  result.bitsPerSample = stream.readU16()
  # WAVE_FORMAT_EXTENSIBLE keeps the real encoding in a GUID whose first two
  # bytes are the classic tag; the rest of the extension is not needed here.
  if size > 16:
    var skip = size - 16
    if result.encoding == FormatExtensible and skip >= 24:
      discard stream.readU16() # extension size
      discard stream.readU16() # valid bits
      discard stream.readU32() # channel mask
      result.encoding = stream.readU16()
      skip -= 10
    if skip > 0: discard stream.readStr(skip)
  if result.channels notin 1 .. MaxChannels:
    raise newException(AudioError,
      "wav: channel count out of range: " & $result.channels)
  if result.sampleRate notin 1 .. MaxSampleRate:
    raise newException(AudioError,
      "wav: sample rate out of range: " & $result.sampleRate)

proc decodeSamples(raw: string; format: WaveFormat): seq[float32] =
  ## One value per stored sample, in file order, so the caller receives the
  ## interleaving the file has rather than a layout invented here.
  let bytesPerSample = format.bitsPerSample div 8
  let count = raw.len div bytesPerSample
  result = newSeq[float32](count)
  case format.encoding
  of FormatPcm:
    case format.bitsPerSample
    of 8:
      for index in 0 ..< count:
        result[index] = fromPcm8(uint8(raw[index]))
    of 16:
      for index in 0 ..< count:
        let low = uint16(uint8(raw[index * 2]))
        let high = uint16(uint8(raw[index * 2 + 1]))
        result[index] = fromPcm16(cast[int16](low or (high shl 8)))
    of 24:
      for index in 0 ..< count:
        result[index] = fromPcm24(uint8(raw[index * 3]),
          uint8(raw[index * 3 + 1]), uint8(raw[index * 3 + 2]))
    of 32:
      for index in 0 ..< count:
        var value = 0'u32
        for byteIndex in 0 .. 3:
          value = value or
            (uint32(uint8(raw[index * 4 + byteIndex])) shl (8 * byteIndex))
        result[index] = fromPcm32(cast[int32](value))
    else:
      raise newException(AudioError,
        "wav: unsupported bit depth: " & $format.bitsPerSample)
  of FormatFloat:
    case format.bitsPerSample
    of 32:
      for index in 0 ..< count:
        var value = 0'u32
        for byteIndex in 0 .. 3:
          value = value or
            (uint32(uint8(raw[index * 4 + byteIndex])) shl (8 * byteIndex))
        result[index] = cast[float32](value)
    of 64:
      for index in 0 ..< count:
        var value = 0'u64
        for byteIndex in 0 .. 7:
          value = value or
            (uint64(uint8(raw[index * 8 + byteIndex])) shl (8 * byteIndex))
        result[index] = float32(cast[float64](value))
    else:
      raise newException(AudioError,
        "wav: unsupported float width: " & $format.bitsPerSample)
  else:
    raise newException(AudioError,
      "wav: unsupported encoding: " & $format.encoding)

proc readWave*(stream: Stream): AudioBuffer =
  ## Decode a RIFF/WAVE stream. Raises `AudioError` on anything malformed.
  if stream.readStr(4) != "RIFF":
    raise newException(AudioError, "wav: missing RIFF")
  discard stream.readU32() # declared file size, not trusted
  if stream.readStr(4) != "WAVE":
    raise newException(AudioError, "wav: missing WAVE")

  var format: WaveFormat
  var haveFormat = false
  var raw = ""
  var haveData = false
  while not stream.atEnd():
    let header = stream.readStr(8)
    if header.len < 8:
      if header.strip(chars = {'\0'}).len == 0: break # trailing padding
      raise newException(AudioError, "wav: truncated chunk header")
    let id = header[0 ..< 4]
    var size = 0'i64
    for index in 0 .. 3:
      size = size or (int64(uint8(header[4 + index])) shl (8 * index))
    if size < 0 or size > MaxChunkBytes:
      raise newException(AudioError, "wav: chunk exceeds the safety limit")
    case id
    of "fmt ":
      format = parseFmt(stream, int(size))
      haveFormat = true
    of "data":
      raw = stream.readStr(int(size))
      if raw.len < int(size):
        raise newException(AudioError, "wav: data chunk is truncated")
      haveData = true
    else:
      discard stream.readStr(int(size))
    # Chunks are word-aligned: an odd size is followed by one pad byte.
    if (size and 1) == 1 and not stream.atEnd(): discard stream.readStr(1)

  if not haveFormat: raise newException(AudioError, "wav: no fmt chunk")
  if not haveData: raise newException(AudioError, "wav: no data chunk")
  if format.bitsPerSample <= 0 or (format.bitsPerSample mod 8) != 0:
    raise newException(AudioError, "wav: bit depth is not a whole byte count")

  let samples = decodeSamples(raw, format)
  let frames = samples.len div format.channels
  result = initAudioBuffer(format.sampleRate, format.channels, frames)
  # A trailing partial frame is dropped: half a frame is not a frame.
  for index in 0 ..< frames * format.channels:
    result.samples[index] = samples[index]

proc readWaveFile*(path: string): AudioBuffer {.contractual.} =
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "wav: cannot open " & path)
    defer: stream.close()
    readWave(stream)

proc writeU16(stream: Stream; value: int) =
  stream.write(uint8(value and 0xFF))
  stream.write(uint8((value shr 8) and 0xFF))

proc writeU32(stream: Stream; value: int) =
  for shift in [0, 8, 16, 24]:
    stream.write(uint8((value shr shift) and 0xFF))

proc writeWave*(stream: Stream; buffer: AudioBuffer; bitsPerSample = 16)
    {.contractual.} =
  ## Write 16- or 24-bit integer PCM. Samples outside [-1, 1] are clamped
  ## rather than left to wrap, which would turn a loud passage into noise.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  body:
    # Checked in the body, not as a precondition: the depth comes from the
    # caller, and a precondition compiles away under -d:release, which would
    # leave a release build writing a malformed file in silence.
    if bitsPerSample notin [16, 24]:
      raise newException(AudioError,
        "wav: cannot write " & $bitsPerSample & " bits; 16 or 24")
    let bytesPerSample = bitsPerSample div 8
    let dataBytes = buffer.samples.len * bytesPerSample
    stream.write("RIFF")
    stream.writeU32(36 + dataBytes)
    stream.write("WAVE")
    stream.write("fmt ")
    stream.writeU32(16)
    stream.writeU16(FormatPcm)
    stream.writeU16(buffer.format.channels)
    stream.writeU32(buffer.format.sampleRate)
    stream.writeU32(buffer.format.sampleRate * buffer.format.channels *
      bytesPerSample)
    stream.writeU16(buffer.format.channels * bytesPerSample)
    stream.writeU16(bitsPerSample)
    stream.write("data")
    stream.writeU32(dataBytes)
    let peak = float32(1 shl (bitsPerSample - 1))
    for sample in buffer.samples:
      # Round, then clamp. Truncating instead would cost up to a whole step and
      # pull every sample towards silence, because it always rounds inwards.
      var scaled = round(sample * peak)
      if scaled > peak - 1: scaled = peak - 1
      if scaled < -peak: scaled = -peak
      let value = int32(scaled)
      for index in 0 ..< bytesPerSample:
        stream.write(uint8((value shr (8 * index)) and 0xFF))

proc writeWaveFile*(path: string; buffer: AudioBuffer; bitsPerSample = 16)
    {.contractual.} =
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmWrite)
    if stream == nil:
      raise newException(IOError, "wav: cannot write " & path)
    defer: stream.close()
    writeWave(stream, buffer, bitsPerSample)


