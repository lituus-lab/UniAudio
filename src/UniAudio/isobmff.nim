# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## ISO base media file format, enough to find audio samples in an MP4.
##
## An `.m4a` is a tree of boxes with the coded frames in one flat `mdat` and a
## set of tables in `stbl` saying where each starts and how long it is. A
## decoder needs the sample entry — which codec, and its setup bytes — and
## those tables; it needs nothing about edit lists, fragments or video.
##
## Every offset and count comes from a table an arbitrary file controls, so
## each is checked against the file's real length before it is used.

import contracts
import ./pcm

const
  MaxBoxDepth = 16
    ## Deeper than any real file; a cycle or a lie about sizes stops here.
  MaxSamples* = 1 shl 22
    ## Four million frames is hours of audio. A table claiming more is refused
    ## rather than allocated.

type
  SampleEntry* = object
    ## What `stsd` says the samples are.
    format*: string ## the four-character code, e.g. "alac"
    channels*: int
    bitsPerSample*: int
    sampleRate*: int
    setup*: string  ## codec-specific bytes: ALAC's magic cookie

  AudioTrack* = object
    ## One audio track, and where each of its coded frames lives.
    entry*: SampleEntry
    offsets*: seq[int] ## byte offset of each sample in the file
    sizes*: seq[int]   ## byte length of each sample

# ISOBMFF is big-endian throughout. Widened to `int`/`int64` on the way out so a
# 32-bit size near 2^32, or a 64-bit one, cannot come back negative and slip
# past a `> 0` check on its way to being used as a length.
proc beU16(data: string; offset: int): int =
  (int(uint8(data[offset])) shl 8) or int(uint8(data[offset + 1]))

proc beU32(data: string; offset: int): int64 =
  ## Four big-endian bytes: a box length, a table count, a 32-bit sample offset.
  result = 0
  for index in 0 .. 3:
    result = (result shl 8) or int64(uint8(data[offset + index]))

proc beU64(data: string; offset: int): int64 =
  ## Eight big-endian bytes: a `co64` offset, or a box whose 32-bit size was 1.
  result = 0
  for index in 0 .. 7:
    result = (result shl 8) or int64(uint8(data[offset + index]))

iterator boxes*(data: string; start, limit: int): tuple[kind: string;
    body, bodyEnd: int] =
  ## Each box between `start` and `limit`, as its kind and the span of its
  ## payload. A size of 0 means "to the end"; 1 means a 64-bit size follows.
  var offset = start
  while offset + 8 <= limit:
    var size = beU32(data, offset)
    let kind = data[offset + 4 ..< offset + 8]
    var header = 8
    if size == 1:
      if offset + 16 > limit: break
      size = beU64(data, offset + 8)
      header = 16
    elif size == 0:
      size = int64(limit - offset)
    if size < int64(header) or offset + int(size) > limit: break
    yield (kind, offset + header, offset + int(size))
    offset += int(size)

proc findBox*(data: string; start, limit: int; path: openArray[string];
              depth = 0): tuple[body, bodyEnd: int] =
  ## Walk a path of box kinds, e.g. ["moov", "trak", "mdia"]. Returns
  ## (-1, -1) when any step is missing.
  if depth > MaxBoxDepth or path.len == 0: return (-1, -1)
  for kind, body, bodyEnd in boxes(data, start, limit):
    if kind != path[0]: continue
    if path.len == 1: return (body, bodyEnd)
    let inner = findBox(data, body, bodyEnd, path[1 .. ^1], depth + 1)
    if inner.body >= 0: return inner
  (-1, -1)

proc parseSampleEntry(data: string; start, limit: int): SampleEntry =
  ## The first entry of `stsd`. An audio sample entry carries the channel
  ## count, bit depth and rate before any codec-specific box.
  if start + 8 > limit: raise newException(AudioError, "mp4: stsd is truncated")
  # stsd is a full box: version and flags, then an entry count.
  for kind, body, bodyEnd in boxes(data, start + 8, limit):
    # 6 reserved bytes, data reference index, 8 more reserved, then channels,
    # sample size, pre-defined, reserved, and a 16.16 sample rate.
    if body + 28 > bodyEnd: continue
    result.format = kind
    result.channels = beU16(data, body + 16)
    result.bitsPerSample = beU16(data, body + 18)
    result.sampleRate = int(beU32(data, body + 24) shr 16)
    # Whatever follows is the codec's own setup box.
    for inner, innerBody, innerEnd in boxes(data, body + 28, bodyEnd):
      if inner in ["alac", "esds", "dfLa", "dOps"]:
        result.setup = data[innerBody ..< innerEnd]
        break
    return
  raise newException(AudioError, "mp4: stsd holds no sample entry")

