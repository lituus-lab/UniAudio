# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## The header probe, checked against the decoder rather than against itself.
##
## `decode` reads the whole file and is the reference: whatever it reports for
## a fixture is what that fixture is. The probe reads a bounded prefix and must
## agree, or it is guessing. Every shipped fixture is put through both, so a
## container whose header layout is misread fails here rather than in a
## catalogue that silently records the wrong length.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"
const AudioExts = [".wav", ".flac", ".m4a", ".ogg", ".mp3", ".aiff", ".aif"]

suite "the probe agrees with the decoder":
  test "every fixture reports the same rate, channels and length":
    var checked = 0
    for path in walkFiles(Fixtures / "*"):
      if path.splitFile.ext.toLowerAscii notin AudioExts: continue
      let probed = probeAudioFile(path)
      var decoded: AudioBuffer
      try:
        decoded = decodeFile(path)
      except CatchableError:
        # A container this build recognises but whose codec it does not read.
        # The probe still answers for it; there is nothing to compare against.
        continue
      inc checked
      check probed.format.sampleRate == decoded.format.sampleRate
      check probed.format.channels == decoded.format.channels
      # Ogg keeps its length in the last page and MPEG audio in an optional
      # header, so those two report none rather than a guess.
      if probed.framesKnown:
        check probed.format.frames == decoded.format.frames
    # A fixture directory that stopped holding audio would otherwise pass by
    # checking nothing at all.
    check checked > 20

suite "what the probe says about a file it cannot place":
  test "bytes in no container it knows are refused":
    expect AudioError:
      discard probeAudio("not audio at all, not even close")

  test "a truncated header is refused rather than half-read":
    expect AudioError:
      discard probeAudio("RIF")

suite "the container is named even where the length is not":
  test "Ogg and MPEG report their rate without claiming a length":
    for pattern in ["*-vorbis.ogg", "*-mp3.mp3"]:
      for path in walkFiles(Fixtures / pattern):
        let probed = probeAudioFile(path)
        check probed.format.sampleRate > 0
        check probed.format.channels > 0
        check not probed.framesKnown
        check probed.format.frames == 0

