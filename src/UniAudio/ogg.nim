# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Ogg framing: pages in, packets out.
##
## Ogg carries packets of arbitrary length across fixed-size pages, so a packet
## can start on one page and finish two pages later, and one page can hold
## dozens of small packets. A codec should never see any of that — it asks for
## packets and gets packets.
##
## Each page names the logical stream it belongs to. Several streams can be
## interleaved in one file; this reader keeps them apart rather than
## concatenating them into nonsense.
##
## The per-page checksum is verified. A truncated download is the usual way an
## Ogg file goes wrong, and the alternative to checking is handing a codec
## bytes that decode to noise.

import ./pcm

const
  OggHeaderBytes = 27
  MaxPacketBytes* = 16 * 1024 * 1024
    ## A Vorbis setup header runs to a few tens of kilobytes. A packet growing
    ## past this came from a malformed lacing table, not from an encoder.

type
  OggPacket* = object
    ## One complete packet, reassembled across as many pages as it spanned.
    data*: string
    serial*: uint32
      ## The logical stream it belongs to.
    granule*: int64
      ## The granule position of the page it finished on, or -1 when that page
      ## ended mid-packet. For audio this is a running sample count.
    endsStream*: bool

  OggStream* = object
    ## The packets of one logical stream, in order.
    serial*: uint32
    packets*: seq[OggPacket]

const crcTable = block:
  # Ogg's checksum uses the 0x04c11db7 polynomial with no reflection at either
  # end and no final complement — not the CRC-32 most formats reach for.
  #
  # Built at compile time: a table filled on first use would be mutable global
  # state, and two threads reading two files would race to fill it.
  var table: array[256, uint32]
  for index in 0 ..< 256:
    var value = uint32(index) shl 24
    for _ in 0 ..< 8:
      value = if (value and 0x8000_0000'u32) != 0:
                (value shl 1) xor 0x04c1_1db7'u32
              else: value shl 1
    table[index] = value
  table

proc pageCrc(data: string; first, last, skipFrom, skipTo: int): uint32 =
  ## The checksum over one page, reading the stored field as zero.
  for index in first .. last:
    let value = if index >= skipFrom and index < skipTo: 0'u8
                else: uint8(data[index])
    result = (result shl 8) xor
      crcTable[int(((result shr 24) xor uint32(value)) and 0xFF)]

func leU32(data: string; offset: int): uint32 =
  for index in countdown(3, 0):
    result = (result shl 8) or uint32(uint8(data[offset + index]))

func leU64(data: string; offset: int): uint64 =
  for index in countdown(7, 0):
    result = (result shl 8) or uint64(uint8(data[offset + index]))

proc oggStreams*(data: string): seq[OggStream] =
  ## Every logical stream in the file, each with its packets in order.
  ##
  ## A packet the last page of a stream leaves unfinished is dropped: it has no
  ## end, so no codec can use it.
  var partial: seq[tuple[serial: uint32; buffer: string]]
  var offset = 0
  var pages = 0

  proc slotFor(serial: uint32): int =
    for index in 0 ..< partial.len:
      if partial[index].serial == serial: return index
    partial.add (serial, "")
    partial.len - 1

  proc streamFor(streams: var seq[OggStream]; serial: uint32): int =
    for index in 0 ..< streams.len:
      if streams[index].serial == serial: return index
    streams.add OggStream(serial: serial)
    streams.len - 1

  while offset + OggHeaderBytes <= data.len:
    if data[offset ..< offset + 4] != "OggS":
      raise newException(AudioError,
        "ogg: no page header at byte " & $offset)
    if uint8(data[offset + 4]) != 0:
      raise newException(AudioError, "ogg: unknown page version")
    let flags = uint8(data[offset + 5])
    let granule = cast[int64](leU64(data, offset + 6))
    let serial = leU32(data, offset + 14)
    let stored = leU32(data, offset + 22)
    let segments = int(uint8(data[offset + 26]))
    let tableAt = offset + OggHeaderBytes
    if tableAt + segments > data.len:
      raise newException(AudioError, "ogg: page ends inside its segment table")

    var payload = 0
    for index in 0 ..< segments:
      payload += int(uint8(data[tableAt + index]))
    let pageEnd = tableAt + segments + payload
    if pageEnd > data.len:
      raise newException(AudioError,
        "ogg: page claims more data than the file holds")
    if pageCrc(data, offset, pageEnd - 1, offset + 22, offset + 26) != stored:
      raise newException(AudioError,
        "ogg: page " & $int(leU32(data, offset + 18)) & " fails its checksum")
    inc pages

    let slot = slotFor(serial)
    # A page not marked as a continuation abandons whatever was half-read: the
    # stream was cut, not merely paused.
    if (flags and 0x01) == 0: partial[slot].buffer.setLen(0)

    var cursor = tableAt + segments
    for index in 0 ..< segments:
      let lacing = int(uint8(data[tableAt + index]))
      if partial[slot].buffer.len + lacing > MaxPacketBytes:
        raise newException(AudioError, "ogg: packet grows past any sane size")
      partial[slot].buffer.add data[cursor ..< cursor + lacing]
      cursor += lacing
      # A lacing value below 255 is the last segment of its packet.
      if lacing < 255:
        let last = index == segments - 1
        let target = result.streamFor(serial)
        result[target].packets.add OggPacket(
          data: move(partial[slot].buffer),
          serial: serial,
          granule: if last: granule else: -1,
          endsStream: last and (flags and 0x04) != 0)
        partial[slot].buffer = ""

    offset = pageEnd

  if pages == 0:
    raise newException(AudioError, "ogg: no page found")

proc oggPackets*(data: string): seq[OggPacket] =
  ## The packets of the first logical stream, which for a plain audio file is
  ## the only one there is.
  let streams = oggStreams(data)
  if streams.len == 0:
    raise newException(AudioError, "ogg: file holds no complete packet")
  streams[0].packets


