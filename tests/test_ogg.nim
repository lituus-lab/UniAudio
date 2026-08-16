# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Ogg framing, checked against files the reference encoder produced.
##
## The fixtures come from `oggenc`. What matters here is not their sound but
## their shape: the three Vorbis headers arrive as three separate packets even
## though the third spans several pages, and the last page's granule position
## is the exact sample count of the WAV that went in.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

suite "ogg pages into packets":
  test "a plain audio file holds exactly one logical stream":
    let streams = oggStreams(readFile(Fixtures / "sweep-vorbis.ogg"))
    check streams.len == 1
    check streams[0].packets.len > 3

  test "the three headers come back as three packets, whole":
    let packets = oggPackets(readFile(Fixtures / "sweep-vorbis.ogg"))
    check packets[0].data.startsWith("\x01vorbis")
    check packets[1].data.startsWith("\x03vorbis")
    check packets[2].data.startsWith("\x05vorbis")
    # The setup header is larger than the pages carrying it, so getting it back
    # whole is the reassembly working, not a page that happened to fit.
    check packets[2].data.len > 2000

  test "the last packet carries the granule the stream ends on":
    for (name, frames) in [("sweep-vorbis.ogg", 33075),
                           ("stereo-vorbis.ogg", 5000)]:
      let packets = oggPackets(readFile(Fixtures / name))
      check packets[^1].endsStream
      check packets[^1].granule == frames

  test "every packet names the stream it came from":
    let streams = oggStreams(readFile(Fixtures / "stereo-vorbis.ogg"))
    for packet in streams[0].packets:
      check packet.serial == streams[0].serial

suite "ogg refuses what it cannot trust":
  test "a file that is not Ogg at all":
    expect AudioError:
      discard oggStreams("RIFF____WAVEfmt ")

  test "a flipped byte is caught by the page checksum":
    var corrupted = readFile(Fixtures / "sweep-vorbis.ogg")
    # Inside the first page's payload: its 27-byte header and one lacing byte
    # are followed by 30 bytes of identification header, so byte 40 is data.
    corrupted[40] = char(uint8(corrupted[40]) xor 0xFF)
    var reason = ""
    try:
      discard oggStreams(corrupted)
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("checksum")

  test "a page claiming more data than the file holds":
    let truncated = readFile(Fixtures / "sweep-vorbis.ogg")[0 ..< 40]
    expect AudioError:
      discard oggStreams(truncated)