proc parseSampleTable(data: string; stbl, stblEnd: int;
                      track: var AudioTrack; fileLen: int) =
  ## Turn `stbl`'s tables into one offset and one length per coded frame.
  ##
  ## The file says where frames live in three pieces that have to be combined:
  ## `stsz` gives each frame's length, `stco` (or `co64`) the byte offset of each
  ## *chunk*, and `stsc` how many frames each chunk holds. A frame's offset is
  ## its chunk's offset plus the lengths of the frames before it in that chunk.
  ##
  ## Every number here comes from a table an arbitrary file controls, so each is
  ## checked before use: counts against `MaxSamples`, table extents against the
  ## box, and every resulting offset against `fileLen`. `stts` is only
  ## shape-checked — how many audio frames a coded frame carries is something the
  ## frames themselves say, so expanding that table would cost one integer per
  ## frame for nothing.
  var sizes: seq[int]
  var chunkOffsets: seq[int]
  # stsc maps a run of chunks to a samples-per-chunk count.
  var chunkRuns: seq[tuple[firstChunk, samplesPerChunk: int]]

  for kind, body, bodyEnd in boxes(data, stbl, stblEnd):
    case kind
    of "stsz":
      if body + 12 > bodyEnd: continue
      let uniform = int(beU32(data, body + 4))
      let count = int(beU32(data, body + 8))
      if count < 0 or count > MaxSamples:
        raise newException(AudioError, "mp4: implausible sample count")
      sizes = newSeq[int](count)
      if uniform != 0:
        for index in 0 ..< count: sizes[index] = uniform
      else:
        if body + 12 + count * 4 > bodyEnd:
          raise newException(AudioError, "mp4: stsz is truncated")
        for index in 0 ..< count:
          sizes[index] = int(beU32(data, body + 12 + index * 4))
    of "stco", "co64":
      if body + 8 > bodyEnd: continue
      let count = int(beU32(data, body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(AudioError, "mp4: implausible chunk count")
      let width = if kind == "stco": 4 else: 8
      if body + 8 + count * width > bodyEnd:
        raise newException(AudioError, "mp4: chunk offset table is truncated")
      chunkOffsets = newSeq[int](count)
      for index in 0 ..< count:
        chunkOffsets[index] =
          if width == 4: int(beU32(data, body + 8 + index * 4))
          else: int(beU64(data, body + 8 + index * 8))
    of "stsc":
      if body + 8 > bodyEnd: continue
      let count = int(beU32(data, body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(AudioError, "mp4: implausible stsc count")
      if body + 8 + count * 12 > bodyEnd:
        raise newException(AudioError, "mp4: stsc is truncated")
      for index in 0 ..< count:
        chunkRuns.add (int(beU32(data, body + 8 + index * 12)),
                       int(beU32(data, body + 8 + index * 12 + 4)))
    of "stts":
      # How many frames each sample carries. A decoder gets that from the
      # frames themselves, so only the table's shape is checked here: expanding
      # it would mean one integer per sample, for nothing.
      if body + 8 > bodyEnd: continue
      let count = int(beU32(data, body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(AudioError, "mp4: implausible stts count")
      if body + 8 + count * 8 > bodyEnd:
        raise newException(AudioError, "mp4: stts is truncated")
    else: discard

  if sizes.len == 0 or chunkOffsets.len == 0 or chunkRuns.len == 0:
    raise newException(AudioError, "mp4: sample table is incomplete")

  # Walk the chunks, handing each the samples stsc says it holds.
  track.sizes = sizes
  track.offsets = newSeq[int](sizes.len)
  var sample = 0
  var run = 0
  for chunk in 0 ..< chunkOffsets.len:
    while run + 1 < chunkRuns.len and chunkRuns[run + 1].firstChunk <= chunk + 1:
      inc run
    var offset = chunkOffsets[chunk]
    for _ in 0 ..< chunkRuns[run].samplesPerChunk:
      if sample >= sizes.len: break
      if offset < 0 or offset + sizes[sample] > fileLen:
        raise newException(AudioError, "mp4: a sample lies outside the file")
      track.offsets[sample] = offset
      offset += sizes[sample]
      inc sample
  if sample < sizes.len:
    raise newException(AudioError, "mp4: fewer chunks than samples")

proc readAudioTrack*(data: string): AudioTrack =
  ## The first audio track of an ISOBMFF file, with its sample entry and the
  ## location of every coded frame.
  let moov = findBox(data, 0, data.len, ["moov"])
  if moov.body < 0: raise newException(AudioError, "mp4: no moov box")
  for kind, body, bodyEnd in boxes(data, moov.body, moov.bodyEnd):
    if kind != "trak": continue
    let handler = findBox(data, body, bodyEnd, ["mdia", "hdlr"])
    if handler.body < 0 or handler.body + 12 > handler.bodyEnd: continue
    if data[handler.body + 8 ..< handler.body + 12] != "soun": continue
    let stbl = findBox(data, body, bodyEnd, ["mdia", "minf", "stbl"])
    if stbl.body < 0: continue
    let stsd = findBox(data, stbl.body, stbl.bodyEnd, ["stsd"])
    if stsd.body < 0: continue
    result.entry = parseSampleEntry(data, stsd.body, stsd.bodyEnd)
    # The media header carries the timescale, which is the real sample rate
    # when the sample entry's 16.16 field cannot express it.
    let mdhd = findBox(data, body, bodyEnd, ["mdia", "mdhd"])
    if mdhd.body >= 0 and mdhd.body + 24 <= mdhd.bodyEnd:
      let version = int(uint8(data[mdhd.body]))
      let timescale = if version == 0: int(beU32(data, mdhd.body + 12))
                      else: int(beU32(data, mdhd.body + 20))
      if timescale in 1 .. MaxSampleRate: result.entry.sampleRate = timescale
    parseSampleTable(data, stbl.body, stbl.bodyEnd, result, data.len)
    return
  raise newException(AudioError, "mp4: no audio track")

proc sampleData*(data: string; track: AudioTrack; index: int): string
    {.contractual.} =
  ## The bytes of one coded frame.
  require:
    index >= 0 and index < track.sizes.len
  body:
    data[track.offsets[index] ..< track.offsets[index] + track.sizes[index]]

func putBE(target: var string; value: int64; width: int) =
  ## Append `value` as `width` big-endian bytes. Bits above `width` are dropped,
  ## which is what lets a matrix entry like `0x00010000` be written as four bytes
  ## and a volume as two without either being masked at the call site.
  for index in countdown(width - 1, 0):
    target.add char(uint8((value shr (index * 8)) and 0xFF))

func box(kind: string; payload: string): string =
  ## A box is its own length, its four-character kind, then its payload.
  result.putBE(int64(payload.len + 8), 4)
  result.add kind
  result.add payload

func fullBox(kind: string; payload: string): string =
  ## A full box prefixes the payload with a version byte and three flag bytes,
  ## both zero for everything written here.
  box(kind, "\0\0\0\0" & payload)

proc buildAudioMp4*(coded: seq[string]; entry: SampleEntry;
                    framesPerSample, totalFrames: int): string
    {.contractual.} =
  ## An `.m4a` holding one audio track: `ftyp`, a `moov` describing where each
  ## coded frame sits, and the frames themselves in one `mdat` chunk.
  ##
  ## `stco` names the offset of that chunk, which depends on how long `moov`
  ## turned out to be, so `moov` is built twice — once to learn its length,
  ## once with the offset that length implies. The second build is the same
  ## size as the first, because the offset field is a fixed four bytes.
  require:
    coded.len > 0
    framesPerSample > 0
    totalFrames > 0
    entry.channels in 1 .. 2
    entry.sampleRate in 1 .. MaxSampleRate
    entry.format.len == 4
  body:
    var mdatBody: string
    var sizes: seq[int]
    for frame in coded:
      sizes.add frame.len
      mdatBody.add frame

    # The last sample carries whatever is left over, so `stts` needs two runs
    # unless the frame count divides evenly.
    let tail = totalFrames - (coded.len - 1) * framesPerSample
    var stts: string
    if tail == framesPerSample:
      stts.putBE(1, 4)
      stts.putBE(int64(coded.len), 4)
      stts.putBE(int64(framesPerSample), 4)
    else:
      stts.putBE(if coded.len == 1: 1 else: 2, 4)
      if coded.len > 1:
        stts.putBE(int64(coded.len - 1), 4)
        stts.putBE(int64(framesPerSample), 4)
      stts.putBE(1, 4)
      stts.putBE(int64(tail), 4)

    var stsz: string
    stsz.putBE(0, 4) # sizes differ per sample, so the table follows
    stsz.putBE(int64(sizes.len), 4)
    for size in sizes: stsz.putBE(int64(size), 4)

    var stsc: string
    stsc.putBE(1, 4) # one run: chunk 1 onwards
    stsc.putBE(1, 4)
    stsc.putBE(int64(coded.len), 4)
    stsc.putBE(1, 4)

    var sampleEntry: string
    sampleEntry.putBE(0, 6) # reserved
    sampleEntry.putBE(1, 2) # data reference index
    sampleEntry.putBE(0, 8) # reserved
    sampleEntry.putBE(int64(entry.channels), 2)
    sampleEntry.putBE(int64(entry.bitsPerSample), 2)
    sampleEntry.putBE(0, 2) # pre-defined
    sampleEntry.putBE(0, 2) # reserved
    sampleEntry.putBE(int64(entry.sampleRate) shl 16, 4) # 16.16 fixed point
    sampleEntry.add fullBox(entry.format, entry.setup)
    var stsd: string
    stsd.putBE(1, 4) # one entry
    stsd.add box(entry.format, sampleEntry)

    var dref: string
    dref.putBE(1, 4)
    # A "url " whose self-contained flag is set: the media is in this file.
    dref.add box("url ", "\0\0\0\1")

    const identity = [0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000]

    var mvhd: string
    mvhd.putBE(0, 8) # creation and modification time, left unset
    mvhd.putBE(int64(entry.sampleRate), 4)
    mvhd.putBE(int64(totalFrames), 4)
    mvhd.putBE(0x00010000, 4) # rate 1.0
    mvhd.putBE(0x0100, 2) # volume 1.0
    mvhd.putBE(0, 10) # reserved
    for value in identity: mvhd.putBE(int64(value), 4)
    mvhd.putBE(0, 24) # pre-defined
    mvhd.putBE(2, 4) # next track id

    var tkhd: string
    tkhd.putBE(0, 8)
    tkhd.putBE(1, 4) # track id
    tkhd.putBE(0, 4) # reserved
    tkhd.putBE(int64(totalFrames), 4)
    tkhd.putBE(0, 8) # reserved
    tkhd.putBE(0, 2) # layer
    tkhd.putBE(0, 2) # alternate group
    tkhd.putBE(0x0100, 2) # volume 1.0
    tkhd.putBE(0, 2) # reserved
    for value in identity: tkhd.putBE(int64(value), 4)
    tkhd.putBE(0, 8) # width and height, zero for audio

    var mdhd: string
    mdhd.putBE(0, 8)
    mdhd.putBE(int64(entry.sampleRate), 4)
    mdhd.putBE(int64(totalFrames), 4)
    mdhd.putBE(0x55C4, 2) # "und": no language claimed
    mdhd.putBE(0, 2) # pre-defined

    var hdlr: string
    hdlr.putBE(0, 4) # pre-defined
    hdlr.add "soun"
    hdlr.putBE(0, 12) # reserved
    hdlr.add '\0' # an empty name

    let dinf = box("dinf", fullBox("dref", dref))
    let smhd = fullBox("smhd", "\0\0\0\0") # balance, then reserved
    let ftyp = box("ftyp", "M4A \0\0\0\0M4A mp42isom")

    var moov: string
    for attempt in 0 .. 1:
      # The first pass measures; the second writes the offset that measurement
      # implies. `mdat`'s payload starts eight bytes past the end of `moov`.
      let chunkOffset = if attempt == 0: 0 else: ftyp.len + moov.len + 8
      var stco: string
      stco.putBE(1, 4)
      stco.putBE(int64(chunkOffset), 4)
      let stbl = box("stbl", fullBox("stsd", stsd) & fullBox("stts", stts) &
        fullBox("stsc", stsc) & fullBox("stsz", stsz) & fullBox("stco", stco))
      let minf = box("minf", smhd & dinf & stbl)
      let mdia = box("mdia", fullBox("mdhd", mdhd) & fullBox("hdlr", hdlr) &
        minf)
      let trak = box("trak", fullBox("tkhd", tkhd) & mdia)
      moov = box("moov", fullBox("mvhd", mvhd) & trak)

    ftyp & moov & box("mdat", mdatBody)


