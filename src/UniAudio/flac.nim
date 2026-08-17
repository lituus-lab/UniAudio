# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## FLAC, read and written.
##
## Lossless and royalty-free, which is why it is here: the reference
## implementation is BSD, the format is fully specified, and nothing in it is
## encumbered. What a decoder must do is small enough to state — read a frame
## header, reconstruct each channel from a predictor plus Rice-coded
## residuals, then undo the stereo decorrelation. The encoder is the same steps
## in reverse, with the fixed predictors only: it reaches the size `flac -0`
## gives, not the size its LPC search does.
##
## Everything a frame declares is checked against what the stream actually
## carries: block size, channel count and bit depth all come from a header a
## damaged or hostile file controls.

import std/[streams, md5]
import UniMath/native_float
import contracts
import ./pcm
import ./bitio

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
  ## Bits between the read position and the end of the buffer. Used to decide
  ## whether another frame can start, without reading into a raise.

proc readBit(reader: var BitReader): int =
  ## One bit, most significant first, as FLAC codes everything. Reading past the
  ## end raises `AudioError` rather than returning zeros, so a truncated frame
  ## stops here instead of decoding into silence.
  if reader.position >= reader.data.len * 8:
    raise newException(AudioError, "flac: stream ended inside a frame")
  let byteIndex = reader.position shr 3
  let bitIndex = 7 - (reader.position and 7)
  inc reader.position
  (int(uint8(reader.data[byteIndex])) shr bitIndex) and 1

proc readBits(reader: var BitReader; count: int): uint64 =
  ## The next `count` bits as an unsigned value. `count` is checked in the body
  ## rather than by a precondition: the widths come from the stream, so an
  ## out-of-range one is a malformed file and not a caller's mistake.
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
  ## Skip to the next byte boundary. A frame's CRC-16 covers whole bytes, so the
  ## subframes are padded out to one before it.
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

func fitsIn(value: int64; bits: int): bool =
  ## Whether a reconstructed sample is one: `bits` is the width the frame
  ## declared, and anything wider came from a corrupt stream.
  if bits >= 64: return true
  let limit = 1'i64 shl (bits - 1)
  value >= -limit and value < limit

proc restoreFixed(output: var seq[int64]; order, blockSize, bits: int) =
  ## The fixed polynomial predictors, orders 0 to 4.
  ##
  ## Each sample feeds the next, so a corrupt residual compounds; the width
  ## check stops that before the arithmetic overflows.
  template guard(index: int) =
    if not fitsIn(output[index], bits):
      raise newException(AudioError,
        "flac: reconstructed sample does not fit " & $bits & " bits")
  case order
  of 0: discard
  of 1:
    for index in 1 ..< blockSize:
      output[index] += output[index - 1]
      guard(index)
  of 2:
    for index in 2 ..< blockSize:
      output[index] += 2 * output[index - 1] - output[index - 2]
      guard(index)
  of 3:
    for index in 3 ..< blockSize:
      output[index] += 3 * output[index - 1] - 3 * output[index - 2] +
        output[index - 3]
      guard(index)
  of 4:
    for index in 4 ..< blockSize:
      output[index] += 4 * output[index - 1] - 6 * output[index - 2] +
        4 * output[index - 3] - output[index - 4]
      guard(index)
  else:
    raise newException(AudioError, "flac: fixed order above 4")

proc decodeSubframe(reader: var BitReader; blockSize, bitsPerSample: int;
                    output: var seq[int64]) =
  ## One channel of one frame, in whichever of the four subframe kinds it used:
  ## CONSTANT (a single value), VERBATIM (raw samples), FIXED (a polynomial
  ## predictor of order 0 to 4) or LPC (a transmitted filter).
  ##
  ## "Wasted bits" are low bits every sample in the subframe has as zero — a
  ## 16-bit stream carrying 14 bits of real signal, say. They are coded once and
  ## shifted back on at the end, so the predictor works at the narrower width.
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
    # A predictor needs as many warm-up samples as its order, and they are
    # written into a block sized by the frame header. A block too short for
    # them is a contradiction the file states about itself.
    if order > blockSize:
      raise newException(AudioError, "flac: predictor order above block size")
    for index in 0 ..< order: output[index] = reader.readSigned(bits)
    decodeResidual(reader, order, blockSize, output)
    restoreFixed(output, order, blockSize, bits)
  elif kind >= 32: # LPC
    let order = kind - 31
    if order > MaxLpcOrder:
      raise newException(AudioError, "flac: LPC order above 32")
    if order > blockSize:
      raise newException(AudioError, "flac: LPC order above block size")
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
      # A reconstructed sample is a sample: it fits the declared width. Left
      # unchecked, a corrupt residual feeds back through this recursion and
      # grows without bound until the multiply above overflows.
      if not fitsIn(output[index], bits):
        raise newException(AudioError,
          "flac: reconstructed sample does not fit " & $bits & " bits")
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
  ## The mandatory first metadata block: rate, channel count, bit depth and
  ## total sample count. The block-size and frame-size bounds are read and
  ## dropped — every frame declares its own, and a STREAMINFO that disagrees is
  ## not worth trusting over the frame in hand.
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
  ## `readFlac` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "flac: cannot open " & path)
    defer: stream.close()
    readFlac(stream.readAll())

