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
import std/[unittest, os, strutils, osproc, math, random]
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

suite "alac, written":
  ## The encoder is checked against ffmpeg, which is neither this decoder nor
  ## the encoder any fixture came from. `-f crc` makes ffmpeg print a checksum
  ## of the decoded samples, so one command covers the MP4 tables, the frame
  ## headers, the mid/side weights and every sample.

  proc referenceCrc(path: string; bits: int): string =
    ## ffmpeg's CRC of the samples it decodes from `path`, at `bits` deep.
    ## Empty when ffmpeg is not installed.
    if findExe("ffmpeg").len == 0: return ""
    let format = if bits > 16: "s32le" else: "s16le"
    let (output, code) = execCmdEx("ffmpeg -v error -i " & path.quoteShell &
      " -f " & format & " -c:a pcm_" & format & " -f crc -")
    if code != 0:
      echo output
      return "failed"
    output.strip()

  proc roundTrip(name: string; bits: int) =
    let source = readWaveFile(Fixtures / (name & ".wav"))
    let target = getTempDir() / ("uniaudio-write-" & name & $bits & ".m4a")
    writeAlacFile(target, source, bits)
    defer: removeFile(target)

    let decoded = readAlacFile(target)
    check decoded.format == source.format
    # Lossless means exactly that: the samples come back at the quantisation
    # asked for and no further apart.
    check worstDelta(decoded, source) < Tolerance

    # The same samples out of ffmpeg's decoder, and out of ffmpeg's reading of
    # the original WAV. Equal checksums mean the file is right by an
    # implementation that shares nothing with this one. Each fixture is encoded
    # at its own depth, so the comparison is exact rather than approximate.
    let mine = referenceCrc(target, bits)
    if mine.len > 0:
      check mine == referenceCrc(Fixtures / (name & ".wav"), bits)

  test "a mono sweep":
    roundTrip("sweep", 16)

  test "stereo, where the mid/side weights are searched":
    roundTrip("stereo16", 16)

  test "noise, which the predictor cannot help":
    roundTrip("noise16", 16)

  test "a tone spanning several frames":
    roundTrip("tone16", 16)

  test "24-bit, with a byte shifted off before predicting":
    roundTrip("deep24", 24)

  test "silence costs almost nothing":
    # A thousand silent frames collapse into zero runs; only the MP4 tables
    # and the magic cookie are left.
    let source = readWaveFile(Fixtures / "silence16.wav")
    check source.format.frames == 1000
    check writeAlac(source, 16).len < 800

  test "a frame the coder cannot shrink is stored raw instead":
    # Full-scale noise codes to more than it occupies, so the encoder falls
    # back to the escape frame. The file lands within a few per cent of the
    # samples' own size, where a coder that never gave up would exceed it.
    var noisy = initAudioBuffer(48000, 2, 9000)
    var rng = initRand(20260817)
    for index in 0 ..< noisy.samples.len:
      noisy.samples[index] = float32(rng.rand(2.0) - 1.0)
    let encoded = writeAlac(noisy, 16)
    let raw = noisy.samples.len * 2
    check encoded.len < raw + raw div 20
    check worstDelta(readAlac(encoded), noisy) < Tolerance

  test "a last frame of one sample":
    # 4097 frames leave a second frame holding a single sample, which is the
    # shortest thing the predictor and the weight search ever see.
    var tone = initAudioBuffer(44100, 2, 4097)
    for frame in 0 ..< 4097:
      tone.samples[frame * 2] = float32(sin(float(frame) * 0.05) * 0.8)
      tone.samples[frame * 2 + 1] = float32(cos(float(frame) * 0.03) * 0.6)
    let decoded = readAlac(writeAlac(tone, 16))
    check decoded.format.frames == 4097
    check worstDelta(decoded, tone) < Tolerance

  test "the frame count survives every boundary":
    for frames in [1, 2, 4095, 4096, 4097, 8192, 8193]:
      var tone = initAudioBuffer(22050, 1, frames)
      for frame in 0 ..< frames:
        tone.samples[frame] = float32(sin(float(frame) * 0.01) * 0.5)
      let decoded = readAlac(writeAlac(tone, 16))
      check decoded.format.frames == frames
      check worstDelta(decoded, tone) < Tolerance

  test "a depth or channel count the writer does not implement is refused":
    # Both checks live in the body, not in a precondition: a precondition
    # compiles away under -d:release, and a release build would then write a
    # malformed stream without saying so.
    let source = readWaveFile(Fixtures / "silence16.wav")
    for bits in [1, 8, 12, 20, 32, 64]:
      expect AudioError:
        discard writeAlac(source, bits)
    expect AudioError:
      discard writeAlac(initAudioBuffer(44100, 3, 100), 16)

  test "an encoded file is byte-for-byte reproducible":
    # Nothing in the writer records a time or a machine, so two runs agree.
    let source = readWaveFile(Fixtures / "stereo16.wav")
    check writeAlac(source, 16) == writeAlac(source, 16)
