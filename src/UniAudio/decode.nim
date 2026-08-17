# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## One entry point: give it a file, get samples back.
##
## The container is identified from the bytes, never from the extension — a
## `.wav` holding a FLAC stream is a real thing, and a caller should not have
## to guess. What this build does not decode is named in the error rather than
## reported as a generic failure: the codec a file turned out to hold is
## actionable, "unsupported file" is not.

import std/streams
import contracts
import ./pcm
import ./riff
import ./aiff
import ./flac
import ./alac
import ./vorbis
import ./mp3

type Container* = enum
  ## What a file turned out to be, decodable or not.
  acUnknown = "unknown"
  acWave = "wav"
  acAiff = "aiff"
  acFlac = "flac"
  acOgg = "ogg"
  acMpegAudio = "mp3"
  acIsoBmff = "mp4"

func startsWithAt(data: string; offset: int; text: string): bool =
  ## Whether `text` sits at `offset`. False rather than a raise when the string
  ## is too short: every caller here is testing a magic number against bytes of
  ## unknown length, where "not long enough" and "does not match" are the same
  ## answer.
  offset >= 0 and offset + text.len <= data.len and
    data[offset ..< offset + text.len] == text

func sniff*(data: string): Container =
  ## Identify a container from its leading bytes, without decoding it.
  ##
  ## Never from a file extension: a `.wav` holding a FLAC stream is a real
  ## thing. `acUnknown` for anything unrecognised, including a string shorter
  ## than four bytes.
  ##
  ## MP4 is the one magic that is not at offset zero — `ftyp` follows a
  ## four-byte box length. MP3 is last because its sync word is only eleven set
  ## bits, which any format could hold by chance; every stricter magic gets to
  ## answer first.
  if data.len < 4: return acUnknown
  if data.startsWithAt(0, "RIFF") and data.startsWithAt(8, "WAVE"):
    return acWave
  if data.startsWithAt(0, "FORM") and
      (data.startsWithAt(8, "AIFF") or data.startsWithAt(8, "AIFC")):
    return acAiff
  if data.startsWithAt(0, "fLaC"): return acFlac
  if data.startsWithAt(0, "OggS"): return acOgg
  if data.startsWithAt(4, "ftyp"): return acIsoBmff
  # An MP3 either opens with an ID3 tag or with a frame sync: eleven set bits.
  if data.startsWithAt(0, "ID3"): return acMpegAudio
  if uint8(data[0]) == 0xFF and (uint8(data[1]) and 0xE0) == 0xE0:
    return acMpegAudio
  acUnknown

func decodes*(container: Container): bool =
  ## Whether this build reads that container. MP4 and Ogg answer yes because the
  ## container itself is read; which codec sits inside is settled by opening it,
  ## and the error then names the codec found.
  container != acUnknown

proc decode*(data: string): AudioBuffer =
  ## Decode whatever the bytes turn out to be, to interleaved float32 samples.
  ##
  ## `sniff` names the container and this dispatches on it. A container that is
  ## recognised but holds a codec this build does not decode raises `AudioError`
  ## from the codec's own reader, with that codec named — so the caller learns
  ## what the file is, not merely that it failed.
  let container = sniff(data)
  case container
  of acWave: readWave(newStringStream(data))
  of acAiff: readAiff(newStringStream(data))
  of acFlac: readFlac(data)
  of acIsoBmff: readAlac(data)
  of acOgg: readVorbis(data)
  of acMpegAudio: readMp3(data)
  of acUnknown:
    raise newException(AudioError, "unrecognised audio container")

proc decodeFile*(path: string): AudioBuffer {.contractual.} =
  ## `decode` over a file, read whole.
  ##
  ## Read whole rather than streamed: FLAC and MP4 both need tables that sit
  ## after the audio, so neither can be decoded from a forward-only stream. A
  ## path that cannot be opened raises `IOError`, which is what separates a
  ## missing file from a malformed one.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "cannot open " & path)
    defer: stream.close()
    decode(stream.readAll())

proc sniffFile*(path: string): Container {.contractual.} =
  ## Identify a file without decoding it. Reads only its head.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "cannot open " & path)
    defer: stream.close()
    sniff(stream.readStr(16))