# --- writing -----------------------------------------------------------------
#
# Fixed polynomial predictors with Rice-coded residuals: what `flac -0` emits.
# No LPC, so the files are larger than the reference encoder's default, and
# exactly as lossless — a decoder cannot tell which predictor family was used.

func crc8(data: openArray[char]): uint8 =
  ## Polynomial 0x07 over the frame header, as FLAC specifies.
  for character in data:
    result = result xor uint8(character)
    for _ in 0 ..< 8:
      result = if (result and 0x80'u8) != 0: (result shl 1) xor 0x07'u8
               else: result shl 1

func crc16(data: openArray[char]): uint16 =
  ## Polynomial 0x8005 over the whole frame, header included.
  for character in data:
    result = result xor (uint16(uint8(character)) shl 8)
    for _ in 0 ..< 8:
      result = if (result and 0x8000'u16) != 0: (result shl 1) xor 0x8005'u16
               else: result shl 1

func rateCode(rate: int): int =
  ## A code for the common rates; 13 means "sixteen explicit bits follow".
  case rate
  of 88200: 1
  of 176400: 2
  of 192000: 3
  of 8000: 4
  of 16000: 5
  of 22050: 6
  of 24000: 7
  of 32000: 8
  of 44100: 9
  of 48000: 10
  of 96000: 11
  else: 13

func depthCode(bits: int): int =
  ## The frame header's 3-bit code for a bit depth. 0 means "the depth is in
  ## STREAMINFO", which is the answer for any width the code cannot name.
  case bits
  of 8: 1
  of 12: 2
  of 16: 4
  of 20: 5
  of 24: 6
  of 32: 7
  else: 0

proc putUtf8Number(writer: var BitWriter; value: int) =
  ## The frame number, in the UTF-8-like coding FLAC borrows.
  if value < 0x80:
    writer.put(uint64(value), 8)
  elif value < 0x800:
    writer.put(0xC0'u64 or uint64(value shr 6), 8)
    writer.put(0x80'u64 or uint64(value and 0x3F), 8)
  elif value < 0x10000:
    writer.put(0xE0'u64 or uint64(value shr 12), 8)
    writer.put(0x80'u64 or uint64((value shr 6) and 0x3F), 8)
    writer.put(0x80'u64 or uint64(value and 0x3F), 8)
  else:
    writer.put(0xF0'u64 or uint64(value shr 18), 8)
    writer.put(0x80'u64 or uint64((value shr 12) and 0x3F), 8)
    writer.put(0x80'u64 or uint64((value shr 6) and 0x3F), 8)
    writer.put(0x80'u64 or uint64(value and 0x3F), 8)

func zigzag(value: int64): uint64 =
  ## Fold a signed residual onto the naturals, small magnitudes first: 0, -1, 1,
  ## -2, 2 become 0, 1, 2, 3, 4. Rice coding costs a value its magnitude, so
  ## interleaving the signs this way keeps a residual near zero cheap whichever
  ## side of zero it falls.
  if value < 0: cast[uint64](-2 * value - 1) else: cast[uint64](2 * value)

func riceBits(values: openArray[int64]; first, last, parameter: int): int =
  ## What one partition costs at this Rice parameter, including its 4-bit
  ## parameter field.
  result = 4
  for index in first ..< last:
    result += int(zigzag(values[index]) shr parameter) + 1 + parameter

func bestParameter(values: openArray[int64]; first, last: int): int =
  ## The cheapest parameter for one partition. 14 is the widest the 4-bit field
  ## can name before it means "escape", which this encoder never emits.
  var best = 0
  var bestCost = high(int)
  for parameter in 0 .. 14:
    let cost = riceBits(values, first, last, parameter)
    if cost < bestCost:
      bestCost = cost
      best = parameter
  best

iterator partitionRanges(blockSize, order, partitionOrder: int):
    tuple[first, last: int] =
  ## The residual slice each partition covers.
  ##
  ## Partitions are counted over the block, not over the residual: the warm-up
  ## samples occupy the first `order` slots of the block, so partition zero
  ## carries that many fewer residuals than the rest.
  let partitions = 1 shl partitionOrder
  let each = blockSize shr partitionOrder
  var at = 0
  for partition in 0 ..< partitions:
    let count = if partition == 0: each - order else: each
    yield (at, at + count)
    at += count

proc fixedResidual(samples: openArray[int64]; order, count: int;
                   into: var seq[int64]) =
  ## The residual of the fixed predictor of that order.
  into.setLen(count - order)
  for index in order ..< count:
    var value = samples[index]
    case order
    of 0: discard
    of 1: value -= samples[index - 1]
    of 2: value -= 2 * samples[index - 1] - samples[index - 2]
    of 3: value -= 3 * samples[index - 1] - 3 * samples[index - 2] +
            samples[index - 3]
    else: value -= 4 * samples[index - 1] - 6 * samples[index - 2] +
            4 * samples[index - 3] - samples[index - 4]
    into[index - order] = value

proc residualCost(values: openArray[int64]; blockSize, order: int;
                  partitionOrder: var int): int =
  ## The cheapest partitioning of one residual, and its bit cost. Splitting
  ## lets a quiet passage and a loud one carry different parameters.
  result = high(int)
  partitionOrder = 0
  for candidate in 0 .. 6:
    let partitions = 1 shl candidate
    if blockSize mod partitions != 0: continue
    if (blockSize shr candidate) <= order: continue
    var total = 2 + 4 # coding method and partition order
    for (first, last) in partitionRanges(blockSize, order, candidate):
      total += riceBits(values, first, last, bestParameter(values, first, last))
    if total < result:
      result = total
      partitionOrder = candidate

proc putResidual(writer: var BitWriter; values: openArray[int64];
                 blockSize, order, partitionOrder: int) =
  ## The residual, Rice-coded in `2^partitionOrder` partitions, each with the
  ## parameter that costs it least. Coding method 0 — 4-bit parameters — because
  ## `bestParameter` never returns one that needs five.
  writer.put(0, 2) # 4-bit Rice parameters
  writer.put(uint64(partitionOrder), 4)
  for (first, last) in partitionRanges(blockSize, order, partitionOrder):
    let parameter = bestParameter(values, first, last)
    writer.put(uint64(parameter), 4)
    for index in first ..< last:
      let folded = zigzag(values[index])
      let quotient = int(folded shr parameter)
      for _ in 0 ..< quotient: writer.put(0, 1)
      writer.put(1, 1)
      if parameter > 0:
        writer.put(folded and ((1'u64 shl parameter) - 1), parameter)

proc putSubframe(writer: var BitWriter; samples: openArray[int64];
                 count, bits: int; scratch: var seq[int64]) =
  ## The cheapest of constant, verbatim, and the five fixed predictors.
  var constant = true
  for index in 1 ..< count:
    if samples[index] != samples[0]:
      constant = false
      break
  if constant:
    writer.put(0, 1)
    writer.put(0, 6) # CONSTANT
    writer.put(0, 1)
    writer.putSigned(samples[0], bits)
    return

  var bestOrder = -1
  var bestCost = count * bits # what VERBATIM would cost
  var bestPartition = 0
  for order in 0 .. 4:
    if count <= order: continue
    fixedResidual(samples, order, count, scratch)
    var partitionOrder = 0
    let cost = order * bits + residualCost(scratch, count, order, partitionOrder)
    if cost < bestCost:
      bestCost = cost
      bestOrder = order
      bestPartition = partitionOrder

  if bestOrder < 0:
    writer.put(0, 1)
    writer.put(1, 6) # VERBATIM
    writer.put(0, 1)
    for index in 0 ..< count: writer.putSigned(samples[index], bits)
    return

  writer.put(0, 1)
  writer.put(uint64(8 + bestOrder), 6) # FIXED
  writer.put(0, 1)
  for index in 0 ..< bestOrder: writer.putSigned(samples[index], bits)
  fixedResidual(samples, bestOrder, count, scratch)
  writer.putResidual(scratch, count, bestOrder, bestPartition)

const WriteBlockSize = 4096

proc writeFlac*(buffer: AudioBuffer; bitsPerSample = 16): string
    {.contractual.} =
  ## Encode to a native FLAC stream, losslessly.
  ##
  ## Fixed predictors only, so the result is larger than the reference
  ## encoder's default and decodes to exactly the same samples: which predictor
  ## family produced a frame is not something a decoder can observe.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  body:
    # Checked in the body, not as a precondition: the depth comes from the
    # caller, and a precondition compiles away under -d:release, which would
    # leave a release build writing a malformed stream in silence.
    if bitsPerSample notin [8, 16, 24]:
      raise newException(AudioError,
        "flac: cannot write " & $bitsPerSample & " bits; 8, 16 or 24")
    if buffer.format.channels notin 1 .. 8:
      raise newException(AudioError,
        "flac: cannot write " & $buffer.format.channels & " channels; 1 to 8")
    let channels = buffer.format.channels
    let frames = buffer.format.frames
    let peak = float32(1'i64 shl (bitsPerSample - 1))
    let limit = int64(1'i64 shl (bitsPerSample - 1))

    # Quantise once: the MD5 in STREAMINFO covers these samples, and it has to
    # be the same integers the frames carry.
    var quantised = newSeq[int64](frames * channels)
    var raw = newStringOfCap(frames * channels * (bitsPerSample div 8))
    for index in 0 ..< frames * channels:
      # Round, then clamp. Truncating instead would cost up to a whole step and
      # pull every sample towards silence, because it always rounds inwards.
      var scaled = round(float32(buffer.samples[index]) * peak)
      if scaled > peak - 1: scaled = peak - 1
      if scaled < -peak: scaled = -peak
      let value = int64(scaled)
      quantised[index] = value
      for byteIndex in 0 ..< bitsPerSample div 8:
        raw.add char(uint8((value shr (8 * byteIndex)) and 0xFF))
    let digest = toMD5(raw)

    var stream = "fLaC"
    var header = BitWriter()
    header.put(1, 1) # last metadata block
    header.put(0, 7) # STREAMINFO
    header.put(34, 24) # its length
    header.put(uint64(min(WriteBlockSize, max(frames, 1))), 16)
    header.put(uint64(min(WriteBlockSize, max(frames, 1))), 16)
    header.put(0, 24) # min frame size, unknown
    header.put(0, 24) # max frame size, unknown
    header.put(uint64(buffer.format.sampleRate), 20)
    header.put(uint64(channels - 1), 3)
    header.put(uint64(bitsPerSample - 1), 5)
    header.put(uint64(frames), 36)
    for index in 0 ..< 16: header.put(uint64(uint8(digest[index])), 8)
    stream.add header.data

    var scratch = newSeq[int64]()
    var channelSamples = newSeq[seq[int64]](channels)
    var frameNumber = 0
    var at = 0
    while at < frames:
      let count = min(WriteBlockSize, frames - at)
      for channel in 0 ..< channels:
        channelSamples[channel].setLen(count)
        for index in 0 ..< count:
          channelSamples[channel][index] =
            quantised[(at + index) * channels + channel]
        for index in 0 ..< count:
          if channelSamples[channel][index] >= limit:
            channelSamples[channel][index] = limit - 1

      var frame = BitWriter()
      frame.put(0b11111111111110'u64, 14) # sync
      frame.put(0, 1) # reserved
      frame.put(0, 1) # fixed blocking strategy
      let sizeCode = if count == WriteBlockSize: 12 else: 7
      frame.put(uint64(sizeCode), 4)
      let rate = rateCode(buffer.format.sampleRate)
      frame.put(uint64(rate), 4)
      frame.put(uint64(channels - 1), 4) # independent channels
      frame.put(uint64(depthCode(bitsPerSample)), 3)
      frame.put(0, 1) # reserved
      frame.putUtf8Number(frameNumber)
      if sizeCode == 7: frame.put(uint64(count - 1), 16)
      if rate == 13: frame.put(uint64(buffer.format.sampleRate), 16)
      frame.put(uint64(crc8(frame.data)), 8)

      for channel in 0 ..< channels:
        frame.putSubframe(channelSamples[channel], count, bitsPerSample,
          scratch)
      frame.alignByte()
      frame.put(uint64(crc16(frame.data)), 16)

      stream.add frame.data
      at += count
      inc frameNumber

    stream

proc writeFlacFile*(path: string; buffer: AudioBuffer; bitsPerSample = 16)
    {.contractual.} =
  ## `writeFlac` to a file, 8, 16 or 24 bits. A depth this writer does not
  ## implement raises `AudioError`; a path that cannot be written raises
  ## `IOError` from `writeFile`.
  require:
    path.len > 0
  body:
    writeFile(path, writeFlac(buffer, bitsPerSample))


