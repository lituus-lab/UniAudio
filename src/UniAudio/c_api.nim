# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## C ABI for UniAudio. Built --app:staticlib/--app:lib --noMain --mm:arc
## -d:release. Keep in sync with include/UniAudio.h; tests/c links the header
## against this lib, so a header that drifts fails to compile rather than at a
## caller's site.
##
## No Nim exception crosses this boundary: every entry point traps and maps to
## a `UAUD_*` status, with the reason available from `uaud_last_error`.
import ../UniAudio

const UniAudioVersionC: cstring = "0.1.0"

type Status = enum
  uaudOk = 0
  uaudErrArg = 1    ## a null pointer or an empty path
  uaudErrIo = 2     ## the file could not be opened or read
  uaudErrFormat = 3 ## the bytes are not a container this build understands

var lastError {.threadvar.}: string

proc uaud_version(): cstring {.exportc, cdecl, dynlib.} =
  ## Static version string; do not free.
  UniAudioVersionC

proc uaud_last_error(): cstring {.exportc, cdecl, dynlib.} =
  ## Most recent failure on this thread, "" when there is none. Owned by the
  ## library; valid until the next failing call on the same thread.
  lastError.cstring

proc uaud_wave_probe(path: cstring; sampleRate, channels: ptr cint;
                     frames: ptr clonglong): cint {.exportc, cdecl, dynlib.} =
  ## Shape of a RIFF/WAVE file, without keeping the samples.
  ##
  ## Reads the whole file, because a WAV declares its size in a header that
  ## cannot be trusted: the frame count reported here is the one the data
  ## actually holds.
  if path == nil or sampleRate == nil or channels == nil or frames == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  try:
    let buffer = readWaveFile($path)
    sampleRate[] = cint(buffer.format.sampleRate)
    channels[] = cint(buffer.format.channels)
    frames[] = clonglong(buffer.format.frames)
    lastError = ""
    cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)
