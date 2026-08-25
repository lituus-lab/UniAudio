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


# A shared library runs NimMain from DllMain (Windows) or an ELF constructor;
# a static one has neither, so nothing initializes the Nim runtime. The first
# entry point then enters Nim code whose globals were never set up and the
# process faults. The static-library tasks pass -d:staticNoAutoInit; shared
# builds must not, or NimMain runs twice.
when defined(staticNoAutoInit):
  # A once primitive, not a plain flag: two threads reaching an entry point
  # together would both see the flag unset, both call NimMain, and the second
  # would enter Nim code the first had not finished initializing. The platform
  # primitives block the losers until the winner returns, which a flag cannot.
  #
  # C statics, not Nim globals: module initialization would reset a Nim one and
  # NimMain would run again. NimMain is declared here too — the generated
  # prototype comes after this section.
  {.emit: """/*VARSECTION*/
void NimMain(void);
#ifdef _WIN32
#  include <windows.h>
static INIT_ONCE uaud_runtime_once = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK uaud_runtime_init(PINIT_ONCE o, PVOID p, PVOID *c) {
  (void)o; (void)p; (void)c; NimMain(); return TRUE;
}
static void uaud_runtime_ensure(void) {
  InitOnceExecuteOnce(&uaud_runtime_once, uaud_runtime_init, NULL, NULL);
}
#else
#  include <pthread.h>
static pthread_once_t uaud_runtime_once = PTHREAD_ONCE_INIT;
static void uaud_runtime_init(void) { NimMain(); }
static void uaud_runtime_ensure(void) {
  pthread_once(&uaud_runtime_once, uaud_runtime_init);
}
#endif
""".}
  template ensureRuntime() =
    {.emit: "  uaud_runtime_ensure();".}
else:
  template ensureRuntime() = discard


proc uaud_version(): cstring {.exportc, cdecl, dynlib, raises: [].} =
  ## Static version string; do not free.
  ensureRuntime()
  UniAudioVersionC

proc uaud_last_error(): cstring {.exportc, cdecl, dynlib, raises: [].} =
  ## Most recent failure on this thread, "" when there is none. Owned by the
  ## library; valid until the next failing call on the same thread.
  ensureRuntime()
  lastError.cstring

proc uaud_container_name(container: cint): cstring {.exportc, cdecl, dynlib,
    raises: [].} =
  ## Name of a container code, or "unknown" for one this build has no name for.
  ## Static; do not free.
  ensureRuntime()
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
               {.exportc, cdecl, dynlib, raises: [].} =
  ## Identify a file from its leading bytes, without decoding it.
  ensureRuntime()
  if path == nil or container == nil:
    lastError = "path and container must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  try:
    container[] = cint(ord(sniffFile($path)))
    lastError = ""
    cint(uaudOk)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrIo)
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_probe(path: cstring; sampleRate, channels: ptr cint;
                frames: ptr clonglong): cint {.exportc, cdecl, dynlib, raises: [].} =
  ## Shape of any container this build decodes. A container it recognises but
  ## does not decode is named in `uaud_last_error`, not silently skipped.
  ensureRuntime()
  if path == nil or sampleRate == nil or channels == nil or frames == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
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
  except Exception:
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
                {.exportc, cdecl, dynlib, raises: [].} =
  ## Decode a file to interleaved floats in [-1, 1]. `frames` counts per
  ## channel, so the block holds `frames * channels` values.
  ensureRuntime()
  if path == nil or sampleRate == nil or channels == nil or frames == nil or
      samples == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  # Cleared before anything can fail: a caller that frees unconditionally must
  # not be handed back whatever its own storage happened to hold.
  samples[] = nil
  frames[] = 0
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_decode_resampled(path: cstring; targetRate: cint; toMonoFlag: cint;
                           sampleRate, channels: ptr cint;
                           frames: ptr clonglong;
                           samples: ptr ptr cfloat): cint
                          {.exportc, cdecl, dynlib, raises: [].} =
  ## Decode, then optionally average the channels and change the rate. A
  ## `target_rate` of zero leaves the rate alone.
  ##
  ## The resampling is linear, which is right for analysis and wrong for
  ## listening; a resampler meant for listening would be a different call.
  ensureRuntime()
  if path == nil or sampleRate == nil or channels == nil or frames == nil or
      samples == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  if targetRate < 0 or targetRate > cint(MaxSampleRate):
    lastError = "target rate out of range"
    return cint(uaudErrArg)
  samples[] = nil
  frames[] = 0
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_wave(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib,
                         raises: [].} =
  ## Write interleaved floats as a RIFF/WAVE file, 16 or 24 bits.
  ensureRuntime()
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_flac(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib,
                         raises: [].} =
  ## Encode interleaved floats to a native FLAC file, losslessly.
  ensureRuntime()
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_write_alac(path: cstring; samples: ptr cfloat; sampleRate,
                     channels: cint; frames: clonglong;
                     bitsPerSample: cint): cint {.exportc, cdecl, dynlib,
                         raises: [].} =
  ## Encode interleaved floats to an `.m4a` holding one ALAC track, losslessly.
  ensureRuntime()
  if path == nil or samples == nil:
    lastError = "path and samples must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)

