# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## AIFF and AIFF-C.
##
## The same IFF chunk structure as RIFF, read big-endian, with one oddity: the
## sample rate is an 80-bit IEEE extended float, a format no current hardware
## uses and no language exposes. It is decoded here by hand from its sign,
## exponent and mantissa.
##
## AIFF-C adds a compression type to the same header. Only the uncompressed
## variants are decoded; a compressed one is reported by name rather than
## approximated.

import std/streams
import UniMath/native_float
import contracts
import ./pcm

# AIFF is big-endian, the opposite of RIFF, which is the only structural
# difference between the two for uncompressed audio. Read a byte at a time so
# the result does not depend on the host's own order.
proc readU16be(stream: Stream): int =
  let high = int(uint8(stream.readChar()))
  let low = int(uint8(stream.readChar()))
  (high shl 8) or low

proc readU32be(stream: Stream): int64 =
  ## Four big-endian bytes, widened to `int64` so a size near 2^32 stays positive.
  result = 0
  for _ in 0 .. 3:
    result = (result shl 8) or int64(uint8(stream.readChar()))

proc readExtended80(stream: Stream): float =
  ## The 80-bit IEEE extended float AIFF keeps its sample rate in: one sign
  ## bit, a 15-bit exponent biased by 16383, and a 64-bit mantissa whose top
  ## bit is explicit rather than implied.
  let hi = stream.readU16be()
  var mantissa = 0'u64
  for _ in 0 .. 7:
    mantissa = (mantissa shl 8) or uint64(uint8(stream.readChar()))
  let sign = if (hi and 0x8000) != 0: -1.0 else: 1.0
  let exponent = hi and 0x7FFF
  if exponent == 0 and mantissa == 0: return 0.0
  if exponent == 0x7FFF:
    raise newException(AudioError, "aiff: sample rate is infinity or NaN")
  let value = sign * float(mantissa) * pow(2.0, float(exponent - 16383 - 63))
  # The caller turns this into an `int`, and a conversion from a float past
  # what an int holds is undefined rather than merely wrong. A rate outside
  # the range any recording uses is refused here, where it is still a float.
  if value < 0.0 or value > float(MaxSampleRate):
    raise newException(AudioError, "aiff: sample rate out of range")
  value

proc decodeSamples(raw: string; bits: int;
                   littleEndian, isFloat: bool): seq[float32] =
  ## One float per stored sample, in file order, so the caller receives the
  ## interleaving the file has rather than a layout invented here.
  ##
  ## `littleEndian` is true for the `sowt` compression type, which is ordinary
  ## PCM with the bytes reversed — AIFF-C's way of storing what a WAV stores.
  ## `isFloat` selects `fl32`. Neither is derivable from `bits`, so both are
  ## passed in from the compression type the file declared.
  let bytesPerSample = bits div 8
  let count = raw.len div bytesPerSample
  result = newSeq[float32](count)
  if isFloat:
    for index in 0 ..< count:
      var value = 0'u32
      for byteIndex in 0 ..< 4:
        let position = if littleEndian: byteIndex else: 3 - byteIndex
        value = value or
          (uint32(uint8(raw[index * 4 + position])) shl (8 * byteIndex))
      result[index] = cast[float32](value)
    return
  case bits
  of 8:
    # AIFF stores 8-bit samples signed, unlike WAV.
    for index in 0 ..< count:
      result[index] = float32(cast[int8](uint8(raw[index]))) / 128.0'f32
  of 16:
    for index in 0 ..< count:
      let a = uint16(uint8(raw[index * 2]))
      let b = uint16(uint8(raw[index * 2 + 1]))
      let raw16 = if littleEndian: a or (b shl 8) else: (a shl 8) or b
      result[index] = fromPcm16(cast[int16](raw16))
  of 24:
    for index in 0 ..< count:
      let base = index * 3
      if littleEndian:
        result[index] = fromPcm24(uint8(raw[base]), uint8(raw[base + 1]),
          uint8(raw[base + 2]))
      else:
        result[index] = fromPcm24(uint8(raw[base + 2]), uint8(raw[base + 1]),
          uint8(raw[base]))
  of 32:
    for index in 0 ..< count:
      var value = 0'u32
      for byteIndex in 0 ..< 4:
        let position = if littleEndian: byteIndex else: 3 - byteIndex
        value = value or
          (uint32(uint8(raw[index * 4 + position])) shl (8 * byteIndex))
      result[index] = fromPcm32(cast[int32](value))
  else:
    raise newException(AudioError, "aiff: unsupported bit depth: " & $bits)

