# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What an audio file is, from its header alone.
##
## `decode` answers the same questions but reads the whole file to do it --
## FLAC and MP4 keep tables after the audio, so neither decodes from a
## forward-only stream. A catalogue asking "how long is this" of ten thousand
## files cannot pay that, and over a network share it cannot pay it at all.
##
## Every container states its rate and channel count in a header near the
## front. The frame count is stated by WAVE, AIFF, FLAC and MP4; Ogg keeps it
## in the last page and MPEG audio in an optional Xing header, so for those two
## `framesKnown` is false when nothing says it and `format.frames` stays zero.

import std/strutils
import ./pcm
import ./decode
import ./isobmff

type AudioProbe* = object
  ## What the header says. `format.frames` is zero unless `framesKnown`.
  container*: Container
  codec*: string
    ## The four-character code for MP4, otherwise the container's own name.
  format*: AudioFormat
  framesKnown*: bool

func beU16(data: string; at: int): int =
  (int(uint8(data[at])) shl 8) or int(uint8(data[at + 1]))

func beU32(data: string; at: int): int64 =
  result = 0
  for index in 0 ..< 4: result = (result shl 8) or int64(uint8(data[at + index]))

func leU16(data: string; at: int): int =
  int(uint8(data[at])) or (int(uint8(data[at + 1])) shl 8)

func leU32(data: string; at: int): int64 =
  result = 0
  for index in countdown(3, 0):
    result = (result shl 8) or int64(uint8(data[at + index]))

proc probeWave(data: string): AudioProbe =
  ## `fmt ` gives the shape, `data` gives the length. Chunks are walked rather
  ## than assumed adjacent: a WAVE may carry `LIST` or `fact` between them.
  result.container = acWave
  result.codec = "wav"
  var at = 12
  var bits = 0
  var dataBytes = 0'i64
  while at + 8 <= data.len:
    let id = data[at ..< at + 4]
    let size = leU32(data, at + 4)
    let body = at + 8
    if size < 0 or body + int(size) > data.len: break
    if id == "fmt " and size >= 16:
      result.format.channels = leU16(data, body + 2)
      result.format.sampleRate = int(leU32(data, body + 4))
      bits = leU16(data, body + 14)
    elif id == "data":
      dataBytes = size
    at = body + int(size) + (int(size) and 1)
  if bits > 0 and result.format.channels > 0 and dataBytes > 0:
    let bytesPerFrame = result.format.channels * (bits div 8)
    if bytesPerFrame > 0:
      result.format.frames = int(dataBytes div bytesPerFrame)
      result.framesKnown = true

proc probeAiff(data: string): AudioProbe =
  ## `COMM` states the frame count outright, and the rate as an 80-bit float.
  result.container = acAiff
  result.codec = "aiff"
  var at = 12
  while at + 8 <= data.len:
    let id = data[at ..< at + 4]
    let size = beU32(data, at + 4)
    let body = at + 8
    if size < 0 or body + int(size) > data.len: break
    if id == "COMM" and size >= 18:
      result.format.channels = beU16(data, body)
      result.format.frames = int(beU32(data, body + 2))
      # An 80-bit extended float, of which a sample rate only ever uses the
      # exponent and the top of the mantissa.
      let exponent = beU16(data, body + 8) - 16383
      var mantissa = 0'i64
      for index in 0 ..< 8:
        mantissa = (mantissa shl 8) or int64(uint8(data[body + 10 + index]))
      if exponent >= 0 and exponent < 63:
        result.format.sampleRate = int(mantissa shr (63 - exponent))
      result.framesKnown = result.format.frames > 0
    at = body + int(size) + (int(size) and 1)

proc probeFlac(data: string): AudioProbe =
  ## STREAMINFO is the first metadata block and is fixed width: the rate is 20
  ## bits, the channel count 3, and the total sample count 36.
  result.container = acFlac
  result.codec = "flac"
  if data.len < 42: return
  let body = 8 # "fLaC" plus the block header
  let rate = (int(uint8(data[body + 10])) shl 12) or
             (int(uint8(data[body + 11])) shl 4) or
             (int(uint8(data[body + 12])) shr 4)
  result.format.sampleRate = rate
  result.format.channels = ((int(uint8(data[body + 12])) shr 1) and 0x07) + 1
  # The 36-bit total sample count starts in the low nibble of byte 13 and runs
  # through byte 17 -- the five bits of bits-per-sample sit between it and the
  # channel count, so it does not begin on a byte boundary.
  var total = int64(int(uint8(data[body + 13])) and 0x0F)
  for index in 0 ..< 4:
    total = (total shl 8) or int64(uint8(data[body + 14 + index]))
  result.format.frames = int(total)
  result.framesKnown = total > 0

