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
    offsets*: seq[int]         ## byte offset of each sample in the file
    sizes*: seq[int]           ## byte length of each sample
    framesPerSample*: seq[int] ## decoded frames each sample carries

proc beU16(data: string; offset: int): int =
  (int(uint8(data[offset])) shl 8) or int(uint8(data[offset + 1]))

proc beU32(data: string; offset: int): int64 =
  result = 0
  for index in 0 .. 3:
    result = (result shl 8) or int64(uint8(data[offset + index]))

proc beU64(data: string; offset: int): int64 =
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
  var sizes: seq[int]
  var chunkOffsets: seq[int]
  var perFrame: seq[int]
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
      if body + 8 > bodyEnd: continue
      let count = int(beU32(data, body + 4))
      if count < 0 or count > MaxSamples:
        raise newException(AudioError, "mp4: implausible stts count")
      if body + 8 + count * 8 > bodyEnd:
        raise newException(AudioError, "mp4: stts is truncated")
      for index in 0 ..< count:
        let runLength = int(beU32(data, body + 8 + index * 8))
        let delta = int(beU32(data, body + 8 + index * 8 + 4))
        if runLength < 0 or runLength > MaxSamples:
          raise newException(AudioError, "mp4: implausible stts run")
        for _ in 0 ..< runLength: perFrame.add delta
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
  track.framesPerSample = perFrame

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


