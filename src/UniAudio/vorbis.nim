# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Vorbis I, decoded.
##
## Written against the Xiph Vorbis I specification, with `stb_vorbis` (public
## domain / MIT, Sean Barrett) consulted where the specification states things
## less directly. Both are named in NOTICE.
##
## A Vorbis stream carries no fixed tables: the setup header brings its own
## codebooks, its own spectral-envelope shapes and its own partitioning, so a
## decoder is largely a machine for reading that configuration and then
## applying it. Each audio packet is a spectrum, coded as a coarse envelope —
## the floor — times a fine structure — the residue. Multiplying them, running
## an inverse MDCT and overlapping with the previous packet gives samples.
##
## Floor type 0 is refused rather than approximated. It is the line-spectral
## representation no encoder has emitted since 2004, and decoding it wrongly
## would sound like audio rather than like an error.

import UniMath/native_float
import ./pcm
import ./fft
import ./ogg

const
  NoCode = 255'u8
  MaxCodeLength = 32
  MaxChannelsHere = 16
  MaxBlockSize = 8192
  MaxCodebookEntries = 1 shl 24

type
  Codebook = object
    dimensions, entries: int
    ## The Huffman codes as a binary trie: two children per node, a symbol on
    ## the leaves. Walking it consumes exactly the bits of one codeword, which
    ## is what the bitstream hands over.
    child: seq[array[2, int32]]
    leaf: seq[int32]
    lookupType: int
    sequenceP: bool
    ## One vector per entry, so the decode loop never divides.
    vectors: seq[float32]

  Floor1 = object
    partitions: int
    partitionClass: seq[int]
    classDimensions, classSubclasses, classMasterbook: seq[int]
    subclassBooks: seq[seq[int]]
    multiplier, rangeBits: int
    xList: seq[int]
    sortedOrder: seq[int]
    lowNeighbour, highNeighbour: seq[int]

  Residue = object
    kind: int
    first, last, partSize, classifications, classbook: int
    books: seq[array[8, int]]
    classData: seq[seq[uint8]]

  MappingChannel = object
    magnitude, angle, mux: int

  Mapping = object
    submaps, couplingSteps: int
    chan: seq[MappingChannel]
    submapFloor, submapResidue: seq[int]

  Mode = object
    longBlock: bool
    mapping: int

  VorbisSetup = object
    channels, sampleRate: int
    blockSize: array[2, int]
    codebooks: seq[Codebook]
    floors: seq[Floor1]
    residues: seq[Residue]
    mappings: seq[Mapping]
    modes: seq[Mode]
    window: array[2, seq[float32]]

  Reader = object
    ## Vorbis packs least-significant bit first, the opposite way round from
    ## FLAC and ALAC.
    data: string
    bit: int

func ilog(value: int): int =
  ## Bits needed to hold `value`: 0 for nothing, 1 for one, 3 for seven.
  var rest = value
  while rest > 0:
    inc result
    rest = rest shr 1

proc initReader(data: string): Reader = Reader(data: data, bit: 0)

proc read(reader: var Reader; count: int): uint32 =
  if count == 0: return 0
  if reader.bit + count > reader.data.len * 8:
    raise newException(AudioError, "vorbis: packet ended early")
  for index in 0 ..< count:
    let position = reader.bit + index
    let bit = (uint32(uint8(reader.data[position shr 3])) shr
      (position and 7)) and 1
    result = result or (bit shl index)
  reader.bit += count

proc readBit(reader: var Reader): bool = reader.read(1) != 0

