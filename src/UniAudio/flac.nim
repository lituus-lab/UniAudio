# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## FLAC, decoded.
##
## Lossless and royalty-free, which is why it is here: the reference
## implementation is BSD, the format is fully specified, and nothing in it is
## encumbered. What a decoder must do is small enough to state — read a frame
## header, reconstruct each channel from a predictor plus Rice-coded
## residuals, then undo the stereo decorrelation.
##
## Everything a frame declares is checked against what the stream actually
## carries: block size, channel count and bit depth all come from a header a
## damaged or hostile file controls.

import std/streams
import contracts
import ./pcm

const
  MaxBlockSize = 65535
    ## The format's own ceiling; a header claiming more is malformed.
  MaxLpcOrder = 32
  MaxFrames* = 1 shl 30
    ## Refuses to accumulate more than a billion frames, whatever a STREAMINFO
    ## block claims.

type
  BitReader = object
    ## MSB-first, as FLAC codes everything.
    data: string
    position: int ## bit offset from the start

  StreamInfo* = object
    ## What the first metadata block declares about the whole stream.
    sampleRate*: int
    channels*: int
    bitsPerSample*: int
    totalSamples*: int64

proc bitsLeft(reader: BitReader): int = reader.data.len * 8 - reader.position

proc readBit(reader: var BitReader): int =
  if reader.position >= reader.data.len * 8:
    raise newException(AudioError, "flac: stream ended inside a frame")
  let byteIndex = reader.position shr 3
  let bitIndex = 7 - (reader.position and 7)
  inc reader.position
  (int(uint8(reader.data[byteIndex])) shr bitIndex) and 1

proc readBits(reader: var BitReader; count: int): uint64 =
  if count < 0 or count > 64:
    raise newException(AudioError, "flac: bit count out of range")
  for _ in 0 ..< count:
    result = (result shl 1) or uint64(reader.readBit())

proc readSigned(reader: var BitReader; count: int): int64 =
  ## Two's complement in `count` bits, sign-extended.
  if count == 0: return 0
  let raw = reader.readBits(count)
  let signBit = 1'u64 shl (count - 1)
  if (raw and signBit) != 0:
    cast[int64](raw or not (signBit * 2 - 1))
  else:
    cast[int64](raw)

proc readUnary(reader: var BitReader): int =
  ## Zeros until a one, as Rice coding writes a quotient.
  while reader.readBit() == 0:
    inc result
    if result > 1_000_000:
      raise newException(AudioError, "flac: unary code is implausibly long")

proc alignToByte(reader: var BitReader) =
  reader.position = (reader.position + 7) and not 7

proc readUtf8Number(reader: var BitReader): int64 =
  ## The frame or sample number, coded like UTF-8 but up to 36 bits.
  let first = int(reader.readBits(8))
  if (first and 0x80) == 0: return int64(first)
  var extra = 0
  var value = 0'i64
  if (first and 0xE0) == 0xC0:
    extra = 1; value = int64(first and 0x1F)
  elif (first and 0xF0) == 0xE0:
    extra = 2; value = int64(first and 0x0F)
  elif (first and 0xF8) == 0xF0:
    extra = 3; value = int64(first and 0x07)
  elif (first and 0xFC) == 0xF8:
    extra = 4; value = int64(first and 0x03)
  elif (first and 0xFE) == 0xFC:
    extra = 5; value = int64(first and 0x01)
  elif first == 0xFE:
    extra = 6; value = 0'i64
  else:
    raise newException(AudioError, "flac: malformed frame number")
  for _ in 0 ..< extra:
    let byteValue = int(reader.readBits(8))
    if (byteValue and 0xC0) != 0x80:
      raise newException(AudioError, "flac: malformed frame number")
    value = (value shl 6) or int64(byteValue and 0x3F)
  value

