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

proc uaud_container_name(container: cint): cstring {.exportc, cdecl, dynlib.} =
  ## Name of a container code, or "unknown" for one this build has no name for.
  ## Static; do not free.
  # String literals, not a table built at module scope: this library is
  # compiled --noMain, so no global initialiser ever runs.
  case container
  of 1: cstring"wav"
  of 2: cstring"aiff"
  of 3: cstring"flac"
  of 4: cstring"ogg"
  of 5: cstring"mp3"
  of 6: cstring"mp4"
  else: cstring"unknown"

proc uaud_sniff(path: cstring; container: ptr cint): cint
               {.exportc, cdecl, dynlib.} =
  ## Identify a file from its leading bytes, without decoding it.
  if path == nil or container == nil:
    lastError = "path and container must be non-null"
    return cint(uaudErrArg)
  try:
    container[] = cint(ord(sniffFile($path)))
    lastError = ""
    cint(uaudOk)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_probe(path: cstring; sampleRate, channels: ptr cint;
                frames: ptr clonglong): cint {.exportc, cdecl, dynlib.} =
  ## Shape of any container this build decodes. A container it recognises but
  ## does not decode is named in `uaud_last_error`, not silently skipped.
  if path == nil or sampleRate == nil or channels == nil or frames == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  try:
    let buffer = decodeFile($path)
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

proc emitBuffer(buffer: AudioBuffer; sampleRate, channels: ptr cint;
                frames: ptr clonglong; samples: ptr ptr cfloat): cint =
  ## Hand a decoded buffer across the boundary. The samples are allocated here
  ## and released with `uaud_free`; a file that decoded to nothing yields a
  ## count of zero and a null pointer, not an error.
  sampleRate[] = cint(buffer.format.sampleRate)
  channels[] = cint(buffer.format.channels)
  frames[] = clonglong(buffer.format.frames)
  if buffer.samples.len == 0:
    samples[] = nil
    return cint(uaudOk)
  let bytes = buffer.samples.len * sizeof(cfloat)
  let target = cast[ptr UncheckedArray[cfloat]](alloc(bytes))
  for index in 0 ..< buffer.samples.len:
    target[index] = cfloat(buffer.samples[index])
  samples[] = cast[ptr cfloat](target)
  cint(uaudOk)

