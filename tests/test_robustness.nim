# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Damaged input must be reported, never fatal.
##
## Every decoder here parses bytes that came from a file, and a file is not to
## be trusted. The distinction this suite draws is between an `AudioError`,
## which says the bytes are wrong, and a `Defect` — an index out of range, an
## arithmetic overflow — which says this library is.
##
## The mutations run from fixed seeds, so a failure is reproducible rather than
## a story about one unlucky run. This is a floor, not a proof: a wider sweep
## outside the gate is what found the cases these fixtures now stand for.
import std/[unittest, os, random, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

const Corpus = [
  "sweep.wav", "sweep.flac", "sweep-alac.m4a", "sweep-vorbis.ogg",
  "sweep-mp3.mp3", "tagged.flac", "tagged.m4a", "tagged.ogg",
  "tagged-v24.mp3", "tagged-v1.mp3", "deep24.wav", "stereo-opus.ogg",
  "sweep-oggflac.ogg", "harsh16-alac.m4a", "silence16-mp3.mp3"]

proc survives(data: string): bool =
  ## True when the library either decoded the bytes or said why it could not.
  try:
    discard decode(data)
  except AudioError, IOError, ValueError:
    discard
  except CatchableError:
    return false
  except Defect:
    return false
  try:
    discard readTags(data)
  except AudioError, IOError, ValueError:
    discard
  except CatchableError:
    return false
  except Defect:
    return false
  true

suite "damaged input is reported, not fatal":
  test "every prefix of every fixture":
    # Truncation reaches the length and count fields a reader trusts.
    for name in Corpus:
      let whole = readFile(Fixtures / name)
      var lengths: seq[int]
      for n in 0 .. 32: lengths.add n
      var step = 1
      while step < whole.len:
        lengths.add step
        step = step * 2 + 1
      lengths.add whole.len - 1
      for n in lengths:
        if n >= 0 and n < whole.len:
          check survives(whole[0 ..< n])

  test "bytes replaced at random, several at a time":
    # One flip mostly lands in sample data. Several reach the headers, which is
    # where a reader can be told to index somewhere it should not.
    randomize(20260817)
    for name in Corpus:
      let whole = readFile(Fixtures / name)
      for _ in 1 .. 60:
        var damaged = whole
        for _ in 1 .. rand(1 .. 6):
          let at = rand(damaged.high)
          damaged[at] = char(rand(255))
        check survives(damaged)

  test "one format's head on another's tail":
    randomize(20260818)
    for name in Corpus:
      let whole = readFile(Fixtures / name)
      for _ in 1 .. 20:
        let other = readFile(Fixtures / Corpus[rand(Corpus.high)])
        let cut = rand(min(whole.high, 400))
        check survives(whole[0 ..< cut] & other[cut ..< other.len])

suite "what the damaged cases turned out to be":
  test "a FLAC whose predictor would run away is refused":
    # A corrupt residual feeds back through the reconstruction and grows until
    # the arithmetic overflows. The width the frame declared bounds it. With
    # this seed the case appears within a couple of mutations; the loop is a
    # margin, not an estimate of how rare it is.
    var reason = ""
    let whole = readFile(Fixtures / "sweep.flac")
    randomize(20260817)
    for _ in 1 .. 200:
      var damaged = whole
      let at = rand(damaged.high)
      damaged[at] = char(uint8(damaged[at]) xor 0x40'u8)
      try:
        discard readFlac(damaged)
      except AudioError as failure:
        if failure.msg.contains("does not fit"):
          reason = failure.msg
          break
      except CatchableError:
        discard
    check reason.contains("does not fit")

  test "an MP3 frame that disagrees about its channel count is survivable":
    # The sync word says nothing about the channel mode, so a damaged frame can
    # claim mono inside a stereo stream. Its side information is then the wrong
    # size for the granules the rest of the stream expects.
    let whole = readFile(Fixtures / "stereo-mp3.mp3")
    randomize(20260819)
    for _ in 1 .. 300:
      var damaged = whole
      for _ in 1 .. 3:
        let at = rand(damaged.high)
        damaged[at] = char(rand(255))
      check survives(damaged)

suite "a box walk never reaches past the buffer":
  test "a limit past the data yields no span past the data":
    # A parent span may name more bytes than the file holds — a truncated
    # download, or a size copied from a header that lied. What is yielded is
    # read by the caller, so it must never point past what was handed in.
    var data = ""
    for shift in countdown(3, 0): data.add char(uint8((64 shr (shift * 8)) and 0xFF))
    data.add "mdat"
    data.add "only twelve"
    for _, _, bodyEnd in boxes(data, 0, 64):
      check bodyEnd <= data.len

  test "a size no int can hold ends the walk rather than wrapping":
    var data = ""
    for shift in countdown(3, 0): data.add char(uint8((1 shr (shift * 8)) and 0xFF))
    data.add "mdat"
    for shift in countdown(7, 0):
      data.add char(uint8((high(int64) shr (shift * 8)) and 0xFF))
    data.add "payload"
    var count = 0
    for _, _, _ in boxes(data, 0, data.len): inc count
    check count == 0