proc uaud_free(buffer: pointer) {.exportc, cdecl, dynlib, raises: [].} =
  ## Release a buffer this library allocated. NULL is accepted.
  ensureRuntime()
  if buffer != nil: dealloc(buffer)

proc uaud_fingerprint(path: cstring; duration: ptr cdouble;
                      words: ptr ptr uint32; count: ptr cint): cint
                     {.exportc, cdecl, dynlib, raises: [].} =
  ## Fingerprint a file. The words are allocated here and released with
  ## `uaud_free`; a recording too short to compare yields a count of zero and
  ## a null pointer, not an error.
  ensureRuntime()
  if path == nil or duration == nil or words == nil or count == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  words[] = nil
  count[] = 0
  duration[] = 0.0
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_chroma_fingerprint(path: cstring; duration: ptr cdouble;
                             words: ptr ptr uint32; count: ptr cint): cint
                            {.exportc, cdecl, dynlib, raises: [].} =
  ## Fingerprint a file the way a lossy re-encode survives.
  ##
  ## `uaud_fingerprint` above is exact through a lossless re-encode and drifts
  ## to roughly 0.7 through a lossy one; this one holds above 0.98, at the cost
  ## of needing about three seconds of recording before it yields a word. The
  ## words are bit-for-bit Chromaprint's, so one taken here compares directly
  ## with one from `fpcalc`.
  ##
  ## Allocated here and released with `uaud_free`; a recording too short yields
  ## a count of zero and a null pointer, not an error.
  ensureRuntime()
  if path == nil or duration == nil or words == nil or count == nil:
    lastError = "path and every output pointer must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  words[] = nil
  count[] = 0
  duration[] = 0.0
  try:
    let print = chromaFingerprint(decodeFile($path))
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_chroma_similarity(a: ptr uint32; aCount: cint; b: ptr uint32;
                            bCount: cint): cdouble
                           {.exportc, cdecl, dynlib, raises: [].} =
  ## How alike two chroma fingerprints are, in [0, 1]. Two empty ones are not
  ## alike: they are unknown, which reads as 0.
  ensureRuntime()
  if a == nil or b == nil or aCount <= 0 or bCount <= 0: return 0.0
  var left, right: ChromaFingerprint
  let leftArray = cast[ptr UncheckedArray[uint32]](a)
  let rightArray = cast[ptr UncheckedArray[uint32]](b)
  for index in 0 ..< int(aCount): left.words.add leftArray[index]
  for index in 0 ..< int(bCount): right.words.add rightArray[index]
  try:
    cdouble(chromaSimilarity(left, right))
  except Exception:
    0.0

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
                   {.exportc, cdecl, dynlib, raises: [].} =
  ## What the file says about itself, as a UTF-8 JSON object. The string is
  ## allocated here and released with `uaud_free`.
  ##
  ## A file carrying no tags yields an object with empty fields, not an error:
  ## having nothing to say is not a failure. `date` is whatever the file wrote,
  ## unparsed, because tag dates follow no agreed format.
  ensureRuntime()
  if path == nil or json == nil:
    lastError = "path and json must be non-null"
    return cint(uaudErrArg)
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  json[] = nil
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_similarity(a: ptr uint32; aCount: cint; b: ptr uint32;
                     bCount: cint): cdouble {.exportc, cdecl, dynlib, raises: [].} =
  ## How alike two fingerprints are, in [0, 1]. Two empty fingerprints are
  ## not alike: they are unknown, which reads as 0.
  ensureRuntime()
  if a == nil or b == nil or aCount <= 0 or bCount <= 0: return 0.0
  var left, right: Fingerprint
  let leftArray = cast[ptr UncheckedArray[uint32]](a)
  let rightArray = cast[ptr UncheckedArray[uint32]](b)
  for index in 0 ..< int(aCount): left.words.add leftArray[index]
  for index in 0 ..< int(bCount): right.words.add rightArray[index]
  try:
    cdouble(similarity(left, right))
  except Exception:
    0.0

proc uaud_offset_similarity(a: ptr uint32; aCount: cint; b: ptr uint32;
                            bCount: cint; maxShift: cint): cdouble
                           {.exportc, cdecl, dynlib, raises: [].} =
  ## The best similarity over a bounded time shift, for two copies of a
  ## recording that start at different points.
  ensureRuntime()
  if a == nil or b == nil or aCount <= 0 or bCount <= 0 or maxShift < 0:
    return 0.0
  var first, second: Fingerprint
  let aWords = cast[ptr UncheckedArray[uint32]](a)
  let bWords = cast[ptr UncheckedArray[uint32]](b)
  for index in 0 ..< int(aCount): first.words.add aWords[index]
  for index in 0 ..< int(bCount): second.words.add bWords[index]
  try:
    cdouble(offsetSimilarity(first, second, int(maxShift)))
  except Exception:
    0.0