proc readAiff*(stream: Stream): AudioBuffer =
  ## Decode an AIFF or AIFF-C stream. Raises `AudioError` on anything
  ## malformed, or on a compression type this library does not implement.
  if stream.readStr(4) != "FORM":
    raise newException(AudioError, "aiff: missing FORM")
  discard stream.readU32be() # declared size, not trusted
  let kind = stream.readStr(4)
  if kind notin ["AIFF", "AIFC"]:
    raise newException(AudioError, "aiff: not AIFF or AIFC")

  var channels, bits = 0
  var frames = 0
  var sampleRate = 0
  var littleEndian = false
  var isFloat = false
  var haveComm = false
  var raw = ""
  var haveSound = false

  while not stream.atEnd():
    let header = stream.readStr(8)
    if header.len < 8: break # trailing padding
    let id = header[0 ..< 4]
    var size = 0'i64
    for index in 0 .. 3:
      size = (size shl 8) or int64(uint8(header[4 + index]))
    if size < 0 or size > MaxChunkBytes:
      raise newException(AudioError, "aiff: chunk exceeds the safety limit")
    case id
    of "COMM":
      if size < 18:
        raise newException(AudioError, "aiff: COMM chunk is too short")
      channels = stream.readU16be()
      frames = int(stream.readU32be())
      bits = stream.readU16be()
      sampleRate = int(stream.readExtended80())
      var remaining = int(size) - 18
      if kind == "AIFC" and remaining >= 4:
        let compression = stream.readStr(4)
        remaining -= 4
        case compression
        of "NONE", "twos": discard
        of "sowt": littleEndian = true
        of "fl32", "FL32": isFloat = true
        else:
          raise newException(AudioError,
            "aiff: compressed AIFF-C is not decoded: " & compression)
      if remaining > 0: discard stream.readStr(remaining)
      haveComm = true
    of "SSND":
      if size < 8:
        raise newException(AudioError, "aiff: SSND chunk is too short")
      let offset = int(stream.readU32be())
      discard stream.readU32be() # block size, unused for uncompressed data
      let dataBytes = int(size) - 8
      if offset < 0 or offset > dataBytes:
        raise newException(AudioError, "aiff: SSND offset is past the data")
      if offset > 0: discard stream.readStr(offset)
      raw = stream.readStr(dataBytes - offset)
      if raw.len < dataBytes - offset:
        raise newException(AudioError, "aiff: sound data is truncated")
      haveSound = true
    else:
      discard stream.readStr(int(size))
    # IFF chunks are word-aligned, like RIFF.
    if (size and 1) == 1 and not stream.atEnd(): discard stream.readStr(1)

  if not haveComm: raise newException(AudioError, "aiff: no COMM chunk")
  if not haveSound: raise newException(AudioError, "aiff: no SSND chunk")
  if channels notin 1 .. MaxChannels:
    raise newException(AudioError,
      "aiff: channel count out of range: " & $channels)
  if sampleRate notin 1 .. MaxSampleRate:
    raise newException(AudioError,
      "aiff: sample rate out of range: " & $sampleRate)
  if bits <= 0 or (bits mod 8) != 0:
    raise newException(AudioError, "aiff: bit depth is not a whole byte count")
  if isFloat: bits = 32

  let samples = decodeSamples(raw, bits, littleEndian, isFloat)
  let available = samples.len div channels
  # COMM declares the frame count; SSND is what actually arrived. The smaller
  # of the two is what can be read without inventing silence.
  let usable = max(min(frames, available), 0)
  result = initAudioBuffer(sampleRate, channels, usable)
  for index in 0 ..< result.format.sampleCount:
    result.samples[index] = samples[index]

proc readAiffFile*(path: string): AudioBuffer {.contractual.} =
  ## `readAiff` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "aiff: cannot open " & path)
    defer: stream.close()
    readAiff(stream)


