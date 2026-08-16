# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Apple Lossless, decoded.
##
## Ported from Apple's reference implementation, which is Apache-2.0 — the
## same licence as this library, so the arithmetic below follows it rather
## than being reconstructed. See NOTICE for the attribution.
##
## Two stages per channel. An adaptive Golomb-Rice decoder turns the bitstream
## into prediction residuals while tracking a running mean that sets each code
## length; then an adaptive FIR predictor rebuilds the samples, moving its own
## coefficients by the sign of each error as it goes, so the filter is never
## transmitted. Stereo arrives as a weighted mid/side pair whose weights the
## frame carries.

import contracts
import ./pcm
import ./isobmff

const
  QBSHIFT = 9
  QB = 1 shl QBSHIFT
  MMULSHIFT = 2
  MDENSHIFT = QBSHIFT - MMULSHIFT - 1
  MOFF = 1 shl (MDENSHIFT - MMULSHIFT)
  BITOFF = 24
  MaxPrefix16 = 9
  MaxPrefix32 = 9
  MaxDatatypeBits16 = 16
  MeanClamp = 0xFFFF
  MaxCoefficients = 32
  MaxFrameLength = 1 shl 20

type
  AlacConfig* = object
    ## The magic cookie an MP4 carries in its `alac` sample entry.
    frameLength*: int
    bitDepth*: int
    pb*, mb*, kb*: int
    channels*: int
    maxRun*: int
    sampleRate*: int

  Reader = object
    ## MSB-first over a padded buffer: the Golomb readers peek 32 bits from
    ## any bit position, so the last bits of a frame need something to read
    ## past.
    data: string
    position: int
    limit: int

proc initReader(data: string): Reader =
  Reader(data: data & "\0\0\0\0\0", position: 0, limit: data.len * 8)

proc peek32(reader: Reader): uint32 =
  let byteIndex = reader.position shr 3
  var word = 0'u32
  for offset in 0 .. 3:
    word = (word shl 8) or uint32(uint8(reader.data[byteIndex + offset]))
  let shift = reader.position and 7
  if shift == 0: word
  else:
    let extra = uint32(uint8(reader.data[byteIndex + 4]))
    (word shl shift) or (extra shr (8 - shift))

proc read(reader: var Reader; count: int): uint32 =
  if count == 0: return 0
  if reader.position + count > reader.limit:
    raise newException(AudioError, "alac: frame ended early")
  result = reader.peek32() shr (32 - count)
  reader.position += count

func lead(value: uint32): int =
  ## Leading zero bits, counted the way the reference does.
  var mask = 0x8000_0000'u32
  while result < 32:
    if (value and mask) != 0: break
    inc result
    mask = mask shr 1

func lg3a(value: int): int = 31 - lead(uint32(value + 3))

proc dynGet(reader: var Reader; m, k: int): int =
  ## The narrow adaptive Golomb reader, used for zero-run lengths.
  var stream = reader.peek32()
  let prefix = lead(not stream)
  if prefix >= MaxPrefix16:
    reader.position += MaxPrefix16
    stream = stream shl MaxPrefix16
    result = int(stream shr (32 - MaxDatatypeBits16))
    reader.position += MaxDatatypeBits16
  else:
    reader.position += prefix + 1
    stream = stream shl (prefix + 1)
    let v = int(stream shr (32 - k))
    reader.position += k
    result = prefix * m + v - 1
    if v < 2:
      result -= v - 1
      dec reader.position

proc dynGet32(reader: var Reader; m, k, maxBits: int): int =
  ## The wide variant: an escaped value is read at the channel's own width.
  var stream = reader.peek32()
  result = lead(not stream)
  if result >= MaxPrefix32:
    reader.position += MaxPrefix32
    result = int(reader.read(maxBits))
  else:
    reader.position += result + 1
    if k != 1:
      stream = stream shl (result + 1)
      let v = int(stream shr (32 - k))
      reader.position += k - 1
      result = result * m
      if v >= 2:
        result += v - 1
        inc reader.position

proc dynDecompress(reader: var Reader; pb, kb, mb0, maxSize, count: int;
                   output: var seq[int]) =
  ## Residuals, with the running mean that chooses each code length. When the
  ## mean collapses the stream switches to coding runs of zeros, which is what
  ## makes silence and near-silence cheap.
  let wb = (1 shl kb) - 1
  var mb = mb0
  var zmode = 0
  var written = 0
  while written < count:
    var k = min(lg3a(mb shr QBSHIFT), kb)
    let m = (1 shl k) - 1
    let n = dynGet32(reader, m, k, maxSize)

    # The least significant bit carries the sign.
    let folded = n + zmode
    let sign = if (folded and 1) != 0: -1 else: 1
    output[written] = ((folded + 1) shr 1) * sign
    inc written

    mb = pb * folded + mb - ((pb * mb) shr QBSHIFT)
    if n > MeanClamp: mb = MeanClamp
    zmode = 0

    if ((mb shl MMULSHIFT) < QB) and written < count:
      zmode = 1
      k = lead(uint32(mb)) - BITOFF + ((mb + MOFF) shr MDENSHIFT)
      let mz = ((1 shl k) - 1) and wb
      let run = dynGet(reader, mz, k)
      if run < 0 or written + run > count:
        raise newException(AudioError, "alac: zero run overruns the frame")
      for _ in 0 ..< run:
        output[written] = 0
        inc written
      if run >= 65535: zmode = 0
      mb = 0