proc uaud_decode(path: cstring; sampleRate, channels: ptr cint;
                 frames: ptr clonglong; samples: ptr ptr cfloat): cint
                {.exportc, cdecl, dynlib.} =
  ## Decode a file to interleaved floats in [-1, 1]. `frames` counts per
  ## channel, so the block holds `frames * channels` values.
  if path == nil or sampleRate == nil or channels == nil or frames == nil or
      samples == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  try:
    result = emitBuffer(decodeFile($path), sampleRate, channels, frames,
      samples)
    lastError = ""
  except AudioError as error:
    lastError = error.msg
    result = cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_decode_resampled(path: cstring; targetRate: cint; toMonoFlag: cint;
                           sampleRate, channels: ptr cint;
                           frames: ptr clonglong;
                           samples: ptr ptr cfloat): cint
                          {.exportc, cdecl, dynlib.} =
  ## Decode, then optionally average the channels and change the rate. A
  ## `target_rate` of zero leaves the rate alone.
  ##
  ## The resampling is linear, which is right for analysis and wrong for
  ## listening; a resampler meant for listening would be a different call.
  if path == nil or sampleRate == nil or channels == nil or frames == nil or
      samples == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if targetRate < 0 or targetRate > cint(MaxSampleRate):
    lastError = "target rate out of range"
    return cint(uaudErrArg)
  try:
    var buffer = decodeFile($path)
    if toMonoFlag != 0: buffer = buffer.toMono()
    if targetRate > 0 and int(targetRate) != buffer.format.sampleRate:
      buffer = buffer.resample(int(targetRate))
    result = emitBuffer(buffer, sampleRate, channels, frames, samples)
    lastError = ""
  except AudioError as error:
    lastError = error.msg
    result = cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_wave(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib.} =
  ## Write interleaved floats as a RIFF/WAVE file. The only format this
  ## library writes; everything else it only reads.
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if sampleRate <= 0 or sampleRate > cint(MaxSampleRate) or channels <= 0 or
      channels > cint(MaxChannels) or frames < 0:
    lastError = "sample rate, channel count or frame count out of range"
    return cint(uaudErrArg)
  if bitsPerSample notin [cint(16), cint(24)]:
    # What the writer implements. Eight-bit WAV is unsigned by convention and
    # this writer emits signed bytes, so it would round-trip inverted; 32 bits
    # carries no more precision than 24 from a float32 sample.
    lastError = "bits per sample must be 16 or 24"
    return cint(uaudErrArg)
  try:
    var buffer = initAudioBuffer(int(sampleRate), int(channels), int(frames))
    let source = cast[ptr UncheckedArray[cfloat]](samples)
    for index in 0 ..< buffer.samples.len:
      buffer.samples[index] = float32(source[index])
    writeWaveFile($path, buffer, int(bitsPerSample))
    lastError = ""
    result = cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    result = cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_flac(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib.} =
  ## Encode interleaved floats to a native FLAC file, losslessly.
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if sampleRate <= 0 or sampleRate > cint(MaxSampleRate) or channels <= 0 or
      channels > 8 or frames < 0:
    lastError = "sample rate, channel count or frame count out of range"
    return cint(uaudErrArg)
  if bitsPerSample notin [cint(8), cint(16), cint(24)]:
    lastError = "bits per sample must be 8, 16 or 24"
    return cint(uaudErrArg)
  try:
    var buffer = initAudioBuffer(int(sampleRate), int(channels), int(frames))
    let source = cast[ptr UncheckedArray[cfloat]](samples)
    for index in 0 ..< buffer.samples.len:
      buffer.samples[index] = float32(source[index])
    writeFlacFile($path, buffer, int(bitsPerSample))
    lastError = ""
    result = cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    result = cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_alac(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib.} =
  ## Encode interleaved floats to an `.m4a` holding one ALAC track, losslessly.
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if sampleRate <= 0 or sampleRate > cint(MaxSampleRate) or channels <= 0 or
      channels > 2 or frames <= 0:
    lastError = "sample rate, channel count or frame count out of range"
    return cint(uaudErrArg)
  if bitsPerSample notin [cint(16), cint(24)]:
    lastError = "bits per sample must be 16 or 24"
    return cint(uaudErrArg)
  try:
    var buffer = initAudioBuffer(int(sampleRate), int(channels), int(frames))
    let source = cast[ptr UncheckedArray[cfloat]](samples)
    for index in 0 ..< buffer.samples.len:
      buffer.samples[index] = float32(source[index])
    writeAlacFile($path, buffer, int(bitsPerSample))
    lastError = ""
    result = cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    result = cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except CatchableError, Defect:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_free(buffer: pointer) {.exportc, cdecl, dynlib.} =
  ## Release a buffer this library allocated. NULL is accepted.
  if buffer != nil: dealloc(buffer)

proc uaud_fingerprint(path: cstring; duration: ptr cdouble;
                      words: ptr ptr uint32; count: ptr cint): cint
                     {.exportc, cdecl, dynlib.} =
  ## Fingerprint a file. The words are allocated here and released with
  ## `uaud_free`; a recording too short to compare yields a count of zero and
  ## a null pointer, not an error.
  if path == nil or duration == nil or words == nil or count == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  try:
    let print = fingerprint(decodeFile($path))
    duration[] = cdouble(print.durationSeconds)
    count[] = cint(print.words.len)
    if print.words.len == 0:
      words[] = nil
    else:
      let bytes = print.words.len * sizeof(uint32)
      let buffer = cast[ptr UncheckedArray[uint32]](alloc(bytes))
      for index in 0 ..< print.words.len:
        buffer[index] = print.words[index]
      words[] = cast[ptr uint32](buffer)
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