proc uaud_wave_probe(path: cstring; sampleRate, channels: ptr cint;
                     frames: ptr clonglong): cint {.exportc, cdecl, dynlib,
                         raises: [].} =
  ## Shape of a RIFF/WAVE file, without keeping the samples.
  ##
  ## Reads the whole file, because a WAV declares its size in a header that
  ## cannot be trusted: the frame count reported here is the one the data
  ## actually holds.
  ensureRuntime()
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
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)


type WaveWriterHandle = ref object
  ## Keeps a `WaveWriter` alive while C holds a pointer to it. The writer is an
  ## object, so a `ref` is what there is to pin: `GC_ref` at open, `GC_unref` at
  ## close, and nothing between the two moves it.
  writer: WaveWriter
  channels: int ## kept so a partial frame is refused before the writer sees it

proc uaud_wave_writer_open(path: cstring; sampleRate, channels,
                           bitsPerSample: cint; writer: ptr pointer): cint
                          {.exportc, cdecl, dynlib, raises: [].} =
  ## Start a RIFF/WAVE file whose length is not known yet, 16 or 24 bits.
  ##
  ## The batch writer needs every sample at once; this one takes them as they
  ## arrive. The handle is released by `uaud_wave_writer_close`, which is also
  ## what patches the sizes the header declares. A file abandoned without it
  ## keeps the provisional sizes and does not read back as a WAV at all,
  ## whatever reached the disk.
  ensureRuntime()
  if path == nil or writer == nil:
    lastError = "path and writer must be non-null"
    return cint(uaudErrArg)
  writer[] = nil
  if ($path).len == 0:
    lastError = "path must not be empty"
    return cint(uaudErrArg)
  if sampleRate <= 0 or sampleRate > cint(MaxSampleRate) or channels <= 0 or
      channels > cint(MaxChannels):
    lastError = "sample rate or channel count out of range"
    return cint(uaudErrArg)
  if bitsPerSample notin [cint(16), cint(24)]:
    lastError = "bits per sample must be 16 or 24"
    return cint(uaudErrArg)
  try:
    let handle = WaveWriterHandle(
      writer: newWaveWriter($path, int(sampleRate), int(channels),
                            int(bitsPerSample)),
      channels: int(channels))
    GC_ref(handle)
    writer[] = cast[pointer](handle)
    lastError = ""
    cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrIo)
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_wave_writer_write(writer: pointer; samples: ptr cfloat;
                            count: clonglong): cint
                           {.exportc, cdecl, dynlib, raises: [].} =
  ## Append `count` interleaved values: whole frames only, `channels` each.
  ensureRuntime()
  if writer == nil or (samples == nil and count > 0):
    lastError = "writer must be non-null, and samples too when count is not 0"
    return cint(uaudErrArg)
  if count < 0:
    lastError = "count must not be negative"
    return cint(uaudErrArg)
  try:
    let handle = cast[WaveWriterHandle](writer)
    if count == 0:
      lastError = ""
      return cint(uaudOk)
    if count mod handle.channels != 0:
      lastError = "a block must hold whole frames, not a partial one"
      return cint(uaudErrArg)
    let source = cast[ptr UncheckedArray[cfloat]](samples)
    handle.writer.writeFrames(source.toOpenArray(0, int(count) - 1))
    lastError = ""
    cint(uaudOk)
  except AudioError as error:
    lastError = error.msg
    cint(uaudErrFormat)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrIo)
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_wave_writer_frames(writer: pointer; frames: ptr clonglong): cint
                            {.exportc, cdecl, dynlib, raises: [].} =
  ## Frames written so far, per channel.
  ensureRuntime()
  if writer == nil or frames == nil:
    lastError = "writer and frames must be non-null"
    return cint(uaudErrArg)
  try:
    frames[] = clonglong(cast[WaveWriterHandle](writer).writer.frameCount)
    lastError = ""
    cint(uaudOk)
  except Exception:
    lastError = getCurrentExceptionMsg()
    cint(uaudErrFormat)

proc uaud_wave_writer_close(writer: pointer): cint
                           {.exportc, cdecl, dynlib, raises: [].} =
  ## Patch the sizes, close the file and release the handle.
  ##
  ## The handle is spent: passing it again is undefined, as with a pointer
  ## already freed. The library cannot check that for you — the memory is gone
  ## on return — so a caller that may close twice keeps its own flag.
  ensureRuntime()
  if writer == nil:
    lastError = "writer must be non-null"
    return cint(uaudErrArg)
  let handle = cast[WaveWriterHandle](writer)
  try:
    handle.writer.close()
    lastError = ""
    result = cint(uaudOk)
  except IOError, OSError:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrIo)
  except Exception:
    lastError = getCurrentExceptionMsg()
    result = cint(uaudErrFormat)
  GC_unref(handle)