func unpackFloat(bits: uint32): float32 =
  ## The 32-bit float the specification defines, which is not IEEE 754.
  let mantissa = float64(bits and 0x001f_ffff'u32)
  let exponent = int((bits and 0x7fe0_0000'u32) shr 21) - 788
  let signed = if (bits and 0x8000_0000'u32) != 0: -mantissa else: mantissa
  float32(signed * pow(2.0, float(exponent)))

func lookup1Values(entries, dimensions: int): int =
  ## The largest r with r to the power of `dimensions` at most `entries`.
  if dimensions <= 0: return 0
  while true:
    var power = 1
    for _ in 0 ..< dimensions:
      power *= result + 1
      if power > entries: return result
    inc result

proc insert(book: var Codebook; code: uint32; length, symbol: int) =
  ## Hang one codeword on the trie, `length` bits of it read from the top.
  var node = 0
  for depth in 0 ..< length:
    let bit = int((code shr (31 - depth)) and 1)
    if book.leaf[node] >= 0:
      raise newException(AudioError, "vorbis: a codeword prefixes another")
    if book.child[node][bit] < 0:
      book.child.add [-1'i32, -1'i32]
      book.leaf.add -1'i32
      book.child[node][bit] = int32(book.child.len - 1)
    node = int(book.child[node][bit])
  if book.leaf[node] >= 0 or book.child[node][0] >= 0 or
      book.child[node][1] >= 0:
    raise newException(AudioError, "vorbis: codebook is not a prefix code")
  book.leaf[node] = int32(symbol)

proc buildTrie(book: var Codebook; lengths: seq[uint8]) =
  ## Assign canonical codewords to the entries that have a length, then hang
  ## them on a trie. The specification allows the lengths in any order, so the
  ## codes cannot simply be handed out in sequence: each takes the lowest
  ## unused leaf at its depth, and the levels below it then become available.
  var available: array[MaxCodeLength, uint32]
  book.child = @[[-1'i32, -1'i32]]
  book.leaf = @[-1'i32]

  var first = -1
  for index in 0 ..< lengths.len:
    if lengths[index] != NoCode:
      first = index
      break
  if first < 0: return

  book.insert(0, int(lengths[first]), first)
  for depth in 1 .. int(lengths[first]):
    available[depth] = 1'u32 shl (32 - depth)

  for index in first + 1 ..< lengths.len:
    let length = int(lengths[index])
    if length == int(NoCode): continue
    var depth = length
    while depth > 0 and available[depth] == 0: dec depth
    if depth == 0:
      raise newException(AudioError, "vorbis: codebook is over-subscribed")
    let code = available[depth]
    available[depth] = 0
    book.insert(code, length, index)
    for level in countdown(length, depth + 1):
      available[level] = code + (1'u32 shl (32 - level))

proc decodeSymbol(reader: var Reader; book: Codebook): int =
  var node = 0
  for _ in 0 .. MaxCodeLength:
    if book.leaf[node] >= 0: return int(book.leaf[node])
    let next = book.child[node][int(reader.read(1))]
    if next < 0:
      raise newException(AudioError, "vorbis: codeword is not in the codebook")
    node = int(next)
  raise newException(AudioError, "vorbis: codeword runs past any legal length")

proc readCodebook(reader: var Reader): Codebook =
  if reader.read(24) != 0x564342'u32:
    raise newException(AudioError, "vorbis: codebook lacks its sync pattern")
  result.dimensions = int(reader.read(16))
  result.entries = int(reader.read(24))
  if result.entries > MaxCodebookEntries:
    raise newException(AudioError, "vorbis: implausible codebook size")
  if result.dimensions == 0 and result.entries != 0:
    raise newException(AudioError, "vorbis: codebook has entries but no shape")

  var lengths = newSeq[uint8](result.entries)
  if reader.readBit():
    # Lengths in ascending runs: each run says how many entries share it.
    var entry = 0
    var length = int(reader.read(5)) + 1
    while entry < result.entries:
      if length >= MaxCodeLength:
        raise newException(AudioError, "vorbis: codeword length is too long")
      let run = int(reader.read(ilog(result.entries - entry)))
      if entry + run > result.entries:
        raise newException(AudioError, "vorbis: length run overruns the book")
      for index in entry ..< entry + run: lengths[index] = uint8(length)
      entry += run
      inc length
  else:
    let sparse = reader.readBit()
    for index in 0 ..< result.entries:
      if sparse and not reader.readBit():
        lengths[index] = NoCode
      else:
        lengths[index] = uint8(reader.read(5) + 1)
        if lengths[index] >= uint8(MaxCodeLength):
          raise newException(AudioError, "vorbis: codeword length is too long")
  result.buildTrie(lengths)

  result.lookupType = int(reader.read(4))
  if result.lookupType > 2:
    raise newException(AudioError, "vorbis: unknown codebook lookup type")
  if result.lookupType == 0: return

  let minimum = unpackFloat(reader.read(32))
  let delta = unpackFloat(reader.read(32))
  let valueBits = int(reader.read(4)) + 1
  result.sequenceP = reader.readBit()
  let lookupValues = if result.lookupType == 1:
      lookup1Values(result.entries, result.dimensions)
    else: result.entries * result.dimensions
  if lookupValues <= 0:
    raise newException(AudioError, "vorbis: codebook lookup table is empty")

  var multiplicands = newSeq[float32](lookupValues)
  for index in 0 ..< lookupValues:
    multiplicands[index] = float32(reader.read(valueBits))

  # Both lookup types end up as one vector per entry. Type 1 stores its vectors
  # as the digits of the entry number in base `lookupValues`, which saves the
  # encoder space and costs a division the decoder need only pay once.
  result.vectors = newSeq[float32](result.entries * result.dimensions)
  for entry in 0 ..< result.entries:
    var last = 0.0'f32
    var divisor = 1
    for axis in 0 ..< result.dimensions:
      let offset = if result.lookupType == 1:
          (entry div divisor) mod lookupValues
        else: entry * result.dimensions + axis
      let value = multiplicands[offset] * delta + minimum + last
      result.vectors[entry * result.dimensions + axis] = value
      if result.sequenceP: last = value
      if result.lookupType == 1: divisor *= lookupValues

proc readFloor(reader: var Reader; codebookCount: int): Floor1 =
  let kind = int(reader.read(16))
  if kind == 0:
    raise newException(AudioError, "vorbis: floor type 0 is not decoded; " &
      "no encoder has produced it since 2004")
  if kind != 1:
    raise newException(AudioError, "vorbis: unknown floor type " & $kind)

  result.partitions = int(reader.read(5))
  result.partitionClass = newSeq[int](result.partitions)
  var maxClass = -1
  for index in 0 ..< result.partitions:
    result.partitionClass[index] = int(reader.read(4))
    maxClass = max(maxClass, result.partitionClass[index])

  result.classDimensions = newSeq[int](maxClass + 1)
  result.classSubclasses = newSeq[int](maxClass + 1)
  result.classMasterbook = newSeq[int](maxClass + 1)
  result.subclassBooks = newSeq[seq[int]](maxClass + 1)
  for index in 0 .. maxClass:
    result.classDimensions[index] = int(reader.read(3)) + 1
    result.classSubclasses[index] = int(reader.read(2))
    if result.classSubclasses[index] != 0:
      result.classMasterbook[index] = int(reader.read(8))
      if result.classMasterbook[index] >= codebookCount:
        raise newException(AudioError,
          "vorbis: floor names a codebook that is not there")
    result.subclassBooks[index] =
      newSeq[int](1 shl result.classSubclasses[index])
    for sub in 0 ..< result.subclassBooks[index].len:
      result.subclassBooks[index][sub] = int(reader.read(8)) - 1
      if result.subclassBooks[index][sub] >= codebookCount:
        raise newException(AudioError,
          "vorbis: floor names a codebook that is not there")

  result.multiplier = int(reader.read(2)) + 1
  result.rangeBits = int(reader.read(4))
  result.xList = @[0, 1 shl result.rangeBits]
  for index in 0 ..< result.partitions:
    let class = result.partitionClass[index]
    for _ in 0 ..< result.classDimensions[class]:
      result.xList.add int(reader.read(result.rangeBits))

  # The curve is drawn left to right, so the points are visited in order of x
  # rather than in the order the stream lists them.
  result.sortedOrder = newSeq[int](result.xList.len)
  for index in 0 ..< result.xList.len: result.sortedOrder[index] = index
  for outer in 1 ..< result.sortedOrder.len:
    var inner = outer
    while inner > 0 and result.xList[result.sortedOrder[inner - 1]] >
        result.xList[result.sortedOrder[inner]]:
      swap(result.sortedOrder[inner - 1], result.sortedOrder[inner])
      dec inner
  for index in 1 ..< result.sortedOrder.len:
    if result.xList[result.sortedOrder[index - 1]] ==
        result.xList[result.sortedOrder[index]]:
      raise newException(AudioError, "vorbis: floor lists a point twice")

  # Every point after the first two is predicted from the two already-known
  # points that bracket it.
  result.lowNeighbour = newSeq[int](result.xList.len)
  result.highNeighbour = newSeq[int](result.xList.len)
  for index in 2 ..< result.xList.len:
    var low = -1
    var high = 1 shl 30
    for earlier in 0 ..< index:
      let x = result.xList[earlier]
      if x > low and x < result.xList[index]:
        result.lowNeighbour[index] = earlier
        low = x
      if x < high and x > result.xList[index]:
        result.highNeighbour[index] = earlier
        high = x

proc readResidue(reader: var Reader; books: seq[Codebook]): Residue =
  result.kind = int(reader.read(16))
  if result.kind > 2:
    raise newException(AudioError,
      "vorbis: unknown residue type " & $result.kind)
  result.first = int(reader.read(24))
  result.last = int(reader.read(24))
  if result.last < result.first:
    raise newException(AudioError, "vorbis: residue ends before it begins")
  result.partSize = int(reader.read(24)) + 1
  result.classifications = int(reader.read(6)) + 1
  result.classbook = int(reader.read(8))
  if result.classbook >= books.len:
    raise newException(AudioError,
      "vorbis: residue names a codebook that is not there")

  var cascade = newSeq[int](result.classifications)
  for index in 0 ..< result.classifications:
    let low = int(reader.read(3))
    let high = if reader.readBit(): int(reader.read(5)) else: 0
    cascade[index] = high * 8 + low

  result.books = newSeq[array[8, int]](result.classifications)
  for index in 0 ..< result.classifications:
    for pass in 0 ..< 8:
      if (cascade[index] and (1 shl pass)) != 0:
        let book = int(reader.read(8))
        if book >= books.len:
          raise newException(AudioError,
            "vorbis: residue names a codebook that is not there")
        result.books[index][pass] = book
      else:
        result.books[index][pass] = -1

  # One classification word covers several partitions, as digits in base
  # `classifications`; unpacking them once here keeps a divide out of the
  # decode loop.
  let words = books[result.classbook].dimensions
  result.classData = newSeq[seq[uint8]](books[result.classbook].entries)
  for entry in 0 ..< result.classData.len:
    result.classData[entry] = newSeq[uint8](words)
    var rest = entry
    for digit in countdown(words - 1, 0):
      result.classData[entry][digit] = uint8(rest mod result.classifications)
      rest = rest div result.classifications

proc readMapping(reader: var Reader;
                 channels, floorCount, residueCount: int): Mapping =
  if reader.read(16) != 0:
    raise newException(AudioError, "vorbis: unknown mapping type")
  result.chan = newSeq[MappingChannel](channels)
  result.submaps = if reader.readBit(): int(reader.read(4)) + 1 else: 1
  if reader.readBit():
    result.couplingSteps = int(reader.read(8)) + 1
    if result.couplingSteps > channels:
      raise newException(AudioError,
        "vorbis: more coupling steps than channels")
    for step in 0 ..< result.couplingSteps:
      result.chan[step].magnitude = int(reader.read(ilog(channels - 1)))
      result.chan[step].angle = int(reader.read(ilog(channels - 1)))
      if result.chan[step].magnitude >= channels or
          result.chan[step].angle >= channels or
          result.chan[step].magnitude == result.chan[step].angle:
        raise newException(AudioError,
          "vorbis: coupling names an impossible channel pair")
  if reader.read(2) != 0:
    raise newException(AudioError, "vorbis: reserved mapping field is set")
  if result.submaps > 1:
    for channel in 0 ..< channels:
      result.chan[channel].mux = int(reader.read(4))
      if result.chan[channel].mux >= result.submaps:
        raise newException(AudioError,
          "vorbis: channel names a submap that is not there")
  result.submapFloor = newSeq[int](result.submaps)
  result.submapResidue = newSeq[int](result.submaps)
  for submap in 0 ..< result.submaps:
    discard reader.read(8)
    result.submapFloor[submap] = int(reader.read(8))
    result.submapResidue[submap] = int(reader.read(8))
    if result.submapFloor[submap] >= floorCount or
        result.submapResidue[submap] >= residueCount:
      raise newException(AudioError,
        "vorbis: submap names a floor or residue that is not there")

func halfWindow(size: int): seq[float32] =
  ## The rising half of the Vorbis window, `size/2` points of it. A sine of a
  ## sine, shaped so a rising and a falling window sum to one wherever they
  ## overlap — which is what makes the overlap-add reconstruct the signal.
  let half = size div 2
  result = newSeq[float32](half)
  for index in 0 ..< half:
    let inner = sin((float(index) + 0.5) / float(half) * 0.5 * PI)
    result[index] = float32(sin(0.5 * PI * inner * inner))

proc readHeaders(packets: seq[OggPacket]): VorbisSetup =
  if packets.len < 3:
    raise newException(AudioError, "vorbis: the three headers are not all there")
  for index, expected in [1'u8, 3'u8, 5'u8]:
    if packets[index].data.len < 7 or
        uint8(packets[index].data[0]) != expected or
        packets[index].data[1 .. 6] != "vorbis":
      raise newException(AudioError,
        "vorbis: header " & $(index + 1) & " is not one")

  var identification = initReader(packets[0].data[7 .. ^1])
  if identification.read(32) != 0:
    raise newException(AudioError, "vorbis: unknown bitstream version")
  result.channels = int(identification.read(8))
  result.sampleRate = int(identification.read(32))
  if result.channels notin 1 .. MaxChannelsHere:
    raise newException(AudioError, "vorbis: " & $result.channels & " channels")
  if result.sampleRate notin 1 .. MaxSampleRate:
    raise newException(AudioError, "vorbis: implausible sample rate")
  discard identification.read(32) # bitrate maximum
  discard identification.read(32) # bitrate nominal
  discard identification.read(32) # bitrate minimum
  let sizes = int(identification.read(8))
  let shortLog = sizes and 15
  let longLog = sizes shr 4
  if shortLog notin 6 .. 13 or longLog notin 6 .. 13 or shortLog > longLog:
    raise newException(AudioError, "vorbis: impossible block sizes")
  result.blockSize = [1 shl shortLog, 1 shl longLog]
  if result.blockSize[1] > MaxBlockSize:
    raise newException(AudioError, "vorbis: block size is too large")
  if not identification.readBit():
    raise newException(AudioError, "vorbis: identification header is unframed")
  result.window = [halfWindow(result.blockSize[0]),
                   halfWindow(result.blockSize[1])]

  # The comment header carries tags, which this decoder does not need.
  var setup = initReader(packets[2].data[7 .. ^1])

  result.codebooks = newSeq[Codebook](int(setup.read(8)) + 1)
  for index in 0 ..< result.codebooks.len:
    result.codebooks[index] = readCodebook(setup)

  # Time-domain transforms: a field the format reserved and never used.
  for _ in 0 ..< int(setup.read(6)) + 1:
    if setup.read(16) != 0:
      raise newException(AudioError, "vorbis: unknown time-domain transform")

  result.floors = newSeq[Floor1](int(setup.read(6)) + 1)
  for index in 0 ..< result.floors.len:
    result.floors[index] = readFloor(setup, result.codebooks.len)

  result.residues = newSeq[Residue](int(setup.read(6)) + 1)
  for index in 0 ..< result.residues.len:
    result.residues[index] = readResidue(setup, result.codebooks)

  result.mappings = newSeq[Mapping](int(setup.read(6)) + 1)
  for index in 0 ..< result.mappings.len:
    result.mappings[index] = readMapping(setup, result.channels,
      result.floors.len, result.residues.len)

  result.modes = newSeq[Mode](int(setup.read(6)) + 1)
  for index in 0 ..< result.modes.len:
    result.modes[index].longBlock = setup.readBit()
    if setup.read(16) != 0 or setup.read(16) != 0:
      raise newException(AudioError, "vorbis: unknown window or transform type")
    result.modes[index].mapping = int(setup.read(8))
    if result.modes[index].mapping >= result.mappings.len:
      raise newException(AudioError,
        "vorbis: mode names a mapping that is not there")
  if not setup.readBit():
    raise newException(AudioError, "vorbis: setup header is unframed")

const inverseDb = block:
  # The floor is coded in decibels; this undoes it. The specification prints
  # all 256 values, which are this expression rounded to single precision.
  #
  # Built at compile time, for the same reason as the Ogg checksum table: a
  # table filled on first use is mutable global state and a race between
  # threads.
  var table: array[256, float32]
  for index in 0 ..< 256:
    table[index] = float32(pow(10.0, float(index - 255) * 7.0 / 256.0))
  table

func predictPoint(x, x0, x1, y0, y1: int): int =
  let dy = y1 - y0
  let offset = (abs(dy) * (x - x0)) div (x1 - x0)
  if dy < 0: y0 - offset else: y0 + offset

proc drawLine(target: var seq[float32]; x0, y0, x1, y1, limit: int) =
  ## The floor between two of its points, in the integer steps the encoder
  ## used. A floating-point line would decode differently on different
  ## hardware, so the format specifies this one exactly.
  let dy = y1 - y0
  let adx = x1 - x0
  var ady = abs(dy)
  let base = dy div adx
  let step = if dy < 0: base - 1 else: base + 1
  ady -= abs(base) * adx
  var x = x0
  var y = y0
  var error = 0
  let stop = min(x1, limit)
  if x < stop:
    target[x] *= inverseDb[y and 255]
    inc x
    while x < stop:
      error += ady
      if error >= adx:
        error -= adx
        y += step
      else:
        y += base
      target[x] *= inverseDb[y and 255]
      inc x

proc applyFloor(floor: Floor1; finalY: seq[int]; target: var seq[float32];
                half: int) =
  var lowX = 0
  var lowY = finalY[0] * floor.multiplier
  for order in 1 ..< floor.xList.len:
    let point = floor.sortedOrder[order]
    if finalY[point] < 0: continue
    let highY = finalY[point] * floor.multiplier
    let highX = floor.xList[point]
    if lowX != highX:
      drawLine(target, lowX, lowY, highX, highY, half)
    lowX = highX
    lowY = highY
  for index in lowX ..< half:
    target[index] *= inverseDb[lowY and 255]

proc decodeFloor(reader: var Reader; setup: VorbisSetup; floor: Floor1;
                 finalY: var seq[int]): bool =
  ## The spectral envelope of one channel, as the y of each of its points.
  ## False means the packet declared this channel silent.
  if not reader.readBit(): return false
  const RangeOf = [256, 128, 86, 64]
  let range = RangeOf[floor.multiplier - 1]
  finalY.setLen(floor.xList.len)
  finalY[0] = int(reader.read(ilog(range) - 1))
  finalY[1] = int(reader.read(ilog(range) - 1))

  var offset = 2
  for partition in 0 ..< floor.partitions:
    let class = floor.partitionClass[partition]
    let bits = floor.classSubclasses[class]
    let mask = (1 shl bits) - 1
    var value = 0
    if bits != 0:
      value = decodeSymbol(reader,
        setup.codebooks[floor.classMasterbook[class]])
    for _ in 0 ..< floor.classDimensions[class]:
      let book = floor.subclassBooks[class][value and mask]
      value = value shr bits
      finalY[offset] =
        if book >= 0: decodeSymbol(reader, setup.codebooks[book]) else: 0
      inc offset

  # Every point after the first two is a correction to what its two known
  # neighbours predict, folded so that small corrections cost few bits.
  var present = newSeq[bool](floor.xList.len)
  present[0] = true
  present[1] = true
  for index in 2 ..< floor.xList.len:
    let low = floor.lowNeighbour[index]
    let high = floor.highNeighbour[index]
    let predicted = predictPoint(floor.xList[index], floor.xList[low],
      floor.xList[high], finalY[low], finalY[high])
    let coded = finalY[index]
    let highRoom = range - predicted
    let lowRoom = predicted
    let room = 2 * min(highRoom, lowRoom)
    if coded != 0:
      present[low] = true
      present[high] = true
      present[index] = true
      finalY[index] =
        if coded >= room:
          if highRoom > lowRoom: coded - lowRoom + predicted
          else: predicted - coded + highRoom - 1
        elif (coded and 1) != 0: predicted - ((coded + 1) shr 1)
        else: predicted + (coded shr 1)
    else:
      finalY[index] = predicted
  # A point nothing referred to is not drawn; the curve passes over it.
  for index in 0 ..< floor.xList.len:
    if not present[index]: finalY[index] = -1
  true

proc decodeResidue(reader: var Reader; setup: VorbisSetup; residue: Residue;
                   buffers: var seq[seq[float32]]; used: seq[int];
                   half: int) =
  ## The fine spectral structure, added into each channel's buffer.
  ##
  ## Eight passes over the same partitions, each refining what the last left:
  ## a partition's class chooses which codebook, if any, that pass uses for it.
  let channels = used.len
  let interleaved = residue.kind == 2 and channels != 1
  let span = if interleaved: half * channels else: half
  let first = min(residue.first, span)
  let last = min(residue.last, span)
  let partitions = (last - first) div residue.partSize
  if partitions <= 0: return

  let classbook = setup.codebooks[residue.classbook]
  let words = classbook.dimensions
  var classes = newSeq[seq[uint8]](channels)
  for channel in 0 ..< channels:
    classes[channel] = newSeq[uint8](partitions + words)

  if interleaved:
    var anyUsed = false
    for channel in 0 ..< channels:
      if used[channel] >= 0: anyUsed = true
    if not anyUsed: return
    for pass in 0 ..< 8:
      var partition = 0
      var wordIndex = 0
      var channelIndex = first mod channels
      var position = first div channels
      while partition < partitions:
        if pass == 0:
          let entry = decodeSymbol(reader, classbook)
          for digit in 0 ..< words:
            classes[0][wordIndex + digit] = residue.classData[entry][digit]
        var step = 0
        while step < words and partition < partitions:
          let book = residue.books[int(classes[0][partition])][pass]
          if book >= 0:
            var remaining = residue.partSize
            let vectorBook = setup.codebooks[book]
            while remaining > 0:
              let entry = decodeSymbol(reader, vectorBook)
              let base = entry * vectorBook.dimensions
              for axis in 0 ..< vectorBook.dimensions:
                if remaining <= 0: break
                if position < half:
                  buffers[channelIndex][position] +=
                    vectorBook.vectors[base + axis]
                inc channelIndex
                if channelIndex == channels:
                  channelIndex = 0
                  inc position
                dec remaining
          else:
            let at = first + (partition + 1) * residue.partSize
            channelIndex = at mod channels
            position = at div channels
          inc step
          inc partition
        wordIndex += words
    return

  for pass in 0 ..< 8:
    var partition = 0
    var wordIndex = 0
    while partition < partitions:
      if pass == 0:
        for channel in 0 ..< channels:
          if used[channel] < 0: continue
          let entry = decodeSymbol(reader, classbook)
          for digit in 0 ..< words:
            classes[channel][wordIndex + digit] = residue.classData[entry][digit]
      var step = 0
      while step < words and partition < partitions:
        for channel in 0 ..< channels:
          if used[channel] < 0: continue
          let book = residue.books[int(classes[channel][partition])][pass]
          if book < 0: continue
          let vectorBook = setup.codebooks[book]
          let at = first + partition * residue.partSize
          if residue.kind == 0:
            # Elements strided across the partition rather than consecutive.
            let stride = residue.partSize div vectorBook.dimensions
            for start in 0 ..< stride:
              let entry = decodeSymbol(reader, vectorBook)
              let base = entry * vectorBook.dimensions
              for axis in 0 ..< vectorBook.dimensions:
                let target = at + start + axis * stride
                if target < half:
                  buffers[channel][target] += vectorBook.vectors[base + axis]
          else:
            var written = 0
            while written < residue.partSize:
              let entry = decodeSymbol(reader, vectorBook)
              let base = entry * vectorBook.dimensions
              for axis in 0 ..< vectorBook.dimensions:
                let target = at + written + axis
                if target < half:
                  buffers[channel][target] += vectorBook.vectors[base + axis]
              written += vectorBook.dimensions
        inc step
        inc partition
      wordIndex += words

proc imdct(spectrum: var seq[float32]; size: int) =
  ## Inverse modified discrete cosine transform: `size/2` coefficients in,
  ## `size` samples out, written over the input.
  ##
  ## Routed through a type-IV discrete cosine transform, which is one complex
  ## transform of length `size` between two twiddles. Straight from the
  ## definition it would be a quadratic sum — for a 2048-point block, a
  ## hundredfold more arithmetic.
  let half = size div 2
  let quarter = size div 4
  var work = newSeq[Complex](size)
  for index in 0 ..< half:
    let angle = -PI * float(index) / float(2 * half)
    work[index] = Complex(re: float(spectrum[index]) * cos(angle),
                          im: float(spectrum[index]) * sin(angle))
  fft(work)

  var cosine = newSeq[float64](half)
  for index in 0 ..< half:
    let angle = -PI * float(2 * index + 1) / float(4 * half)
    cosine[index] = work[index].re * cos(angle) - work[index].im * sin(angle)

  # The transform repeats with a sign flip, so half of it spells out the block.
  for index in 0 ..< quarter:
    spectrum[index] = float32(cosine[index + quarter])
  for index in quarter ..< 3 * quarter:
    spectrum[index] = float32(-cosine[3 * quarter - 1 - index])
  for index in 3 * quarter ..< size:
    spectrum[index] = float32(-cosine[index - 3 * quarter])

proc decodeAudio(reader: var Reader; setup: VorbisSetup;
                 buffers: var seq[seq[float32]]): tuple[left, right,
                 windowEnd: int] =
  ## One audio packet into `buffers`, and the window it covers.
  if reader.readBit():
    raise newException(AudioError, "vorbis: audio packet has the wrong type")
  let modeIndex = int(reader.read(ilog(setup.modes.len - 1)))
  if modeIndex >= setup.modes.len:
    raise newException(AudioError,
      "vorbis: packet names a mode that is not there")
  let mode = setup.modes[modeIndex]
  let size = setup.blockSize[if mode.longBlock: 1 else: 0]
  let half = size div 2
  let shortSize = setup.blockSize[0]

  # A long block next to a short one narrows its window on that side, so the
  # two still overlap over the same span.
  var previousLong = true
  var nextLong = true
  if mode.longBlock:
    previousLong = reader.readBit()
    nextLong = reader.readBit()
  let leftStart = if mode.longBlock and not previousLong:
      (size - shortSize) div 4 else: 0
  let rightStart = if mode.longBlock and not nextLong:
      (size * 3 - shortSize) div 4 else: half
  # Where this block's falling window reaches zero. Past it the samples are
  # nothing, and the overlap with the next block spans rightEnd - rightStart.
  let rightEnd = if mode.longBlock and not nextLong:
      (size * 3 + shortSize) div 4 else: size

  let mapping = setup.mappings[mode.mapping]
  var silent = newSeq[bool](setup.channels)
  var finalY = newSeq[seq[int]](setup.channels)
  for channel in 0 ..< setup.channels:
    let floor = setup.floors[mapping.submapFloor[mapping.chan[channel].mux]]
    finalY[channel] = @[]
    silent[channel] = not decodeFloor(reader, setup, floor, finalY[channel])

  # A silent channel still has to be decoded when it is coupled to one that is
  # not: the pair only means anything together.
  let reallySilent = silent
  for step in 0 ..< mapping.couplingSteps:
    if not silent[mapping.chan[step].magnitude] or
        not silent[mapping.chan[step].angle]:
      silent[mapping.chan[step].magnitude] = false
      silent[mapping.chan[step].angle] = false

  for channel in 0 ..< setup.channels:
    if buffers[channel].len < size: buffers[channel].setLen(size)
    for index in 0 ..< size: buffers[channel][index] = 0

  for submap in 0 ..< mapping.submaps:
    var members: seq[int]
    var used: seq[int]
    for channel in 0 ..< setup.channels:
      if mapping.chan[channel].mux == submap:
        members.add channel
        used.add (if silent[channel]: -1 else: channel)
    if members.len == 0: continue
    var slice = newSeq[seq[float32]](members.len)
    for index, channel in members: slice[index] = move(buffers[channel])
    decodeResidue(reader, setup, setup.residues[mapping.submapResidue[submap]],
      slice, used, half)
    for index, channel in members: buffers[channel] = move(slice[index])

  # Undo the magnitude/angle pair the encoder folded the channels into.
  for step in countdown(mapping.couplingSteps - 1, 0):
    let magnitude = mapping.chan[step].magnitude
    let angle = mapping.chan[step].angle
    for index in 0 ..< half:
      let m = buffers[magnitude][index]
      let a = buffers[angle][index]
      var newM, newA: float32
      if m > 0:
        if a > 0: (newM, newA) = (m, m - a)
        else: (newM, newA) = (m + a, m)
      else:
        if a > 0: (newM, newA) = (m, m + a)
        else: (newM, newA) = (m - a, m)
      buffers[magnitude][index] = newM
      buffers[angle][index] = newA

  for channel in 0 ..< setup.channels:
    if reallySilent[channel]:
      for index in 0 ..< half: buffers[channel][index] = 0
    else:
      let floor = setup.floors[mapping.submapFloor[mapping.chan[channel].mux]]
      applyFloor(floor, finalY[channel], buffers[channel], half)
    imdct(buffers[channel], size)

  (leftStart, rightStart, rightEnd)

proc readVorbis*(data: string): AudioBuffer =
  ## Decode the Vorbis stream of an Ogg file held in memory.
  let packets = oggPackets(data)
  let setup = readHeaders(packets)

  var buffers = newSeq[seq[float32]](setup.channels)
  var previous = newSeq[seq[float32]](setup.channels)
  var output = newSeq[seq[float32]](setup.channels)
  for channel in 0 ..< setup.channels:
    buffers[channel] = newSeq[float32](setup.blockSize[1])
    previous[channel] = newSeq[float32](setup.blockSize[1] div 2)
  var previousLength = 0

  for index in 3 ..< packets.len:
    var reader = initReader(packets[index].data)
    let (left, right, windowEnd) = decodeAudio(reader, setup, buffers)

    # The first packet has nothing to overlap with, so it contributes no
    # samples: half of every block is only half a window until the next one
    # arrives to complete it.
    if previousLength > 0:
      let window = setup.window[
        if previousLength * 2 == setup.blockSize[0]: 0 else: 1]
      for channel in 0 ..< setup.channels:
        for offset in 0 ..< previousLength:
          buffers[channel][left + offset] =
            buffers[channel][left + offset] * window[offset] +
            previous[channel][offset] * window[previousLength - 1 - offset]
        for offset in left ..< right:
          output[channel].add buffers[channel][offset]

    previousLength = windowEnd - right
    for channel in 0 ..< setup.channels:
      for offset in 0 ..< previousLength:
        previous[channel][offset] = buffers[channel][right + offset]

  var frames = output[0].len
  # The last page's granule states where the stream really ends; the final
  # block runs past it, and that tail is padding the encoder added.
  let granule = packets[^1].granule
  if granule >= 0 and granule < frames: frames = int(granule)

  result = initAudioBuffer(setup.sampleRate, setup.channels, frames)
  for index in 0 ..< frames:
    for channel in 0 ..< setup.channels:
      # A Vorbis stream may reconstruct past unity where the encoder pushed a
      # loud passage; every player clamps it, and so does the buffer contract.
      result.samples[index * setup.channels + channel] =
        clamp(output[channel][index], -1.0'f32, 1.0'f32)

proc readVorbisFile*(path: string): AudioBuffer =
  readVorbis(readFile(path))