func jsonString(text: string): string =
  ## Escaped by hand rather than through std/json: this library is compiled
  ## --noMain, and anything needing a global initialiser would never run.
  result = "\""
  for character in text:
    case character
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    else:
      if character < ' ':
        const Digits = "0123456789abcdef"
        result.add "\\u00"
        result.add Digits[int(uint8(character)) shr 4]
        result.add Digits[int(uint8(character)) and 15]
      else:
        result.add character
  result.add "\""

proc uaud_tags_json(path: cstring; json: ptr cstring): cint
                   {.exportc, cdecl, dynlib.} =
  ## What the file says about itself, as a UTF-8 JSON object. The string is
  ## allocated here and released with `uaud_free`.
  ##
  ## A file carrying no tags yields an object with empty fields, not an error:
  ## having nothing to say is not a failure. `date` is whatever the file wrote,
  ## unparsed, because tag dates follow no agreed format.
  if path == nil or json == nil:
    lastError = "path and json must be non-null"
    return cint(uaudErrArg)
  try:
    let tags = readTagsFile($path)
    var text = "{"
    text.add "\"title\":" & jsonString(tags.title)
    text.add ",\"artist\":" & jsonString(tags.artist)
    text.add ",\"album\":" & jsonString(tags.album)
    text.add ",\"albumArtist\":" & jsonString(tags.albumArtist)
    text.add ",\"composer\":" & jsonString(tags.composer)
    text.add ",\"genre\":" & jsonString(tags.genre)
    text.add ",\"comment\":" & jsonString(tags.comment)
    text.add ",\"date\":" & jsonString(tags.date)
    text.add ",\"trackNumber\":" & $tags.trackNumber
    text.add ",\"trackTotal\":" & $tags.trackTotal
    text.add ",\"discNumber\":" & $tags.discNumber
    text.add ",\"discTotal\":" & $tags.discTotal
    text.add ",\"other\":["
    for index, entry in tags.other:
      if index > 0: text.add ","
      text.add "{\"key\":" & jsonString(entry.key) &
        ",\"value\":" & jsonString(entry.value) & "}"
    text.add "]}"

    let buffer = cast[cstring](alloc(text.len + 1))
    copyMem(buffer, text.cstring, text.len + 1)
    json[] = buffer
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

proc uaud_similarity(a: ptr uint32; aCount: cint; b: ptr uint32;
                     bCount: cint): cdouble {.exportc, cdecl, dynlib.} =
  ## How alike two fingerprints are, in [0, 1]. Two empty fingerprints are
  ## not alike: they are unknown, which reads as 0.
  if a == nil or b == nil or aCount <= 0 or bCount <= 0: return 0.0
  var left, right: Fingerprint
  let leftArray = cast[ptr UncheckedArray[uint32]](a)
  let rightArray = cast[ptr UncheckedArray[uint32]](b)
  for index in 0 ..< int(aCount): left.words.add leftArray[index]
  for index in 0 ..< int(bCount): right.words.add rightArray[index]
  cdouble(similarity(left, right))

proc uaud_offset_similarity(a: ptr uint32; aCount: cint; b: ptr uint32;
                            bCount: cint; maxShift: cint): cdouble
                           {.exportc, cdecl, dynlib.} =
  ## The best similarity over a bounded time shift, for two copies of a
  ## recording that start at different points.
  if a == nil or b == nil or aCount <= 0 or bCount <= 0 or maxShift < 0:
    return 0.0
  var first, second: Fingerprint
  let aWords = cast[ptr UncheckedArray[uint32]](a)
  let bWords = cast[ptr UncheckedArray[uint32]](b)
  for index in 0 ..< int(aCount): first.words.add aWords[index]
  for index in 0 ..< int(bCount): second.words.add bWords[index]
  try:
    cdouble(offsetSimilarity(first, second, int(maxShift)))
  except CatchableError, Defect:
    0.0

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


