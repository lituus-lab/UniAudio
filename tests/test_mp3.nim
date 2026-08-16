# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## MP3, checked against another decoder rather than against itself.
##
## Each `.mp3` came from LAME; each `-ref.wav` beside it is that file decoded
## by ffmpeg. MP3 is lossy, so agreement with an independent decoder is the
## only definition of correct there is.
##
## The reference is 16-bit PCM, so it is quantised and clipped, and both are
## reproduced before comparing.
##
## Where a decode starts and stops is as much a part of being right as the
## samples: an encoder pads the audio out to whole frames and records how much
## it added. The fixtures cover a file that says so, one that does not, and one
## behind an ID3 tag.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

## One step of 16-bit quantisation. The reference cannot be more exact than the
## format it was written in.
const Tolerance = 1.0 / 30000.0

proc worstDelta(decoded, reference: AudioBuffer): float =
  for index in 0 ..< min(decoded.samples.len, reference.samples.len):
    let clipped = clamp(float(decoded.samples[index]), -1.0, 1.0)
    result = max(result, abs(clipped - float(reference.samples[index])))

proc checkAgainstReference(name: string; rate, channels, frames: int) =
  let decoded = readMp3File(Fixtures / (name & "-mp3.mp3"))
  let reference = readWaveFile(Fixtures / (name & "-mp3-ref.wav"))
  check decoded.format.sampleRate == rate
  check decoded.format.channels == channels
  check decoded.format.frames == frames
  check reference.format.frames == frames
  check worstDelta(decoded, reference) < Tolerance

suite "mp3 against an independent decoder":
  test "MPEG-2.5 at 11 kHz, mono, three seconds of it":
    checkAgainstReference("sweep", 11025, 1, 33075)

  test "MPEG-1 at 44.1 kHz, joint stereo":
    checkAgainstReference("stereo", 44100, 2, 5000)

  test "MPEG-2 at 22 kHz, stereo, variable bitrate":
    checkAgainstReference("noise16", 22050, 2, 2000)

  test "full-scale noise at 320 kbit/s, where nothing compresses":
    checkAgainstReference("harsh16", 44100, 1, 2205)

  test "silence, which is all bit reservoir and no spectrum":
    checkAgainstReference("silence16", 8000, 1, 1000)

suite "mp3 knows where the audio starts and stops":
  test "an encoder that recorded its own padding is trimmed to the source":
    # LAME's tag says what it added at each end, so the decode comes out the
    # length of the WAV that went in, not of the frames carrying it.
    let decoded = readMp3File(Fixtures / "sweep-mp3.mp3")
    let source = readWaveFile(Fixtures / "sweep.wav")
    check decoded.format.frames == source.format.frames

  test "an encoder that recorded nothing is not trimmed at all":
    # 10368 frames is nine whole frames of 1152. With no tag there is no basis
    # for cutting any of them, and guessing would be worse than keeping them.
    checkAgainstReference("tone16", 44100, 1, 10368)

  test "frames behind an ID3 tag are found":
    let raw = readFile(Fixtures / "silence16-mp3.mp3")
    check raw.startsWith("ID3")
    check readMp3File(Fixtures / "silence16-mp3.mp3").format.frames == 1000

suite "mp3 refuses what it cannot decode":
  test "bytes with no frame header at all":
    var reason = ""
    try:
      discard readMp3("RIFF____WAVEfmt " & repeat('\0', 200))
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("no frame header")

  test "a sync word alone is not a frame":
    # Four bytes that pass the header test, with nothing to corroborate them.
    expect AudioError:
      discard readMp3("\xFF\xFB\x90\x00" & repeat('\0', 64))

suite "mp3 through the container-agnostic entry point":
  test "an mp3 is recognised and decoded without naming its type":
    check sniffFile(Fixtures / "sweep-mp3.mp3") == acMpegAudio
    check decodes(acMpegAudio)
    let decoded = decodeFile(Fixtures / "sweep-mp3.mp3")
    check decoded.format.sampleRate == 11025
    check decoded.format.frames == 33075

  test "a file behind an ID3 tag is still recognised as MPEG audio":
    check sniffFile(Fixtures / "silence16-mp3.mp3") == acMpegAudio
    check decodeFile(Fixtures / "silence16-mp3.mp3").format.frames == 1000
