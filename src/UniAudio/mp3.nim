# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## MPEG-1 and MPEG-2 Layer III, decoded.
##
## Ported from minimp3 (CC0 1.0, lieff), named in NOTICE. Its tables are in
## `mp3_tables`.
##
## The last MP3 patents expired in 2017, which is what puts the format inside
## this library rather than behind a backend the application supplies.
##
## A frame carries two granules of 576 spectral lines per channel, Huffman
## coded against a scalefactor envelope. Decoding runs the encoder backwards:
## read the scalefactors, read the spectrum, undo the stereo folding, undo the
## aliasing the filterbank introduced, inverse MDCT, then a polyphase synthesis
## filter that turns 32 subbands back into samples.
##
## Layers I and II are refused. They share a frame header with Layer III and
## nothing else, and no encoder in use produces them.

import ./pcm
import ./mp3_tables

const
  MaxBitReservoir = 511
  MaxFramePayload = 2304
  HeaderBytes = 4
  ShortBlock = 2
  StopBlock = 3
  BitsDequantOut = -1
  MaxScfi = ((255 + BitsDequantOut * 4 - 210) + 3) and not 3
  GranuleLines = 576
  SubBands = 32
  MaxFrames = 1 shl 22
    ## Four million frames is over a day of audio.

type
  GranuleInfo = object
    sfbtab: seq[uint8] ## scalefactor band widths, terminated by a zero
    part23Length, bigValues: int
    globalGain, scalefacCompress: int
    blockType: int
    mixedBlock: bool
    subblockGain: array[3, int]
    tableSelect: array[3, int]
    regionCount: array[3, int]
    preflag, scalefacScale, count1Table: bool
    scfsi: int
    nLongSfb, nShortSfb: int

  FrameHeader = object
    bytes: array[4, uint8]

  Bits = object
    data: string
    pos, limit: int ## both counted in bits

  Decoder = object
    ## What one frame leaves for the next: the filterbank's memory, and the
    ## reservoir of bits a later frame may reach back into.
    mdctOverlap: array[2, array[9 * SubBands, float32]]
    qmfState: array[15 * 2 * SubBands, float32]
    reserv: int
    reservBuf: array[MaxBitReservoir, uint8]

# --- frame header -----------------------------------------------------------