proc probeIsoBmff(data: string): AudioProbe =
  ## The sample entry gives the rate and the channels; `mdhd` gives the length
  ## in its own timescale, which is the audio rate for an audio track.
  result.container = acIsoBmff
  let track = readAudioTrack(data)
  result.codec = track.entry.format
  result.format.sampleRate = track.entry.sampleRate
  result.format.channels = track.entry.channels
  let moov = findBox(data, 0, data.len, ["moov"])
  if moov.body < 0: return
  for kind, body, bodyEnd in boxes(data, moov.body, moov.bodyEnd):
    if kind != "trak": continue
    let hdlr = findBox(data, body, bodyEnd, ["mdia", "hdlr"])
    if hdlr.body < 0 or hdlr.body + 12 > hdlr.bodyEnd: continue
    if data[hdlr.body + 8 ..< hdlr.body + 12] != "soun": continue
    let mdhd = findBox(data, body, bodyEnd, ["mdia", "mdhd"])
    if mdhd.body < 0 or mdhd.body + 24 > mdhd.bodyEnd: continue
    let version = int(uint8(data[mdhd.body]))
    let timescale = if version == 1: beU32(data, mdhd.body + 12)
                    else: beU32(data, mdhd.body + 12)
    var duration = 0'i64
    if version == 1:
      for index in 0 ..< 8:
        duration = (duration shl 8) or int64(uint8(data[mdhd.body + 16 + index]))
    else:
      duration = beU32(data, mdhd.body + 16)
    if timescale > 0 and duration > 0 and result.format.sampleRate > 0:
      result.format.frames =
        int(duration * int64(result.format.sampleRate) div timescale)
      result.framesKnown = true
    break

proc probeOgg(data: string): AudioProbe =
  ## The Vorbis identification header is the first packet of the first page.
  ## The length lives in the granule position of the last page, which is why it
  ## is not read here: finding it means seeking to the end of the file.
  result.container = acOgg
  result.codec = "ogg"
  # Bounded to the first page: the identification header is the first packet,
  # and scanning a whole file for those seven bytes would find a later match in
  # the audio itself.
  let limit = min(data.len, 4096)
  let head = data.find("\x01vorbis", 0, limit - 1)
  if head < 0 or head + 16 > data.len: return
  result.format.channels = int(uint8(data[head + 11]))
  result.format.sampleRate = int(leU32(data, head + 12))

const
  MpegRates = [
    [11025, 12000, 8000, 0],  # MPEG 2.5
    [0, 0, 0, 0],             # reserved
    [22050, 24000, 16000, 0], # MPEG 2
    [44100, 48000, 32000, 0]] # MPEG 1

proc probeMpeg(data: string): AudioProbe =
  ## The first frame header carries the rate and the channel mode. The frame
  ## count is only stated by an optional Xing or VBRI header, so a file without
  ## one reports no length rather than an estimate that would be wrong for
  ## anything but a constant bit rate.
  result.container = acMpegAudio
  result.codec = "mp3"
  var at = 0
  # An ID3v2 tag sits before the audio; its size is four seven-bit bytes.
  if data.len > 10 and data[0 .. 2] == "ID3":
    var size = 0
    for index in 0 ..< 4:
      size = (size shl 7) or (int(uint8(data[6 + index])) and 0x7F)
    at = 10 + size
  while at + 4 <= data.len:
    if uint8(data[at]) == 0xFF and (uint8(data[at + 1]) and 0xE0'u8) == 0xE0'u8:
      break
    inc at
  if at + 4 > data.len: return
  let versionBits = (int(uint8(data[at + 1])) shr 3) and 0x03
  let rateIndex = (int(uint8(data[at + 2])) shr 2) and 0x03
  result.format.sampleRate = MpegRates[versionBits][rateIndex]
  let mode = (int(uint8(data[at + 3])) shr 6) and 0x03
  result.format.channels = if mode == 3: 1 else: 2

proc probeAudio*(data: string): AudioProbe =
  ## What the bytes say they are, without decoding them.
  ##
  ## The container is named for anything recognised, even where the rate and
  ## the length are not stated in a header this reads: a caller learns what the
  ## file is either way, and `framesKnown` says whether the length is real.
  result.container = sniff(data)
  case result.container
  of acWave: probeWave(data)
  of acAiff: probeAiff(data)
  of acFlac: probeFlac(data)
  of acIsoBmff: probeIsoBmff(data)
  of acOgg: probeOgg(data)
  of acMpegAudio: probeMpeg(data)
  of acUnknown:
    raise newException(AudioError, "unrecognised audio container")

const ProbePrefixBytes* = 128 * 1024
  ## How much of a file the bounded read takes. Every header this parses sits
  ## within it -- WAVE and AIFF state their length in a chunk header, FLAC's
  ## STREAMINFO is the first metadata block, Vorbis puts its identification
  ## packet in the first page, and an MPEG frame header follows the ID3 tag.

proc probeAudioFile*(path: string): AudioProbe =
  ## `probeAudio` over a file, reading only its head where that is enough.
  ##
  ## An ISO base media file is the exception: `moov` is as often at the end as
  ## at the front, so one that does not parse from the prefix is read whole.
  ## For everything else this is a fixed cost whatever the file's length, which
  ## is what lets a catalogue ask this of every track it holds.
  var handle: File
  if not open(handle, path, fmRead):
    raise newException(IOError, "cannot open " & path)
  var prefix: string
  try:
    prefix = newString(ProbePrefixBytes)
    let read = handle.readBuffer(addr prefix[0], ProbePrefixBytes)
    prefix.setLen(read)
  finally:
    handle.close()
  try:
    result = probeAudio(prefix)
    if result.container != acIsoBmff and result.format.sampleRate > 0:
      return result
  except CatchableError:
    discard
  probeAudio(readFile(path))


