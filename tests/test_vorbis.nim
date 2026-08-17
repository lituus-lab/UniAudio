# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Vorbis, checked against libvorbis rather than against itself.
##
## Each `.ogg` came from `oggenc`; each `-ref.wav` beside it is that file
## decoded by ffmpeg. Vorbis is lossy, so there is nothing to compare a decode
## against except another decoder — agreement here means agreement with the
## reference implementation, which is the only definition of correct there is.
##
## The reference is 16-bit PCM, so it is quantised and clipped. Clipping is
## reproduced before comparing: a Vorbis stream can reconstruct past unity, and
## calling that a mismatch would be measuring the reference's format.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

## One step of 16-bit quantisation. The reference cannot be more exact than
## the format it was written in.
const Tolerance = 1.0 / 30000.0

proc worstDelta(decoded, reference: AudioBuffer): float =
  for index in 0 ..< min(decoded.samples.len, reference.samples.len):
    let clipped = clamp(float(decoded.samples[index]), -1.0, 1.0)
    result = max(result, abs(clipped - float(reference.samples[index])))

proc checkAgainstReference(name: string; rate, channels, frames: int) =
  let decoded = readVorbisFile(Fixtures / (name & "-vorbis.ogg"))
  let reference = readWaveFile(Fixtures / (name & "-vorbis-ref.wav"))
  check decoded.format.sampleRate == rate
  check decoded.format.channels == channels
  check decoded.format.frames == frames
  check worstDelta(decoded, reference) < Tolerance

suite "vorbis against libvorbis":
  test "a three-second mono sweep":
    checkAgainstReference("sweep", 11025, 1, 33075)

  test "a stereo pair, decoupled":
    checkAgainstReference("stereo", 44100, 2, 5000)

  test "stereo noise, where every residue pass carries something":
    checkAgainstReference("noise16", 22050, 2, 2000)

  test "full-scale noise, which reconstructs past unity":
    checkAgainstReference("harsh16", 44100, 1, 2205)

  test "a tone long enough to switch between block sizes":
    checkAgainstReference("tone16", 44100, 1, 9000)

  test "a 48 kHz source at the lowest quality setting":
    checkAgainstReference("deep24", 48000, 1, 1500)

suite "vorbis stream length":
  test "the granule position, not the last block, ends the stream":
    # The final block runs past the end of the audio; its tail is padding the
    # encoder added to fill it, and the granule says where to stop.
    let decoded = readVorbisFile(Fixtures / "sweep-vorbis.ogg")
    let source = readWaveFile(Fixtures / "sweep.wav")
    check decoded.format.frames == source.format.frames

suite "vorbis refuses what it cannot decode":
  test "an Ogg carrying a codec this build has no decoder for":
    # A real Ogg-FLAC file: the container reads, the headers are not Vorbis.
    var reason = ""
    try:
      discard readVorbisFile(Fixtures / "sweep-oggflac.ogg")
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("flac")

  test "an Ogg carrying Opus names it rather than failing as bad Vorbis":
    var reason = ""
    try:
      discard readVorbisFile(Fixtures / "stereo-opus.ogg")
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("opus")

  test "bytes that are not an Ogg file at all":
    expect AudioError:
      discard readVorbis("RIFF____WAVEfmt ")

suite "vorbis through the container-agnostic entry point":
  test "an ogg is recognised and decoded without naming its type":
    check sniffFile(Fixtures / "sweep-vorbis.ogg") == acOgg
    check decodes(acOgg)
    let decoded = decodeFile(Fixtures / "sweep-vorbis.ogg")
    check decoded.format.sampleRate == 11025
    check decoded.format.frames == 33075

  test "the decode fingerprints, and does so the same way every time":
    let once = fingerprint(decodeFile(Fixtures / "sweep-vorbis.ogg"))
    let again = fingerprint(readVorbisFile(Fixtures / "sweep-vorbis.ogg"))
    check once.words.len > 0
    check once.words == again.words
    check similarity(once, again) == 1.0
