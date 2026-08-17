# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## ALAC, checked against the encoders that produced the files.
##
## Each fixture is a synthetic WAV run through an ALAC encoder. ALAC is
## lossless, so decoding it must give the samples back: the only difference
## allowed is the integer-to-float scale, one quantisation step apart between
## the two readers.
##
## The fixtures are chosen for the frame shapes they contain, not for their
## sound — a partial last frame, a stereo pair carrying mid/side weights, a
## 24-bit stream with a byte shifted off, an incompressible one the encoder
## gave up on and stored raw, and one whose predictor uses no coefficients at
## all. `deep24-apple.m4a` is the same signal through Apple's reference
## encoder rather than ffmpeg's, so agreement is between two independent
## encoders and not a shared assumption.
import std/[unittest, os, strutils]
import UniAudio

const Fixtures = currentSourcePath.parentDir / "fixtures"

## One step of 16-bit quantisation, the widest the two readers' scales differ.
const Tolerance = 1.0 / 30000.0

proc worstDelta(a, b: AudioBuffer): float =
  for index in 0 ..< min(a.samples.len, b.samples.len):
    result = max(result, abs(float(a.samples[index]) - float(b.samples[index])))

proc checkRoundTrip(alacName, wavName: string) =
  let reference = readWaveFile(Fixtures / wavName)
  let decoded = readAlacFile(Fixtures / alacName)
  check decoded.format.sampleRate == reference.format.sampleRate
  check decoded.format.channels == reference.format.channels
  check decoded.format.frames == reference.format.frames
  check decoded.samples.len == reference.samples.len
  check worstDelta(decoded, reference) < Tolerance

suite "alac against the encoders that made the fixtures":
  test "a mono stream spanning several frames, the last one partial":
    # 33075 frames is eight full 4096-sample frames and a 307-sample tail.
    checkRoundTrip("sweep-alac.m4a", "sweep.wav")
    check readAlacFile(Fixtures / "sweep-alac.m4a").format.frames == 33075

  test "a stereo pair, undoing the mid/side weights the frame carries":
    checkRoundTrip("stereo-alac.m4a", "stereo16.wav")

  test "24 bits, with the low byte stored outside the coded residuals":
    checkRoundTrip("deep24-alac.m4a", "deep24.wav")

  test "the same 24-bit signal through Apple's reference encoder":
    checkRoundTrip("deep24-apple.m4a", "deep24.wav")

  test "a frame the encoder stored raw rather than compress":
    # Full-scale white noise: the coded frame would be larger than the samples,
    # so the encoder sets the escape flag and writes them verbatim.
    checkRoundTrip("harsh16-alac.m4a", "harsh16.wav")

  test "a predictor with no coefficients at all":
    checkRoundTrip("wide32-alac.m4a", "wide32.wav")

suite "alac magic cookie":
  test "the cookie describes the stream the samples turn out to be":
    let track = readAudioTrack(readFile(Fixtures / "stereo-alac.m4a"))
    let config = parseMagicCookie(track.entry.setup)
    check config.channels == 2
    check config.bitDepth == 16
    check config.sampleRate == 44100
    check config.frameLength == 4096

  test "a cookie of the wrong length is refused, not read past":
    expect AudioError:
      discard parseMagicCookie("short")

  test "a plausible cookie describing an impossible stream is refused":
    # The right 24 bytes, with the channel count set to 9.
    var cookie = newString(24)
    cookie[3] = '\x01' # frameLength = 1
    cookie[5] = '\x10' # bitDepth = 16
    cookie[9] = '\x09' # numChannels = 9
    expect AudioError:
      discard parseMagicCookie(cookie)

suite "mp4 containers this build will not decode":
  test "a track that is not ALAC names the codec it found":
    # The same file with its sample entry renamed: the error must say `mp4a`
    # rather than report a generic failure.
    var patched = readFile(Fixtures / "stereo-alac.m4a")
    let at = patched.find("alac")
    check at > 0
    patched[at .. at + 3] = "mp4a"
    var reason = ""
    try:
      discard readAlac(patched)
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("mp4a")

  test "a real AAC track names the codec it found":
    # Not a patched sample entry: a file ffmpeg encoded as AAC.
    var reason = ""
    try:
      discard readAlacFile(Fixtures / "stereo-aac.m4a")
    except AudioError as failure:
      reason = failure.msg
    check reason.contains("mp4a")

  test "bytes that are not an MP4 at all are refused":
    expect AudioError:
      discard readAlac("not an mp4, not even close")

suite "alac through the container-agnostic entry point":
  test "an m4a is recognised and decoded without naming its type":
    check sniffFile(Fixtures / "sweep-alac.m4a") == acIsoBmff
    check decodes(acIsoBmff)
    let decoded = decodeFile(Fixtures / "sweep-alac.m4a")
    let reference = readWaveFile(Fixtures / "sweep.wav")
    check decoded.format == reference.format
    check worstDelta(decoded, reference) < Tolerance

  test "an ALAC file fingerprints the same as the WAV it came from":
    let fromAlac = fingerprint(decodeFile(Fixtures / "sweep-alac.m4a"))
    let fromWave = fingerprint(readWaveFile(Fixtures / "sweep.wav"))
    check fromAlac.words == fromWave.words
