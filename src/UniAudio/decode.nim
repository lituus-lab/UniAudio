# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## One entry point: give it a file, get samples back.
##
## The container is identified from the bytes, never from the extension — a
## `.wav` holding a FLAC stream is a real thing, and a caller should not have
## to guess. What this build does not decode is named in the error rather than
## reported as a generic failure: knowing a file is MP3 and unsupported is
## actionable, "unsupported file" is not.

import std/streams
import contracts
import ./pcm
import ./riff
import ./aiff
import ./flac

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
  offset >= 0 and offset + text.len <= data.len and
    data[offset ..< offset + text.len] == text

func sniff*(data: string): Container =
  ## Identify a container from its leading bytes.
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
  ## Whether this build turns that container into samples.
  container in {acWave, acAiff, acFlac}

proc decode*(data: string): AudioBuffer =
  ## Decode whatever the bytes turn out to be.
  let container = sniff(data)
  case container
  of acWave: readWave(newStringStream(data))
  of acAiff: readAiff(newStringStream(data))
  of acFlac: readFlac(data)
  of acUnknown:
    raise newException(AudioError, "unrecognised audio container")
  else:
    raise newException(AudioError,
      $container & ": recognised, but this build does not decode it")

proc decodeFile*(path: string): AudioBuffer {.contractual.} =
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(AudioError, "cannot open " & path)
    defer: stream.close()
    decode(stream.readAll())

proc sniffFile*(path: string): Container {.contractual.} =
  ## Identify a file without decoding it. Reads only its head.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(AudioError, "cannot open " & path)
    defer: stream.close()
    sniff(stream.readStr(16))