func isMono(h: FrameHeader): bool = (h.bytes[3] and 0xC0'u8) == 0xC0'u8
func isMsStereo(h: FrameHeader): bool = (h.bytes[3] and 0xE0'u8) == 0x60'u8
func isIStereo(h: FrameHeader): bool = (h.bytes[3] and 0x10'u8) != 0
func testMsStereo(h: FrameHeader): bool = (h.bytes[3] and 0x20'u8) != 0
func hasCrc(h: FrameHeader): bool = (h.bytes[1] and 1'u8) == 0
func hasPadding(h: FrameHeader): bool = (h.bytes[2] and 2'u8) != 0
func isMpeg1(h: FrameHeader): bool = (h.bytes[1] and 8'u8) != 0
func notMpeg25(h: FrameHeader): bool = (h.bytes[1] and 0x10'u8) != 0
func layerCode(h: FrameHeader): int = int((h.bytes[1] shr 1) and 3'u8)
func bitrateIndex(h: FrameHeader): int = int(h.bytes[2] shr 4)
func rateIndex(h: FrameHeader): int = int((h.bytes[2] shr 2) and 3'u8)
func myRateIndex(h: FrameHeader): int =
  rateIndex(h) + (int((h.bytes[1] shr 3) and 1'u8) +
                  int((h.bytes[1] shr 4) and 1'u8)) * 3
func isFrame576(h: FrameHeader): bool = (h.bytes[1] and 14'u8) == 2'u8
func isLayer1(h: FrameHeader): bool = (h.bytes[1] and 6'u8) == 6'u8
func isFreeFormat(h: FrameHeader): bool = (h.bytes[2] and 0xF0'u8) == 0

func headerAt(data: string; offset: int): FrameHeader =
  for index in 0 .. 3: result.bytes[index] = uint8(data[offset + index])

func isValid(h: FrameHeader): bool =
  h.bytes[0] == 0xFF'u8 and
    ((h.bytes[1] and 0xF0'u8) == 0xF0'u8 or
     (h.bytes[1] and 0xFE'u8) == 0xE2'u8) and
    layerCode(h) != 0 and bitrateIndex(h) != 15 and rateIndex(h) != 3

func sameStream(a, b: FrameHeader): bool =
  ## Two headers belong to the same stream when version, layer, rate and
  ## channel mode agree. The bitrate may change from frame to frame.
  isValid(b) and ((a.bytes[1] xor b.bytes[1]) and 0xFE'u8) == 0 and
    ((a.bytes[2] xor b.bytes[2]) and 0x0C'u8) == 0 and
    isFreeFormat(a) == isFreeFormat(b)

const HalfRate: array[2, array[3, array[15, int]]] = [
  [[0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80],
   [0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80],
   [0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128]],
  [[0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160],
   [0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192],
   [0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224]]]

func bitrateKbps(h: FrameHeader): int =
  2 * HalfRate[if isMpeg1(h): 1 else: 0][layerCode(h) - 1][bitrateIndex(h)]

func sampleRateHz(h: FrameHeader): int =
  result = SampleRates[rateIndex(h)]
  if not isMpeg1(h): result = result shr 1
  if not notMpeg25(h): result = result shr 1

func frameSamples(h: FrameHeader): int =
  if isLayer1(h): 384 else: (if isFrame576(h): 576 else: 1152)

func frameBytes(h: FrameHeader; freeFormat: int): int =
  result = frameSamples(h) * bitrateKbps(h) * 125 div sampleRateHz(h)
  if isLayer1(h): result = result and not 3
  if result == 0: result = freeFormat

func padding(h: FrameHeader): int =
  if hasPadding(h): (if isLayer1(h): 4 else: 1) else: 0

# --- bit reader -------------------------------------------------------------

proc initBits(data: string; bytes: int): Bits =
  Bits(data: data, pos: 0, limit: bytes * 8)

proc getBits(bits: var Bits; count: int): uint32 =
  ## Most significant bit first. Reading past the end yields zero rather than
  ## raising: a truncated frame decodes as far as it goes, which is what the
  ## format asks for.
  if count == 0: return 0
  let shift = bits.pos and 7
  var byteIndex = bits.pos shr 3
  var remaining = count + shift
  bits.pos += count
  if bits.pos > bits.limit: return 0
  var next = uint32(uint8(bits.data[byteIndex])) and (255'u32 shr shift)
  inc byteIndex
  var cache = 0'u32
  while remaining - 8 > 0:
    remaining -= 8
    cache = cache or (next shl remaining)
    next = uint32(uint8(bits.data[byteIndex]))
    inc byteIndex
  cache or (next shr (8 - remaining))

# --- side information -------------------------------------------------------

func scfRow(table: openArray[uint8]; index, width: int): seq[uint8] =
  result = newSeq[uint8](width)
  for offset in 0 ..< width: result[offset] = table[index * width + offset]

proc readSideInfo(bits: var Bits; gr: var seq[GranuleInfo];
                  h: FrameHeader): int =
  ## How many bytes of the reservoir this frame reaches back into, or -1 when
  ## the side information is malformed.
  var rateIdx = myRateIndex(h)
  if rateIdx != 0: dec rateIdx
  var count = if isMono(h): 1 else: 2
  var scfsi = 0'u32
  var mainDataBegin: int

  if isMpeg1(h):
    count *= 2
    mainDataBegin = int(bits.getBits(9))
    scfsi = bits.getBits(7 + count)
  else:
    mainDataBegin = int(bits.getBits(8 + count)) shr count

  gr.setLen(count)
  var part23Sum = 0
  for index in 0 ..< count:
    if isMono(h): scfsi = scfsi shl 4
    gr[index].part23Length = int(bits.getBits(12))
    part23Sum += gr[index].part23Length
    gr[index].bigValues = int(bits.getBits(9))
    if gr[index].bigValues > 288: return -1
    gr[index].globalGain = int(bits.getBits(8))
    gr[index].scalefacCompress = int(bits.getBits(if isMpeg1(h): 4 else: 9))
    gr[index].sfbtab = scfRow(ScfLong, rateIdx, 23)
    gr[index].nLongSfb = 22
    gr[index].nShortSfb = 0
    var tables: uint32
    if bits.getBits(1) != 0:
      gr[index].blockType = int(bits.getBits(2))
      if gr[index].blockType == 0: return -1
      gr[index].mixedBlock = bits.getBits(1) != 0
      gr[index].regionCount[0] = 7
      gr[index].regionCount[1] = 255
      if gr[index].blockType == ShortBlock:
        scfsi = scfsi and 0x0F0F'u32
        if not gr[index].mixedBlock:
          gr[index].regionCount[0] = 8
          gr[index].sfbtab = scfRow(ScfShort, rateIdx, 40)
          gr[index].nLongSfb = 0
          gr[index].nShortSfb = 39
        else:
          gr[index].sfbtab = scfRow(ScfMixed, rateIdx, 40)
          gr[index].nLongSfb = if isMpeg1(h): 8 else: 6
          gr[index].nShortSfb = 30
      tables = bits.getBits(10) shl 5
      for sub in 0 .. 2: gr[index].subblockGain[sub] = int(bits.getBits(3))
    else:
      gr[index].blockType = 0
      gr[index].mixedBlock = false
      tables = bits.getBits(15)
      gr[index].regionCount[0] = int(bits.getBits(4))
      gr[index].regionCount[1] = int(bits.getBits(3))
      gr[index].regionCount[2] = 255
    gr[index].tableSelect[0] = int(tables shr 10)
    gr[index].tableSelect[1] = int((tables shr 5) and 31)
    gr[index].tableSelect[2] = int(tables and 31)
    gr[index].preflag = if isMpeg1(h): bits.getBits(1) != 0
                        else: gr[index].scalefacCompress >= 500
    gr[index].scalefacScale = bits.getBits(1) != 0
    gr[index].count1Table = bits.getBits(1) != 0
    gr[index].scfsi = int((scfsi shr 12) and 15)
    scfsi = scfsi shl 4

  if part23Sum + bits.pos > bits.limit + mainDataBegin * 8: return -1
  mainDataBegin

# --- scalefactors -----------------------------------------------------------

proc readScalefactors(scf: var array[40, uint8];
                      istPos: var array[39, uint8];
                      size: array[4, int]; counts: openArray[uint8];
                      countBase: int; bits: var Bits; scfsi: int) =
  var scfsi = scfsi
  var at = 0
  var istAt = 0
  for part in 0 ..< 4:
    let cnt = int(counts[countBase + part])
    if cnt == 0: break
    if (scfsi and 8) != 0:
      # This granule reuses the previous one's scalefactors for this band.
      for k in 0 ..< cnt: scf[at + k] = istPos[istAt + k]
    else:
      let width = size[part]
      if width == 0:
        for k in 0 ..< cnt:
          scf[at + k] = 0
          istPos[istAt + k] = 0
      else:
        # A value at the top of its range means "no intensity position here".
        let maxScf = if scfsi < 0: (1 shl width) - 1 else: -1
        for k in 0 ..< cnt:
          let s = int(bits.getBits(width))
          istPos[istAt + k] = uint8(if s == maxScf: 255 else: s)
          scf[at + k] = uint8(s)
    istAt += cnt
    at += cnt
    scfsi *= 2
  scf[at] = 0
  scf[at + 1] = 0
  scf[at + 2] = 0

func ldexpQ2(value: float32; exponent: int): float32 =
  ## Scale by two to the power of `exponent` quarters, in steps small enough
  ## that each multiply stays exact.
  result = value
  var rest = exponent
  while true:
    let e = min(30 * 4, rest)
    result = result * ExpFrac[e and 3] * float32(1 shl 30 shr (e shr 2))
    rest -= e
    if rest <= 0: break

proc decodeScalefactors(h: FrameHeader; istPos: var array[39, uint8];
                        bits: var Bits; gr: GranuleInfo;
                        scf: var array[40, float32]; channel: int) =
  let partition = (if gr.nShortSfb != 0: 1 else: 0) +
                  (if gr.nLongSfb == 0: 1 else: 0)
  var countBase = partition * 28
  var size: array[4, int]
  var scfsi = gr.scfsi
  let shift = (if gr.scalefacScale: 1 else: 0) + 1

  if isMpeg1(h):
    let part = int(ScfcDecode[gr.scalefacCompress])
    size[0] = part shr 2
    size[1] = size[0]
    size[2] = part and 3
    size[3] = size[2]
  else:
    let intensity = if isIStereo(h) and channel != 0: 1 else: 0
    var sfc = gr.scalefacCompress shr intensity
    var k = intensity * 3 * 4
    var product = 1
    while sfc >= 0:
      product = 1
      for index in countdown(3, 0):
        size[index] = (sfc div product) mod int(ScfMod[k + index])
        product *= int(ScfMod[k + index])
      sfc -= product
      k += 4
    countBase += k
    scfsi = -16

  var iscf: array[40, uint8]
  readScalefactors(iscf, istPos, size, ScfPartitions, countBase, bits, scfsi)

  if gr.nShortSfb != 0:
    let sh = 3 - shift
    var index = 0
    while index < gr.nShortSfb:
      for sub in 0 .. 2:
        iscf[gr.nLongSfb + index + sub] =
          iscf[gr.nLongSfb + index + sub] + uint8(gr.subblockGain[sub] shl sh)
      index += 3
  elif gr.preflag:
    for index in 0 ..< 10:
      iscf[11 + index] = iscf[11 + index] + Preamp[index]

  let gainExp = gr.globalGain + BitsDequantOut * 4 - 210 -
                (if isMsStereo(h): 2 else: 0)
  let gain = ldexpQ2(float32(1 shl (MaxScfi div 4)), MaxScfi - gainExp)
  for index in 0 ..< gr.nLongSfb + gr.nShortSfb:
    scf[index] = ldexpQ2(gain, int(iscf[index]) shl shift)

# --- spectrum ---------------------------------------------------------------

func pow43(x: int): float32 =
  ## The three-quarter-power dequantisation curve. Small values come straight
  ## from the table; larger ones interpolate between its entries.
  if x < 129: return Pow43[16 + x]
  var value = x
  var multiplier = 256'f32
  if value < 1024:
    multiplier = 16
    value = value shl 3
  let sign = (2 * value) and 64
  let frac = float32((value and 63) - sign) /
             float32((value and not 63) + sign)
  Pow43[16 + ((value + sign) shr 6)] *
    (1.0'f32 + frac * (4.0'f32 / 3.0'f32 + frac * (2.0'f32 / 9.0'f32))) *
    multiplier

type HuffReader = object
  ## The Huffman loop reads a bit at a time, so it keeps a 32-bit window rather
  ## than going back through `Bits` for each one.
  data: string
  next: int
  cache: uint32
  sh: int

proc initHuff(bits: Bits): HuffReader =
  result.data = bits.data
  result.next = bits.pos shr 3
  var word = 0'u32
  for offset in 0 .. 3:
    word = (word shl 8) or uint32(uint8(result.data[result.next + offset]))
  result.cache = word shl (bits.pos and 7)
  result.sh = (bits.pos and 7) - 8
  result.next += 4

func peek(reader: HuffReader; count: int): int =
  if count <= 0: 0 else: int(reader.cache shr (32 - count))

proc flush(reader: var HuffReader; count: int) =
  reader.cache = reader.cache shl count
  reader.sh += count

proc refill(reader: var HuffReader) =
  while reader.sh >= 0:
    reader.cache = reader.cache or
      (uint32(uint8(reader.data[reader.next])) shl reader.sh)
    inc reader.next
    reader.sh -= 8

func position(reader: HuffReader): int = reader.next * 8 - 24 + reader.sh

func negative(reader: HuffReader): bool =
  (reader.cache and 0x8000_0000'u32) != 0

proc decodeSpectrum(dst: var seq[float32]; dstBase: int; bits: var Bits;
                    gr: GranuleInfo; scf: array[40, float32]; limit: int) =
  var reader = initHuff(bits)
  var one = 0.0'f32
  var region = 0
  var remaining = gr.bigValues
  var sfbAt = 0
  var scfAt = 0
  var at = dstBase

  while remaining > 0 and region < 3:
    let tableNum = gr.tableSelect[region]
    var sfbCount = gr.regionCount[region]
    inc region
    let bookBase = int(TabIndex[tableNum])
    let linbits = int(LinBits[tableNum])
    while true:
      let np = int(gr.sfbtab[sfbAt]) div 2
      inc sfbAt
      var pairs = min(remaining, np)
      one = scf[scfAt]
      inc scfAt
      while pairs > 0:
        var width = 5
        var leaf = int(HuffTabs[bookBase + reader.peek(width)])
        while leaf < 0:
          reader.flush(width)
          width = leaf and 7
          leaf = int(HuffTabs[bookBase + reader.peek(width) - (leaf shr 3)])
        reader.flush(leaf shr 8)
        for _ in 0 .. 1:
          var lsb = leaf and 0x0F
          if linbits != 0 and lsb == 15:
            lsb += reader.peek(linbits)
            reader.flush(linbits)
            reader.refill()
            dst[at] = one * pow43(lsb) *
              (if reader.negative(): -1.0'f32 else: 1.0'f32)
          else:
            dst[at] = Pow43[16 + lsb - (if reader.negative(): 16 else: 0)] * one
          reader.flush(if lsb != 0: 1 else: 0)
          inc at
          leaf = leaf shr 4
        reader.refill()
        dec pairs
      remaining -= np
      dec sfbCount
      if remaining <= 0 or sfbCount < 0: break

  # Past the big values the spectrum is coded four lines at a time as little
  # more than signs: every remaining line is -1, 0 or 1.
  var np = 1 - remaining
  # The two count-1 codebooks are different lengths, so index them rather than
  # binding one of them to a name.
  template countTable(index: int): int =
    if gr.count1Table: int(Tab33[index]) else: int(Tab32[index])
  while true:
    var leaf = countTable(reader.peek(4))
    if (leaf and 8) == 0:
      leaf = countTable((leaf shr 3) +
        int((reader.cache shl 4) shr (32 - (leaf and 3))))
    reader.flush(leaf and 7)
    if reader.position() > limit: break
    var exhausted = false
    for half in 0 .. 1:
      dec np
      if np == 0:
        np = int(gr.sfbtab[sfbAt]) div 2
        inc sfbAt
        if np == 0:
          exhausted = true
          break
        one = scf[scfAt]
        inc scfAt
      for step in 0 .. 1:
        let index = half * 2 + step
        if (leaf and (128 shr index)) != 0:
          if at + index < dst.len:
            dst[at + index] = if reader.negative(): -one else: one
          reader.flush(1)
    if exhausted: break
    at += 4
    if at + 4 > dst.len: break
    reader.refill()

  bits.pos = limit

# --- stereo -----------------------------------------------------------------

proc midSideStereo(gr: var seq[float32]; base, count: int) =
  for index in 0 ..< count:
    let a = gr[base + index]
    let b = gr[base + GranuleLines + index]
    gr[base + index] = a + b
    gr[base + GranuleLines + index] = a - b

proc intensityBand(gr: var seq[float32]; base, count: int; kl, kr: float32) =
  for index in 0 ..< count:
    gr[base + GranuleLines + index] = gr[base + index] * kr
    gr[base + index] = gr[base + index] * kl

proc topBand(gr: seq[float32]; base: int; sfb: seq[uint8]; bands: int;
             maxBand: var array[3, int]) =
  ## The highest band in each of the three short windows that carries anything
  ## on the right channel. Above it, the right channel is only a scaling of the
  ## left, which is what intensity stereo means.
  maxBand = [-1, -1, -1]
  var at = base
  for index in 0 ..< bands:
    var k = 0
    while k < int(sfb[index]):
      if gr[at + k] != 0 or gr[at + k + 1] != 0:
        maxBand[index mod 3] = index
        break
      k += 2
    at += int(sfb[index])

proc stereoProcess(gr: var seq[float32]; istPos: array[39, uint8];
                   sfb: seq[uint8]; h: FrameHeader; maxBand: array[3, int];
                   mpeg2Shift: int) =
  let maxPos = if isMpeg1(h): 7 else: 64
  var base = 0
  var index = 0
  while index < sfb.len and sfb[index] != 0:
    let ipos = int(istPos[index])
    if index > maxBand[index mod 3] and ipos < maxPos:
      let s = if testMsStereo(h): 1.41421356'f32 else: 1.0'f32
      var kl, kr: float32
      if isMpeg1(h):
        kl = Pan[2 * ipos]
        kr = Pan[2 * ipos + 1]
      else:
        kl = 1
        kr = ldexpQ2(1, ((ipos + 1) shr 1) shl mpeg2Shift)
        if (ipos and 1) != 0:
          kl = kr
          kr = 1
      intensityBand(gr, base, int(sfb[index]), kl * s, kr * s)
    elif testMsStereo(h):
      midSideStereo(gr, base, int(sfb[index]))
    base += int(sfb[index])
    inc index

proc intensityStereo(gr: var seq[float32]; istPos: var array[39, uint8];
                     info: seq[GranuleInfo]; first: int; h: FrameHeader) =
  var maxBand: array[3, int]
  let nSfb = info[first].nLongSfb + info[first].nShortSfb
  let blocks = if info[first].nShortSfb != 0: 3 else: 1
  topBand(gr, GranuleLines, info[first].sfbtab, nSfb, maxBand)
  if info[first].nLongSfb != 0:
    let widest = max(max(maxBand[0], maxBand[1]), maxBand[2])
    maxBand = [widest, widest, widest]
  for index in 0 ..< blocks:
    let defaultPos = if isMpeg1(h): 3 else: 0
    let top = nSfb - blocks + index
    let previous = top - blocks
    istPos[top] = if maxBand[index] >= previous: uint8(defaultPos)
                  else: istPos[previous]
  let shift = if first + 1 < info.len: info[first + 1].scalefacCompress and 1
              else: 0
  stereoProcess(gr, istPos, info[first].sfbtab, h, maxBand, shift)

# --- filterbank -------------------------------------------------------------

proc reorder(gr: var seq[float32]; base: int; scratch: var seq[float32];
             sfb: seq[uint8]; sfbAt: int) =
  ## Short blocks arrive grouped by window; the filterbank wants them grouped
  ## by frequency.
  var src = base
  var written = 0
  var at = sfbAt
  while at < sfb.len and sfb[at] != 0:
    let len = int(sfb[at])
    for index in 0 ..< len:
      for window in 0 .. 2:
        scratch[written] = gr[src + index + window * len]
        inc written
    src += 3 * len
    at += 3
  for index in 0 ..< written: gr[base + index] = scratch[index]

proc antialias(gr: var seq[float32]; base, bands: int) =
  ## Undo the aliasing the encoder's filterbank left between neighbouring
  ## subbands.
  var at = base
  for _ in 0 ..< bands:
    for index in 0 ..< 8:
      let u = gr[at + 18 + index]
      let d = gr[at + 17 - index]
      gr[at + 18 + index] = u * Antialias[index] - d * Antialias[8 + index]
      gr[at + 17 - index] = u * Antialias[8 + index] + d * Antialias[index]
    at += 18

proc dct3x9(y: var array[9, float32]) =
  var s0 = y[0]
  var s2 = y[2]
  var s4 = y[4]
  var s6 = y[6]
  var s8 = y[8]
  var t0 = s0 + s6 * 0.5'f32
  s0 -= s6
  var t4 = (s4 + s2) * 0.93969262'f32
  var t2 = (s8 + s2) * 0.76604444'f32
  s6 = (s4 - s8) * 0.17364818'f32
  s4 += s8 - s2

  s2 = s0 - s4 * 0.5'f32
  y[4] = s4 + s0
  s8 = t0 - t2 + s6
  s0 = t0 - t4 + t2
  s4 = t0 + t4 - s6

  var s1 = y[1]
  var s3 = y[3]
  var s5 = y[5]
  var s7 = y[7]

  s3 = s3 * 0.86602540'f32
  t0 = (s5 + s1) * 0.98480775'f32
  t4 = (s5 - s7) * 0.34202014'f32
  t2 = (s1 + s7) * 0.64278761'f32
  s1 = (s1 - s5 - s7) * 0.86602540'f32

  s5 = t0 - s3 - t2
  s7 = t4 - s3 - t0
  s3 = t4 + s3 - t2

  y[0] = s4 - s7
  y[1] = s2 + s1
  y[2] = s0 - s3
  y[3] = s8 + s5
  y[5] = s8 - s5
  y[6] = s0 + s3
  y[7] = s2 - s1
  y[8] = s4 + s7

proc imdct36(gr: var seq[float32]; grAt: int; overlap: var openArray[float32];
             overlapAt, window, bands: int) =
  var at = grAt
  var ovAt = overlapAt
  for _ in 0 ..< bands:
    var co, si: array[9, float32]
    co[0] = -gr[at]
    si[0] = gr[at + 17]
    for index in 0 ..< 4:
      si[8 - 2 * index] = gr[at + 4 * index + 1] - gr[at + 4 * index + 2]
      co[1 + 2 * index] = gr[at + 4 * index + 1] + gr[at + 4 * index + 2]
      si[7 - 2 * index] = gr[at + 4 * index + 4] - gr[at + 4 * index + 3]
      co[2 + 2 * index] = -(gr[at + 4 * index + 3] + gr[at + 4 * index + 4])
    dct3x9(co)
    dct3x9(si)
    si[1] = -si[1]
    si[3] = -si[3]
    si[5] = -si[5]
    si[7] = -si[7]

    let win = window * 18
    for index in 0 ..< 9:
      let previous = overlap[ovAt + index]
      let sum = co[index] * Twiddle9[9 + index] + si[index] * Twiddle9[index]
      overlap[ovAt + index] =
        co[index] * Twiddle9[index] - si[index] * Twiddle9[9 + index]
      gr[at + index] =
        previous * MdctWindow[win + index] - sum * MdctWindow[win + 9 + index]
      gr[at + 17 - index] =
        previous * MdctWindow[win + 9 + index] + sum * MdctWindow[win + index]
    at += 18
    ovAt += 9

func idct3(x0, x1, x2: float32): array[3, float32] =
  let m1 = x1 * 0.86602540'f32
  let a1 = x0 - x2 * 0.5'f32
  [a1 + m1, x0 + x2, a1 - m1]

proc imdct12(source: openArray[float32]; sourceAt: int;
             dst: var openArray[float32]; dstAt: int;
             overlap: var openArray[float32]; overlapAt: int) =
  var co = idct3(-source[sourceAt],
                 source[sourceAt + 6] + source[sourceAt + 3],
                 source[sourceAt + 12] + source[sourceAt + 9])
  var si = idct3(source[sourceAt + 15],
                 source[sourceAt + 12] - source[sourceAt + 9],
                 source[sourceAt + 6] - source[sourceAt + 3])
  si[1] = -si[1]
  for index in 0 .. 2:
    let previous = overlap[overlapAt + index]
    let sum = co[index] * Twiddle3[3 + index] + si[index] * Twiddle3[index]
    overlap[overlapAt + index] =
      co[index] * Twiddle3[index] - si[index] * Twiddle3[3 + index]
    dst[dstAt + index] =
      previous * Twiddle3[2 - index] - sum * Twiddle3[5 - index]
    dst[dstAt + 5 - index] =
      previous * Twiddle3[5 - index] + sum * Twiddle3[2 - index]

proc imdctShort(gr: var seq[float32]; grAt: int;
                overlap: var openArray[float32]; overlapAt, bands: int) =
  var at = grAt
  var ovAt = overlapAt
  for _ in 0 ..< bands:
    var tmp: array[18, float32]
    for index in 0 ..< 18: tmp[index] = gr[at + index]
    for index in 0 ..< 6: gr[at + index] = overlap[ovAt + index]
    imdct12(tmp, 0, gr, at + 6, overlap, ovAt + 6)
    imdct12(tmp, 1, gr, at + 12, overlap, ovAt + 6)
    imdct12(tmp, 2, overlap, ovAt, overlap, ovAt + 6)
    at += 18
    ovAt += 9

proc changeSign(gr: var seq[float32]; base: int) =
  var at = base + 18
  var band = 0
  while band < SubBands:
    var index = 1
    while index < 18:
      gr[at + index] = -gr[at + index]
      index += 2
    band += 2
    at += 36

proc imdctGranule(gr: var seq[float32]; base: int;
                  overlap: var openArray[float32]; overlapAt: int;
                  blockType, longBands: int) =
  var at = base
  var ovAt = overlapAt
  if longBands != 0:
    imdct36(gr, at, overlap, ovAt, 0, longBands)
    at += 18 * longBands
    ovAt += 9 * longBands
  if blockType == ShortBlock:
    imdctShort(gr, at, overlap, ovAt, SubBands - longBands)
  else:
    imdct36(gr, at, overlap, ovAt,
      (if blockType == StopBlock: 1 else: 0), SubBands - longBands)

# --- synthesis --------------------------------------------------------------

proc dct2(gr: var seq[float32]; base, n: int) =
  for k in 0 ..< n:
    var t: array[32, float32]
    var y = base + k
    for index in 0 ..< 8:
      let x0 = gr[y + index * 18]
      let x1 = gr[y + (15 - index) * 18]
      let x2 = gr[y + (16 + index) * 18]
      let x3 = gr[y + (31 - index) * 18]
      let t0 = x0 + x3
      let t1 = x1 + x2
      let t2 = (x1 - x2) * DctSec[3 * index]
      let t3 = (x0 - x3) * DctSec[3 * index + 1]
      t[index] = t0 + t1
      t[index + 8] = (t0 - t1) * DctSec[3 * index + 2]
      t[index + 16] = t3 + t2
      t[index + 24] = (t3 - t2) * DctSec[3 * index + 2]
    for quarter in 0 ..< 4:
      let b = quarter * 8
      var x0 = t[b]
      var x1 = t[b + 1]
      var x2 = t[b + 2]
      var x3 = t[b + 3]
      var x4 = t[b + 4]
      var x5 = t[b + 5]
      var x6 = t[b + 6]
      var x7 = t[b + 7]
      var xt = x0 - x7
      x0 += x7
      x7 = x1 - x6
      x1 += x6
      x6 = x2 - x5
      x2 += x5
      x5 = x3 - x4
      x3 += x4
      x4 = x0 - x3
      x0 += x3
      x3 = x1 - x2
      x1 += x2
      t[b] = x0 + x1
      t[b + 4] = (x0 - x1) * 0.70710677'f32
      x5 = x5 + x6
      x6 = (x6 + x7) * 0.70710677'f32
      x7 = x7 + xt
      x3 = (x3 + x4) * 0.70710677'f32
      x5 -= x7 * 0.198912367'f32 # a rotation by an eighth of a turn
      x7 += x5 * 0.382683432'f32
      x5 -= x7 * 0.198912367'f32
      x0 = xt - x6
      xt += x6
      t[b + 1] = (xt + x7) * 0.50979561'f32
      t[b + 2] = (x4 + x3) * 0.54119611'f32
      t[b + 3] = (x0 - x5) * 0.60134488'f32
      t[b + 5] = (x0 + x5) * 0.89997619'f32
      t[b + 6] = (x4 - x3) * 1.30656302'f32
      t[b + 7] = (xt - x7) * 2.56291556'f32
    for index in 0 ..< 7:
      gr[y] = t[index]
      gr[y + 18] = t[16 + index] + t[24 + index] + t[24 + index + 1]
      gr[y + 36] = t[8 + index] + t[8 + index + 1]
      gr[y + 54] = t[16 + index + 1] + t[24 + index] + t[24 + index + 1]
      y += 4 * 18
    gr[y] = t[7]
    gr[y + 18] = t[23] + t[31]
    gr[y + 36] = t[15]
    gr[y + 54] = t[31]

const PcmScale = 1.0'f32 / 32768.0'f32

proc synthPair(pcm: var seq[float32]; at, stride: int;
               lins: openArray[float32]; z: int) =
  var a = (lins[z + 14 * 64] - lins[z]) * 29'f32
  a += (lins[z + 64] + lins[z + 13 * 64]) * 213'f32
  a += (lins[z + 12 * 64] - lins[z + 2 * 64]) * 459'f32
  a += (lins[z + 3 * 64] + lins[z + 11 * 64]) * 2037'f32
  a += (lins[z + 10 * 64] - lins[z + 4 * 64]) * 5153'f32
  a += (lins[z + 5 * 64] + lins[z + 9 * 64]) * 6574'f32
  a += (lins[z + 8 * 64] - lins[z + 6 * 64]) * 37489'f32
  a += lins[z + 7 * 64] * 75038'f32
  pcm[at] = a * PcmScale

  let w = z + 2
  var b = lins[w + 14 * 64] * 104'f32
  b += lins[w + 12 * 64] * 1567'f32
  b += lins[w + 10 * 64] * 9727'f32
  b += lins[w + 8 * 64] * 64019'f32
  b += lins[w + 6 * 64] * -9975'f32
  b += lins[w + 4 * 64] * -45'f32
  b += lins[w + 2 * 64] * 146'f32
  b += lins[w] * -5'f32
  pcm[at + 16 * stride] = b * PcmScale

proc synth(gr: seq[float32]; grAt, channels: int; pcm: var seq[float32];
           pcmAt: int; lins: var seq[float32]; linsAt: int) =
  ## The polyphase synthesis filter: 32 subbands back into 64 samples.
  let left = grAt
  let right = grAt + GranuleLines * (channels - 1)
  let dstl = pcmAt
  let dstr = pcmAt + channels - 1
  let zlin = linsAt + 15 * 64

  lins[zlin + 4 * 15] = gr[left + 18 * 16]
  lins[zlin + 4 * 15 + 1] = gr[right + 18 * 16]
  lins[zlin + 4 * 15 + 2] = gr[left]
  lins[zlin + 4 * 15 + 3] = gr[right]

  lins[zlin + 4 * 31] = gr[left + 1 + 18 * 16]
  lins[zlin + 4 * 31 + 1] = gr[right + 1 + 18 * 16]
  lins[zlin + 4 * 31 + 2] = gr[left + 1]
  lins[zlin + 4 * 31 + 3] = gr[right + 1]

  synthPair(pcm, dstr, channels, lins, linsAt + 4 * 15 + 1)
  synthPair(pcm, dstr + 32 * channels, channels, lins,
    linsAt + 4 * 15 + 64 + 1)
  synthPair(pcm, dstl, channels, lins, linsAt + 4 * 15)
  synthPair(pcm, dstl + 32 * channels, channels, lins, linsAt + 4 * 15 + 64)

  var w = 0
  for i in countdown(14, 0):
    var a, b: array[4, float32]
    lins[zlin + 4 * i] = gr[left + 18 * (31 - i)]
    lins[zlin + 4 * i + 1] = gr[right + 18 * (31 - i)]
    lins[zlin + 4 * i + 2] = gr[left + 1 + 18 * (31 - i)]
    lins[zlin + 4 * i + 3] = gr[right + 1 + 18 * (31 - i)]
    lins[zlin + 4 * (i + 16)] = gr[left + 1 + 18 * (1 + i)]
    lins[zlin + 4 * (i + 16) + 1] = gr[right + 1 + 18 * (1 + i)]
    lins[zlin + 4 * (i - 16) + 2] = gr[left + 18 * (1 + i)]
    lins[zlin + 4 * (i - 16) + 3] = gr[right + 18 * (1 + i)]

    # Eight taps. The odd ones subtract the near half from the far half rather
    # than the other way round, which is the filter's alternating symmetry.
    for step in 0 ..< 8:
      let w0 = SynthWindow[w]
      let w1 = SynthWindow[w + 1]
      w += 2
      let vz = zlin + 4 * i - step * 64
      let vy = zlin + 4 * i - (15 - step) * 64
      for j in 0 ..< 4:
        let bj = lins[vz + j] * w1 + lins[vy + j] * w0
        if step == 0:
          b[j] = bj
          a[j] = lins[vz + j] * w0 - lins[vy + j] * w1
        else:
          b[j] += bj
          if (step and 1) != 0:
            a[j] += lins[vy + j] * w1 - lins[vz + j] * w0
          else:
            a[j] += lins[vz + j] * w0 - lins[vy + j] * w1

    pcm[dstr + (15 - i) * channels] = a[1] * PcmScale
    pcm[dstr + (17 + i) * channels] = b[1] * PcmScale
    pcm[dstl + (15 - i) * channels] = a[0] * PcmScale
    pcm[dstl + (17 + i) * channels] = b[0] * PcmScale
    pcm[dstr + (47 - i) * channels] = a[3] * PcmScale
    pcm[dstr + (49 + i) * channels] = b[3] * PcmScale
    pcm[dstl + (47 - i) * channels] = a[2] * PcmScale
    pcm[dstl + (49 + i) * channels] = b[2] * PcmScale

proc synthGranule(decoder: var Decoder; gr: var seq[float32];
                  bands, channels: int; pcm: var seq[float32]; pcmAt: int;
                  lins: var seq[float32]) =
  for channel in 0 ..< channels:
    dct2(gr, GranuleLines * channel, bands)
  for index in 0 ..< 15 * 64: lins[index] = decoder.qmfState[index]
  var band = 0
  while band < bands:
    synth(gr, band, channels, pcm, pcmAt + 32 * channels * band, lins,
      band * 64)
    band += 2
  if channels == 1:
    var index = 0
    while index < 15 * 64:
      decoder.qmfState[index] = lins[bands * 64 + index]
      index += 2
  else:
    for index in 0 ..< 15 * 64:
      decoder.qmfState[index] = lins[bands * 64 + index]

# --- frames -----------------------------------------------------------------

proc decodeGranule(decoder: var Decoder; h: FrameHeader; main: var Bits;
                   info: seq[GranuleInfo]; first, channels: int;
                   gr: var seq[float32];
                   istPos: var array[2, array[39, uint8]];
                   scratch: var seq[float32]) =
  var scf: array[40, float32]
  for channel in 0 ..< channels:
    let limit = main.pos + info[first + channel].part23Length
    decodeScalefactors(h, istPos[channel], main, info[first + channel], scf,
      channel)
    decodeSpectrum(gr, GranuleLines * channel, main, info[first + channel],
      scf, limit)

  if isIStereo(h):
    intensityStereo(gr, istPos[1], info, first, h)
  elif isMsStereo(h):
    midSideStereo(gr, 0, GranuleLines)

  for channel in 0 ..< channels:
    let g = info[first + channel]
    var aaBands = 31
    let longBands = (if g.mixedBlock: 2 else: 0) shl
      (if myRateIndex(h) == 2: 1 else: 0)
    if g.nShortSfb != 0:
      aaBands = longBands - 1
      reorder(gr, GranuleLines * channel + longBands * 18, scratch, g.sfbtab,
        g.nLongSfb)
    antialias(gr, GranuleLines * channel, aaBands)
    imdctGranule(gr, GranuleLines * channel, decoder.mdctOverlap[channel], 0,
      g.blockType, longBands)
    changeSign(gr, GranuleLines * channel)

proc findFrame(data: string; start: int; freeFormat: var int;
               frameSize: var int): int =
  ## The offset of the next frame whose header is corroborated by the ones that
  ## should follow it. A lone valid-looking header is not enough: MP3 has no
  ## framing beyond the sync word, and audio data mimics it often.
  var index = start
  while index < data.len - HeaderBytes:
    let h = headerAt(data, index)
    if h.isValid:
      let size = frameBytes(h, freeFormat)
      let whole = size + padding(h)
      if size > 0 and index + whole <= data.len:
        var at = index
        var matches = 0
        var good = true
        while matches < 10:
          let here = headerAt(data, at)
          at += frameBytes(here, freeFormat) + padding(here)
          if at + HeaderBytes > data.len:
            good = matches > 0
            break
          if not sameStream(h, headerAt(data, at)):
            good = false
            break
          inc matches
        if good or (index == start and whole == data.len - start):
          frameSize = whole
          return index
      freeFormat = 0
    inc index
  frameSize = 0
  data.len

proc gaplessTrim(data: string; frameStart, frameSize: int):
    tuple[delay, tail: int; tagged: bool] =
  ## LAME and its descendants record the samples they added at each end in an
  ## `Info`/`Xing` tag, carried in a frame of its own ahead of the audio. That
  ## frame decodes to silence and is not part of the recording. Without the tag
  ## there is nothing to trim and no frame to drop.
  let window = min(data.len - 4, frameStart + frameSize)
  var at = -1
  for index in frameStart ..< window:
    let tag = data[index ..< index + 4]
    if tag == "Xing" or tag == "Info":
      at = index
      break
  if at < 0: return (0, 0, false)
  var flags = 0
  for index in 0 .. 3:
    flags = (flags shl 8) or int(uint8(data[at + 4 + index]))
  var cursor = at + 8
  if (flags and 1) != 0: cursor += 4 # frame count
  if (flags and 2) != 0: cursor += 4 # byte count
  if (flags and 4) != 0: cursor += 100 # seek table
  if (flags and 8) != 0: cursor += 4 # quality indicator
  # The LAME extension follows: nine bytes naming the encoder, then twelve
  # more before the delay and padding, packed twelve bits each.
  let delayAt = cursor + 21
  if delayAt + 3 > data.len: return (0, 0, true)
  let packed = (int(uint8(data[delayAt])) shl 16) or
               (int(uint8(data[delayAt + 1])) shl 8) or
               int(uint8(data[delayAt + 2]))
  let delay = packed shr 12
  let tail = packed and 0xFFF
  if delay > 5000 or tail > 5000: return (0, 0, true)
  (delay, tail, true)

func audioSpan(data: string): tuple[first, last: int] =
  ## The bytes that are actually MPEG frames. Tags sit outside them: ID3v2 at
  ## the front, ID3v1 or APE at the end. Leaving them in place would make the
  ## frame search reject the last real frame, whose successor is a tag rather
  ## than another frame.
  result = (0, data.len)
  if data.len > 10 and data[0 .. 2] == "ID3":
    # A four-byte size with the top bit of each byte cleared, so it can never
    # contain a frame sync.
    var size = 0
    for index in 6 .. 9:
      size = (size shl 7) or (int(uint8(data[index])) and 0x7F)
    let footer = if (uint8(data[5]) and 0x10'u8) != 0: 10 else: 0
    result.first = min(data.len, 10 + size + footer)
  if result.last - result.first > 128 and
      data[result.last - 128 ..< result.last - 125] == "TAG":
    result.last -= 128
  if result.last - result.first > 32 and
      data[result.last - 32 ..< result.last - 24] == "APETAGEX":
    var size = 0
    for index in countdown(3, 0):
      size = (size shl 8) or int(uint8(data[result.last - 20 + index]))
    if size in 0 .. result.last - result.first: result.last -= size + 32

proc readMp3*(data: string): AudioBuffer =
  ## Decode an MPEG audio file held in memory.
  ##
  ## Anything ahead of the first corroborated frame header is skipped, which is
  ## how an ID3 tag or a stray byte at the front is passed over.
  let span = audioSpan(data)
  let data = data[span.first ..< span.last]
  var freeFormat = 0
  var frameSize = 0
  var offset = findFrame(data, 0, freeFormat, frameSize)
  if frameSize == 0:
    raise newException(AudioError, "mp3: no frame header in the file")

  let firstHeader = headerAt(data, offset)
  let layer = 4 - layerCode(firstHeader)
  if layer != 3:
    raise newException(AudioError, "mp3: layer " & $layer &
      " is a different codec and is not decoded")
  let channels = if isMono(firstHeader): 1 else: 2
  let rate = sampleRateHz(firstHeader)
  if rate notin 1 .. MaxSampleRate:
    raise newException(AudioError, "mp3: implausible sample rate")

  let (delay, tail, tagged) = gaplessTrim(data, offset, frameSize)
  var decoder = Decoder()
  var output = newSeq[float32]()
  # The Huffman reader looks up to four bytes past its position, so both the
  # file and the reservoir buffer carry a tail of zeros to read into.
  let padded = data & "\0\0\0\0\0\0\0\0"
  var main = newString(MaxBitReservoir + MaxFramePayload + 8)
  var gr = newSeq[float32](2 * GranuleLines)
  var scratch = newSeq[float32](2 * GranuleLines)
  var lins = newSeq[float32](33 * 64)
  var istPos: array[2, array[39, uint8]]
  var info: seq[GranuleInfo]
  var frames = 0

  while offset + frameSize <= data.len:
    let h = headerAt(data, offset)
    if not sameStream(firstHeader, h): break
    inc frames
    let tagFrame = tagged and frames == 1
    if frames > MaxFrames:
      raise newException(AudioError, "mp3: implausible frame count")

    var frame = initBits(padded, offset + frameSize)
    frame.pos = (offset + HeaderBytes) * 8
    if hasCrc(h): discard frame.getBits(16)

    let mainDataBegin = readSideInfo(frame, info, h)
    if mainDataBegin >= 0 and frame.pos <= frame.limit:
      # Splice this frame's payload onto what earlier frames left behind: a
      # granule may reach back several frames for the bits it needs.
      let payloadBytes = (frame.limit - frame.pos) div 8
      let borrowed = min(decoder.reserv, mainDataBegin)
      let borrowFrom = max(0, decoder.reserv - mainDataBegin)
      for index in 0 ..< borrowed:
        main[index] = char(decoder.reservBuf[borrowFrom + index])
      for index in 0 ..< payloadBytes:
        main[borrowed + index] = padded[(frame.pos div 8) + index]
      for index in 0 ..< 8: main[borrowed + payloadBytes + index] = '\0'
      var mainBits = initBits(main, borrowed + payloadBytes)

      if decoder.reserv >= mainDataBegin and not tagFrame:
        let granules = if isMpeg1(h): 2 else: 1
        var pcm = newSeq[float32](granules * GranuleLines * channels)
        for granule in 0 ..< granules:
          for index in 0 ..< gr.len: gr[index] = 0
          decodeGranule(decoder, h, mainBits, info, granule * channels,
            channels, gr, istPos, scratch)
          synthGranule(decoder, gr, 18, channels, pcm,
            granule * GranuleLines * channels, lins)
        output.add pcm

      # Keep what this frame did not consume, for the frames that follow.
      let consumed = (mainBits.pos + 7) div 8
      var remains = mainBits.limit div 8 - consumed
      var keepFrom = consumed
      if remains > MaxBitReservoir:
        keepFrom += remains - MaxBitReservoir
        remains = MaxBitReservoir
      if remains > 0:
        for index in 0 ..< remains:
          decoder.reservBuf[index] = uint8(main[keepFrom + index])
      decoder.reserv = max(0, remains)
    else:
      decoder = Decoder()

    offset += frameSize
    if offset + HeaderBytes > data.len: break
    let next = headerAt(data, offset)
    if next.isValid:
      frameSize = frameBytes(next, freeFormat) + padding(next)
      if frameSize == 0: break
    else:
      offset = findFrame(data, offset, freeFormat, frameSize)
      if frameSize == 0: break

  # The tag records what the encoder added at each end, measured at its own
  # input. A decoder's output lags that by 529 samples, so the same 529 shifts
  # from the tail to the front rather than being trimmed twice.
  ## Without a tag there is nothing to trim: the lag correction only means
  ## anything alongside the delay the encoder recorded.
  const DecoderLag = 529
  let total = output.len div channels
  let front = if tagged: min(delay + DecoderLag, total) else: 0
  let count = if tagged: max(0, total - front - max(0, tail - DecoderLag))
              else: total
  result = initAudioBuffer(rate, channels, count)
  for index in 0 ..< count * channels:
    result.samples[index] = output[front * channels + index]

proc readMp3File*(path: string): AudioBuffer =
  readMp3(readFile(path))
