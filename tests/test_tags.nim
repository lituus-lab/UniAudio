# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Tags, read out of files that carry known ones.
##
## The fixtures were written by ffmpeg and LAME with the same set of values, so
## the four schemes can be checked against one expectation. The title carries
## accents on purpose: ID3v2.3 stores it as UTF-16 and ID3v2.4 as UTF-8, and a
## reader that ignores the encoding byte passes one and fails the other.
##
## ID3v2.2 has no writer to make a fixture with, so its tag is built here. That
## is weaker evidence than a real file, and worth knowing when reading it.
import std/[unittest, os]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

## What every `tagged.*` fixture was written with.
const
  Title = "Été à Nice"
  Artist = "Lituus Lab"
  Album = "Fixtures"

proc checkCommonFields(tags: Tags) =
  check tags.title == Title
  check tags.artist == Artist
  check tags.album == Album
  check tags.date == "2026"
  check tags.genre == "Ambient"
  check tags.trackNumber == 3
  check tags.trackTotal == 12

suite "tags, whichever scheme the file uses":
  test "ID3v2.4, where the text is UTF-8":
    let tags = readTagsFile(Fixtures / "tagged-v24.mp3")
    checkCommonFields(tags)
    check tags.comment == "one line"

  test "ID3v2.3, where the same text is UTF-16 with a byte-order mark":
    let tags = readTagsFile(Fixtures / "tagged-v23.mp3")
    checkCommonFields(tags)
    check tags.comment == "one line"

  test "a Vorbis comment inside FLAC":
    checkCommonFields(readTagsFile(Fixtures / "tagged.flac"))

  test "a Vorbis comment inside Ogg":
    # This file writes `title` in lower case and `TRACKNUMBER` in upper; the
    # format says names are case insensitive, and both have to land.
    let tags = readTagsFile(Fixtures / "tagged.ogg")
    checkCommonFields(tags)
    check tags.comment == "one line"

  test "iTunes-style atoms inside MP4":
    checkCommonFields(readTagsFile(Fixtures / "tagged.m4a"))

suite "ID3v1, which is fixed width and says nothing about its encoding":
  test "the fields a 128-byte tag can hold":
    let tags = readTagsFile(Fixtures / "tagged-v1.mp3")
    check tags.title == "Old Tag"
    check tags.artist == "Legacy"
    check tags.album == "Archive"
    check tags.date == "1998"
    # Version 1.1 took the last byte of the comment for a track number.
    check tags.trackNumber == 7

  test "the genre is reported as its number, not as a guessed name":
    let tags = readTagsFile(Fixtures / "tagged-v1.mp3")
    check tags.genre == ""
    var code = ""
    for (key, value) in tags.other:
      if key == "GENRECODE": code = value
    check code == "17"

  test "a newer tag wins, and the older one fills what it left empty":
    let tags = readTagsFile(Fixtures / "silence16-mp3.mp3")
    check tags.title == "fixture"
    check tags.artist == "uniaudio"

suite "tags this reader has no fixture for":
  test "ID3v2.2, whose frame names are three characters":
    # A header, then one TT2 frame: three-byte name, three-byte length, an
    # encoding byte and Latin-1 text.
    let text = "Old Style"
    var frame = "TT2"
    frame.add char(0)
    frame.add char(0)
    frame.add char(text.len + 1)
    frame.add char(0) # Latin-1
    frame.add text
    var tag = "ID3"
    tag.add char(2) # major version
    tag.add char(0)
    tag.add char(0) # no flags
    for shift in countdown(3, 0):
      tag.add char((frame.len shr (7 * shift)) and 0x7F)
    tag.add frame
    check readId3v2(tag).title == text

  test "a Vorbis comment naming a track total on its own":
    var field = "\x00\x00\x00\x00" # no vendor string
    let entries = @["TRACKNUMBER=5", "TOTALTRACKS=9", "ALBUMARTIST=Someone"]
    field.add char(entries.len)
    field.add "\x00\x00\x00"
    for entry in entries:
      field.add char(entry.len)
      field.add "\x00\x00\x00"
      field.add entry
    let tags = readVorbisComment(field)
    check tags.trackNumber == 5
    check tags.trackTotal == 9
    check tags.albumArtist == "Someone"

suite "tags refuse to invent":
  test "a file with none reads as empty rather than as blanks":
    check readTagsFile(Fixtures / "sweep.wav").isEmpty

  test "a truncated tag is not read past":
    # A header claiming far more than follows it.
    var tag = "ID3\x04\x00\x00\x7F\x7F\x7F\x7F"
    tag.add "TIT2"
    check readId3v2(tag).isEmpty

  test "bytes that are no format at all":
    check readTags("not audio").isEmpty

  test "a name with no field of its own is kept, not dropped":
    let tags = readTagsFile(Fixtures / "tagged.flac")
    var encoder = ""
    for (key, value) in tags.other:
      if key == "ENCODER": encoder = value
    check encoder.len > 0