proc decodeResidual(reader: var BitReader; order, blockSize: int;
                    output: var seq[int64]) =
  ## Rice-coded residuals, in 2^partitionOrder partitions. The first partition
  ## is short by `order` samples, which the predictor already provided.
  let codingMethod = int(reader.readBits(2))
  if codingMethod > 1:
    raise newException(AudioError, "flac: reserved residual coding method")
  let paramBits = if codingMethod == 0: 4 else: 5
  let escape = if codingMethod == 0: 0x0F else: 0x1F
  let partitionOrder = int(reader.readBits(4))
  let partitions = 1 shl partitionOrder
  if partitions > blockSize or
      (blockSize shr partitionOrder) shl partitionOrder != blockSize:
    raise newException(AudioError,
      "flac: block size does not divide into the partition count")
  var index = order
  for partition in 0 ..< partitions:
    let count = (blockSize shr partitionOrder) -
      (if partition == 0: order else: 0)
    if count < 0:
      raise newException(AudioError,
        "flac: first partition is shorter than the predictor order")
    let parameter = int(reader.readBits(paramBits))
    if parameter == escape:
      # An escaped partition stores raw samples of a fixed width instead.
      let width = int(reader.readBits(5))
      for _ in 0 ..< count:
        output[index] = reader.readSigned(width)
        inc index
    else:
      for _ in 0 ..< count:
        let quotient = reader.readUnary()
        let remainder = reader.readBits(parameter)
        let folded = (uint64(quotient) shl parameter) or remainder
        # Zigzag: even values are positive, odd ones negative.
        output[index] = cast[int64]((folded shr 1) xor (0'u64 - (folded and 1)))
        inc index

proc restoreFixed(output: var seq[int64]; order, blockSize: int) =
  ## The fixed polynomial predictors, orders 0 to 4.
  case order
  of 0: discard
  of 1:
    for index in 1 ..< blockSize: output[index] += output[index - 1]
  of 2:
    for index in 2 ..< blockSize:
      output[index] += 2 * output[index - 1] - output[index - 2]
  of 3:
    for index in 3 ..< blockSize:
      output[index] += 3 * output[index - 1] - 3 * output[index - 2] +
        output[index - 3]
  of 4:
    for index in 4 ..< blockSize:
      output[index] += 4 * output[index - 1] - 6 * output[index - 2] +
        4 * output[index - 3] - output[index - 4]
  else:
    raise newException(AudioError, "flac: fixed order above 4")

proc decodeSubframe(reader: var BitReader; blockSize, bitsPerSample: int;
                    output: var seq[int64]) =
  if reader.readBit() != 0:
    raise newException(AudioError, "flac: subframe padding bit is set")
  let kind = int(reader.readBits(6))
  var wasted = 0
  if reader.readBit() == 1:
    wasted = reader.readUnary() + 1
  let bits = bitsPerSample - wasted
  if bits <= 0 or bits > 32:
    raise newException(AudioError, "flac: wasted bits leave nothing to decode")

  if kind == 0: # CONSTANT
    let value = reader.readSigned(bits)
    for index in 0 ..< blockSize: output[index] = value
  elif kind == 1: # VERBATIM
    for index in 0 ..< blockSize: output[index] = reader.readSigned(bits)
  elif kind >= 8 and kind <= 12: # FIXED
    let order = kind - 8
    for index in 0 ..< order: output[index] = reader.readSigned(bits)
    decodeResidual(reader, order, blockSize, output)
    restoreFixed(output, order, blockSize)
  elif kind >= 32: # LPC
    let order = kind - 31
    if order > MaxLpcOrder:
      raise newException(AudioError, "flac: LPC order above 32")
    for index in 0 ..< order: output[index] = reader.readSigned(bits)
    let precision = int(reader.readBits(4)) + 1
    if precision == 16:
      raise newException(AudioError, "flac: invalid LPC precision")
    let shift = int(reader.readSigned(5))
    if shift < 0:
      raise newException(AudioError, "flac: negative LPC shift")
    var coefficients = newSeq[int64](order)
    for index in 0 ..< order:
      coefficients[index] = reader.readSigned(precision)
    decodeResidual(reader, order, blockSize, output)
    for index in order ..< blockSize:
      var sum = 0'i64
      for tap in 0 ..< order:
        sum += coefficients[tap] * output[index - 1 - tap]
      output[index] += sum shr shift
  else:
    raise newException(AudioError, "flac: reserved subframe type " & $kind)

  if wasted > 0:
    for index in 0 ..< blockSize: output[index] = output[index] shl wasted

proc blockSizeFrom(code: int): int =
  ## -1 and -2 mean "read it from the frame", after the coded number.
  case code
  of 0: raise newException(AudioError, "flac: reserved block size")
  of 1: 192
  of 2, 3, 4, 5: 576 shl (code - 2)
  of 6: -1
  of 7: -2
  else: 256 shl (code - 8)

proc sampleSizeFrom(code: int): int =
  ## 0 means "from STREAMINFO"; 3 is reserved.
  case code
  of 1: 8
  of 2: 12
  of 4: 16
  of 5: 20
  of 6: 24
  of 7: 32
  else: 0

proc readStreamInfo(data: string): StreamInfo =
  if data.len < 34:
    raise newException(AudioError, "flac: STREAMINFO is too short")
  var reader = BitReader(data: data)
  discard reader.readBits(16) # minimum block size
  discard reader.readBits(16) # maximum block size
  discard reader.readBits(24) # minimum frame size
  discard reader.readBits(24) # maximum frame size
  result.sampleRate = int(reader.readBits(20))
  result.channels = int(reader.readBits(3)) + 1
  result.bitsPerSample = int(reader.readBits(5)) + 1
  result.totalSamples = cast[int64](reader.readBits(36))
  if result.sampleRate notin 1 .. MaxSampleRate:
    raise newException(AudioError,
      "flac: sample rate out of range: " & $result.sampleRate)
  if result.channels notin 1 .. 8:
    raise newException(AudioError,
      "flac: channel count out of range: " & $result.channels)
  if result.bitsPerSample notin 4 .. 32:
    raise newException(AudioError,
      "flac: bit depth out of range: " & $result.bitsPerSample)

proc decodeFrame(reader: var BitReader; info: StreamInfo;
                 channels: var seq[seq[int64]]): int =
  ## One frame into `channels`, returning its block size.
  let sync = reader.readBits(14)
  if sync != 0b11_1111_1111_1110'u64:
    raise newException(AudioError, "flac: lost frame synchronisation")
  discard reader.readBit() # reserved
  discard reader.readBit() # blocking strategy, not needed to decode
  let blockCode = int(reader.readBits(4))
  let rateCode = int(reader.readBits(4))
  let channelCode = int(reader.readBits(4))
  let sizeCode = int(reader.readBits(3))
  if reader.readBit() != 0:
    raise newException(AudioError, "flac: reserved frame header bit is set")
  discard reader.readUtf8Number()

  var blockSize = blockSizeFrom(blockCode)
  if blockSize == -1: blockSize = int(reader.readBits(8)) + 1
  elif blockSize == -2: blockSize = int(reader.readBits(16)) + 1
  if blockSize < 1 or blockSize > MaxBlockSize:
    raise newException(AudioError, "flac: block size out of range")
  case rateCode
  of 12: discard reader.readBits(8)
  of 13, 14: discard reader.readBits(16)
  of 15: raise newException(AudioError, "flac: invalid sample rate code")
  else: discard
  discard reader.readBits(8) # header CRC-8

  if sizeCode == 3:
    raise newException(AudioError, "flac: reserved sample size code")
  let channelCount = if channelCode < 8: channelCode + 1 else: 2
  if channelCount != info.channels:
    raise newException(AudioError,
      "flac: frame channel count disagrees with STREAMINFO")
  let declared = sampleSizeFrom(sizeCode)
  let bits = if declared == 0: info.bitsPerSample else: declared

  for channel in 0 ..< channelCount:
    if channels[channel].len < blockSize:
      channels[channel].setLen(blockSize)
    # In a decorrelated pair the side channel carries one extra bit.
    let extra = if (channelCode == 8 and channel == 1) or
                   (channelCode == 9 and channel == 0) or
                   (channelCode == 10 and channel == 1): 1 else: 0
    decodeSubframe(reader, blockSize, bits + extra, channels[channel])

  reader.alignToByte()
  discard reader.readBits(16) # frame CRC-16

  # Undo the stereo decorrelation the encoder chose.
  case channelCode
  of 8: # left / side
    for index in 0 ..< blockSize:
      channels[1][index] = channels[0][index] - channels[1][index]
  of 9: # side / right
    for index in 0 ..< blockSize:
      channels[0][index] += channels[1][index]
  of 10: # mid / side
    for index in 0 ..< blockSize:
      let side = channels[1][index]
      var mid = channels[0][index] shl 1
      mid = mid or (side and 1)
      channels[0][index] = (mid + side) shr 1
      channels[1][index] = (mid - side) shr 1
  else: discard
  blockSize

proc readFlac*(data: string): AudioBuffer =
  ## Decode a whole FLAC stream held in memory.
  if data.len < 4 or data[0 ..< 4] != "fLaC":
    raise newException(AudioError, "flac: missing fLaC marker")
  var offset = 4
  var info: StreamInfo
  var haveInfo = false
  while true:
    if offset + 4 > data.len:
      raise newException(AudioError, "flac: metadata block header is truncated")
    let header = uint8(data[offset])
    let last = (header and 0x80) != 0
    let kind = int(header and 0x7F)
    var length = 0
    for index in 1 .. 3:
      length = (length shl 8) or int(uint8(data[offset + index]))
    offset += 4
    if offset + length > data.len:
      raise newException(AudioError, "flac: metadata block is truncated")
    if kind == 0:
      info = readStreamInfo(data[offset ..< offset + length])
      haveInfo = true
    offset += length
    if last: break
  if not haveInfo:
    raise newException(AudioError, "flac: no STREAMINFO block")

  var reader = BitReader(data: data, position: offset * 8)
  var scratch = newSeq[seq[int64]](info.channels)
  var decoded = newSeq[seq[int64]](info.channels)
  var total = 0

  while reader.bitsLeft() >= 32:
    let blockSize = decodeFrame(reader, info, scratch)
    if total + blockSize > MaxFrames:
      raise newException(AudioError, "flac: stream is implausibly long")
    for channel in 0 ..< info.channels:
      let start = decoded[channel].len
      decoded[channel].setLen(start + blockSize)
      for index in 0 ..< blockSize:
        decoded[channel][start + index] = scratch[channel][index]
    total += blockSize
    # A stream may declare its length; stop there rather than reading padding.
    if info.totalSamples > 0 and int64(total) >= info.totalSamples: break

  var frames = total
  if info.totalSamples > 0 and info.totalSamples < int64(total):
    frames = int(info.totalSamples)
  result = initAudioBuffer(info.sampleRate, info.channels, frames)
  let scale = float32(1'i64 shl (info.bitsPerSample - 1))
  for index in 0 ..< frames:
    for channel in 0 ..< info.channels:
      result.samples[index * info.channels + channel] =
        float32(decoded[channel][index]) / scale

proc readFlacFile*(path: string): AudioBuffer {.contractual.} =
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(AudioError, "flac: cannot open " & path)
    defer: stream.close()
    readFlac(stream.readAll())