func signOf(value: int): int =
  if value > 0: 1 elif value < 0: -1 else: 0

func signExtend(value, width: int): int =
  ## Sign-extend a `width`-bit value. The shift pair has to happen at 32 bits:
  ## on a 64-bit int it is a no-op, and every negative sample comes back as a
  ## large positive one.
  let shift = 32 - width
  int(cast[int32](uint32(value and 0xFFFF_FFFF) shl uint32(shift)) shr shift)

proc unpredict(residual: seq[int]; output: var seq[int]; count: int;
               coefficients: var seq[int]; active, chanBits, denShift: int) =
  ## The adaptive FIR predictor, undone.
  template clip(value: int): int = signExtend(value, chanBits)

  output[0] = residual[0]
  if active == 0:
    for index in 1 ..< count: output[index] = residual[index]
    return
  if active == 31:
    # A plain running sum: the encoder's simplest predictor.
    var previous = output[0]
    for index in 1 ..< count:
      previous = clip(residual[index] + previous)
      output[index] = previous
    return

  for index in 1 .. min(active, count - 1):
    output[index] = clip(residual[index] + output[index - 1])

  let denHalf = if denShift > 0: 1 shl (denShift - 1) else: 0
  for index in active + 1 ..< count:
    let top = output[index - active - 1]
    var sum = 0
    for tap in 0 ..< active:
      sum += coefficients[tap] * (output[index - 1 - tap] - top)
    let error = residual[index]
    output[index] = clip(error + top + ((sum + denHalf) shr denShift))

    # Nudge each coefficient towards the one that would have helped, stopping
    # once the error has been accounted for. The two directions are not one
    # expression: each shifts a differently-signed operand, and an arithmetic
    # shift of a negative value is not the negation of shifting its magnitude.
    var remaining = error
    if error > 0:
      for tap in countdown(active - 1, 0):
        let difference = top - output[index - 1 - tap]
        let sgn = signOf(difference)
        coefficients[tap] -= sgn
        remaining -= (active - tap) * ((sgn * difference) shr denShift)
        if remaining <= 0: break
    elif error < 0:
      for tap in countdown(active - 1, 0):
        let difference = top - output[index - 1 - tap]
        let sgn = signOf(difference)
        coefficients[tap] += sgn
        remaining -= (active - tap) * ((-sgn * difference) shr denShift)
        if remaining >= 0: break

proc parseMagicCookie*(setup: string): AlacConfig =
  ## The 24-byte cookie, big-endian. An MP4 `alac` box prefixes it with a
  ## four-byte version and flags, skipped when present.
  var offset = 0
  if setup.len == 28: offset = 4
  elif setup.len != 24:
    raise newException(AudioError,
      "alac: magic cookie is " & $setup.len & " bytes, expected 24 or 28")
  proc beU16(at: int): int =
    (int(uint8(setup[offset + at])) shl 8) or int(uint8(setup[offset + at + 1]))
  proc beU32(at: int): int =
    for index in 0 .. 3:
      result = (result shl 8) or int(uint8(setup[offset + at + index]))
  result.frameLength = beU32(0)
  result.bitDepth = int(uint8(setup[offset + 5]))
  result.pb = int(uint8(setup[offset + 6]))
  result.mb = int(uint8(setup[offset + 7]))
  result.kb = int(uint8(setup[offset + 8]))
  result.channels = int(uint8(setup[offset + 9]))
  result.maxRun = beU16(10)
  result.sampleRate = beU32(20)
  if result.frameLength notin 1 .. MaxFrameLength:
    raise newException(AudioError, "alac: implausible frame length")
  if result.channels notin 1 .. 2:
    raise newException(AudioError,
      "alac: " & $result.channels & " channels; only mono and stereo decode")
  if result.bitDepth notin [16, 20, 24, 32]:
    raise newException(AudioError,
      "alac: unsupported bit depth " & $result.bitDepth)

proc decodeFrame(reader: var Reader; config: AlacConfig;
                 channels: var seq[seq[int]]): int =
  ## One frame into `channels`, returning how many samples it held.
  let tag = int(reader.read(3))
  case tag
  of 0, 1, 3: discard # single channel, channel pair, low frequency
  of 7: return 0 # end of frame
  else:
    raise newException(AudioError, "alac: element " & $tag & " is not decoded")
  let stereo = tag == 1
  let present = if stereo: 2 else: 1
  if present > config.channels:
    raise newException(AudioError, "alac: more channels than the cookie says")
  discard reader.read(4) # element instance tag
  discard reader.read(12) # unused
  let header = int(reader.read(4))
  let partial = (header shr 3) != 0
  let bytesShifted = (header shr 1) and 3
  let escaped = (header and 1) != 0
  if bytesShifted == 3:
    raise newException(AudioError, "alac: invalid shift width")
  let count = if partial: int(reader.read(32)) else: config.frameLength
  if count notin 1 .. MaxFrameLength:
    raise newException(AudioError, "alac: implausible sample count")
  for channel in 0 ..< present:
    if channels[channel].len < count: channels[channel].setLen(count)

  if escaped:
    # Stored raw: no prediction, no entropy coding, no mixing. An encoder
    # falls back to this when the coded frame would be larger than the samples.
    for index in 0 ..< count:
      for channel in 0 ..< present:
        channels[channel][index] =
          signExtend(int(reader.read(config.bitDepth)), config.bitDepth)
    return count

  let shiftBits = bytesShifted * 8
  var chanBits = config.bitDepth - shiftBits
  if stereo: inc chanBits

  let mixBits = int(reader.read(8))
  let mixRes = int(cast[int8](uint8(reader.read(8))))

  var modes = newSeq[int](present)
  var denShifts = newSeq[int](present)
  var pbFactors = newSeq[int](present)
  var actives = newSeq[int](present)
  var coefficients = newSeq[seq[int]](present)
  for channel in 0 ..< present:
    let first = int(reader.read(8))
    modes[channel] = first shr 4
    denShifts[channel] = first and 0xF
    let second = int(reader.read(8))
    pbFactors[channel] = second shr 5
    actives[channel] = second and 0x1F
    if actives[channel] > MaxCoefficients:
      raise newException(AudioError, "alac: too many predictor coefficients")
    coefficients[channel] = newSeq[int](actives[channel])
    for tap in 0 ..< actives[channel]:
      coefficients[channel][tap] = int(cast[int16](uint16(reader.read(16))))

  # The wasted low bytes sit in one block ahead of the coded residuals.
  var shifted: seq[int]
  if shiftBits > 0:
    shifted = newSeq[int](count * present)
    for index in 0 ..< count * present:
      shifted[index] = int(reader.read(shiftBits))

  var residual = newSeq[int](count)
  var mixed = newSeq[seq[int]](present)
  for channel in 0 ..< present:
    mixed[channel] = newSeq[int](count)
    dynDecompress(reader, (config.pb * pbFactors[channel]) div 4, config.kb,
      config.mb, chanBits, count, residual)
    if modes[channel] == 0:
      unpredict(residual, mixed[channel], count, coefficients[channel],
        actives[channel], chanBits, denShifts[channel])
    else:
      # A running-sum pass over the residuals first, as the reference does.
      var first = newSeq[int](count)
      var none = newSeq[int](0)
      unpredict(residual, first, count, none, 31, chanBits, 0)
      unpredict(first, mixed[channel], count, coefficients[channel],
        actives[channel], chanBits, denShifts[channel])

  if stereo:
    for index in 0 ..< count:
      let u = mixed[0][index]
      let v = mixed[1][index]
      if mixRes != 0:
        let left = u + v - ((mixRes * v) shr mixBits)
        channels[0][index] = left
        channels[1][index] = left - v
      else:
        channels[0][index] = u
        channels[1][index] = v
  else:
    for index in 0 ..< count:
      channels[0][index] = mixed[0][index]

  if shiftBits > 0:
    for index in 0 ..< count:
      for channel in 0 ..< present:
        channels[channel][index] = (channels[channel][index] shl shiftBits) or
          shifted[index * present + channel]
  count

proc readAlac*(data: string): AudioBuffer =
  ## Decode the ALAC track of an MP4 held in memory.
  let track = readAudioTrack(data)
  if track.entry.format != "alac":
    raise newException(AudioError, "mp4: the audio track is '" &
      track.entry.format & "'; this build decodes only alac")
  let config = parseMagicCookie(track.entry.setup)

  var scratch = newSeq[seq[int]](config.channels)
  var decoded = newSeq[seq[int]](config.channels)
  var total = 0
  for index in 0 ..< track.sizes.len:
    var reader = initReader(sampleData(data, track, index))
    let count = decodeFrame(reader, config, scratch)
    if count == 0: continue
    for channel in 0 ..< config.channels:
      let start = decoded[channel].len
      decoded[channel].setLen(start + count)
      for sample in 0 ..< count:
        decoded[channel][start + sample] = scratch[channel][sample]
    total += count

  let rate = if config.sampleRate in 1 .. MaxSampleRate: config.sampleRate
             else: track.entry.sampleRate
  result = initAudioBuffer(rate, config.channels, total)
  let scale = float32(1'i64 shl (config.bitDepth - 1))
  for index in 0 ..< total:
    for channel in 0 ..< config.channels:
      result.samples[index * config.channels + channel] =
        float32(decoded[channel][index]) / scale

proc readAlacFile*(path: string): AudioBuffer {.contractual.} =
  require:
    path.len > 0
  body:
    readAlac(readFile(path))
