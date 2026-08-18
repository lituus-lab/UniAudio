# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## RIFF/WAVE, read and written.
##
## The simplest container this library handles, and the one every other decoder
## is checked against: a WAV of known samples is the fixture that says whether
## a FLAC or MP3 decode landed where it should.
##
## Bounds come first. A chunk header is attacker-controlled, so a declared size
## is checked against a ceiling and against what the file actually holds before
## a single byte is allocated.

import std/[streams, strutils]
import UniMath/native_float
import contracts
import ./pcm

const
  FormatPcm = 1
  FormatFloat = 3
  FormatExtensible = 0xFFFE

type WaveFormat = object
  encoding: int
  channels: int
  sampleRate: int
  bitsPerSample: int

# RIFF is little-endian throughout, which is what `readUint16`/`readUint32`
# already give on every platform this builds for. Widened to `int`/`int64` so a
# size near 2^32 cannot come back negative and pass a `> 0` check.
proc readU16(stream: Stream): int = int(stream.readUint16())
proc readU32(stream: Stream): int64 = int64(stream.readUint32())

proc parseFmt(stream: Stream; size: int): WaveFormat =
  ## The `fmt ` chunk: encoding, channel count, rate and bit depth. `size` is
  ## what the chunk header declared, and the whole of it is consumed either way,
  ## so the caller lands on the next chunk header.
  ##
  ## Byte rate and block alignment are read and dropped: both are derivable from
  ## the other fields, and a file that disagrees with itself about them is not
  ## worth trusting over the fields that matter. Channel count and rate are
  ## range-checked here rather than by the caller, because this is where a
  ## hostile header first becomes a number.
  if size < 16:
    raise newException(AudioError, "wav: fmt chunk is too short")
  result.encoding = stream.readU16()
  result.channels = stream.readU16()
  result.sampleRate = int(stream.readU32())
  discard stream.readU32() # byte rate, derivable
  discard stream.readU16() # block align, derivable
  result.bitsPerSample = stream.readU16()
  # WAVE_FORMAT_EXTENSIBLE keeps the real encoding in a GUID whose first two
  # bytes are the classic tag; the rest of the extension is not needed here.
  if size > 16:
    var skip = size - 16
    if result.encoding == FormatExtensible and skip >= 24:
      discard stream.readU16() # extension size
      discard stream.readU16() # valid bits
      discard stream.readU32() # channel mask
      result.encoding = stream.readU16()
      skip -= 10
    if skip > 0: discard stream.readStr(skip)
  if result.channels notin 1 .. MaxChannels:
    raise newException(AudioError,
      "wav: channel count out of range: " & $result.channels)
  if result.sampleRate notin 1 .. MaxSampleRate:
    raise newException(AudioError,
      "wav: sample rate out of range: " & $result.sampleRate)

proc decodeSamples(raw: string; format: WaveFormat): seq[float32] =
  ## One value per stored sample, in file order, so the caller receives the
  ## interleaving the file has rather than a layout invented here.
  let bytesPerSample = format.bitsPerSample div 8
  let count = raw.len div bytesPerSample
  result = newSeq[float32](count)
  case format.encoding
  of FormatPcm:
    case format.bitsPerSample
    of 8:
      for index in 0 ..< count:
        result[index] = fromPcm8(uint8(raw[index]))
    of 16:
      for index in 0 ..< count:
        let low = uint16(uint8(raw[index * 2]))
        let high = uint16(uint8(raw[index * 2 + 1]))
        result[index] = fromPcm16(cast[int16](low or (high shl 8)))
    of 24:
      for index in 0 ..< count:
        result[index] = fromPcm24(uint8(raw[index * 3]),
          uint8(raw[index * 3 + 1]), uint8(raw[index * 3 + 2]))
    of 32:
      for index in 0 ..< count:
        var value = 0'u32
        for byteIndex in 0 .. 3:
          value = value or
            (uint32(uint8(raw[index * 4 + byteIndex])) shl (8 * byteIndex))
        result[index] = fromPcm32(cast[int32](value))
    else:
      raise newException(AudioError,
        "wav: unsupported bit depth: " & $format.bitsPerSample)
  of FormatFloat:
    case format.bitsPerSample
    of 32:
      for index in 0 ..< count:
        var value = 0'u32
        for byteIndex in 0 .. 3:
          value = value or
            (uint32(uint8(raw[index * 4 + byteIndex])) shl (8 * byteIndex))
        result[index] = cast[float32](value)
    of 64:
      for index in 0 ..< count:
        var value = 0'u64
        for byteIndex in 0 .. 7:
          value = value or
            (uint64(uint8(raw[index * 8 + byteIndex])) shl (8 * byteIndex))
        result[index] = float32(cast[float64](value))
    else:
      raise newException(AudioError,
        "wav: unsupported float width: " & $format.bitsPerSample)
  else:
    raise newException(AudioError,
      "wav: unsupported encoding: " & $format.encoding)

proc readWave*(stream: Stream): AudioBuffer =
  ## Decode a RIFF/WAVE stream: integer PCM at 8, 16, 24 or 32 bits, IEEE float
  ## at 32 or 64, and `WAVE_FORMAT_EXTENSIBLE` wrapping either.
  ##
  ## The whole stream is read, and the frame count comes from how many samples
  ## the `data` chunk actually held — not from the size in its header, which an
  ## arbitrary file controls. Chunks other than `fmt ` and `data` are skipped,
  ## so a file carrying `LIST` or `fact` reads normally.
  ##
  ## Raises `AudioError` on anything malformed: a missing magic, a truncated
  ## chunk, a depth that is not a whole number of bytes, an encoding this
  ## library does not decode.
  if stream.readStr(4) != "RIFF":
    raise newException(AudioError, "wav: missing RIFF")
  discard stream.readU32() # declared file size, not trusted
  if stream.readStr(4) != "WAVE":
    raise newException(AudioError, "wav: missing WAVE")

  var format: WaveFormat
  var haveFormat = false
  var raw = ""
  var haveData = false
  while not stream.atEnd():
    let header = stream.readStr(8)
    if header.len < 8:
      if header.strip(chars = {'\0'}).len == 0: break # trailing padding
      raise newException(AudioError, "wav: truncated chunk header")
    let id = header[0 ..< 4]
    var size = 0'i64
    for index in 0 .. 3:
      size = size or (int64(uint8(header[4 + index])) shl (8 * index))
    if size < 0 or size > MaxChunkBytes:
      raise newException(AudioError, "wav: chunk exceeds the safety limit")
    case id
    of "fmt ":
      format = parseFmt(stream, int(size))
      haveFormat = true
    of "data":
      raw = stream.readStr(int(size))
      if raw.len < int(size):
        raise newException(AudioError, "wav: data chunk is truncated")
      haveData = true
    else:
      discard stream.readStr(int(size))
    # Chunks are word-aligned: an odd size is followed by one pad byte.
    if (size and 1) == 1 and not stream.atEnd(): discard stream.readStr(1)

  if not haveFormat: raise newException(AudioError, "wav: no fmt chunk")
  if not haveData: raise newException(AudioError, "wav: no data chunk")
  if format.bitsPerSample <= 0 or (format.bitsPerSample mod 8) != 0:
    raise newException(AudioError, "wav: bit depth is not a whole byte count")

  let samples = decodeSamples(raw, format)
  let frames = samples.len div format.channels
  result = initAudioBuffer(format.sampleRate, format.channels, frames)
  # A trailing partial frame is dropped: half a frame is not a frame.
  for index in 0 ..< frames * format.channels:
    result.samples[index] = samples[index]

proc readWaveFile*(path: string): AudioBuffer {.contractual.} =
  ## `readWave` over a file. A path that cannot be opened raises `IOError`,
  ## which is what separates a missing file from a malformed one.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmRead)
    if stream == nil:
      raise newException(IOError, "wav: cannot open " & path)
    defer: stream.close()
    readWave(stream)

# Little-endian, byte by byte rather than through `stream.write(uint16)`, so the
# bytes are the format's regardless of the host's own order.
proc writeU16(stream: Stream; value: int) =
  stream.write(uint8(value and 0xFF))
  stream.write(uint8((value shr 8) and 0xFF))

proc writeU32(stream: Stream; value: int) =
  ## Four little-endian bytes: a chunk size, a rate, a byte rate.
  for shift in [0, 8, 16, 24]:
    stream.write(uint8((value shr shift) and 0xFF))

func quantise*(sample: float32; bitsPerSample: int): int32 =
  ## One float sample as the integer a WAV of this depth stores.
  ##
  ## Round, then clamp. Truncating instead would cost up to a whole step and
  ## pull every sample towards silence, because it always rounds inwards — and
  ## a library with two writers that quantise differently produces two
  ## different files from one buffer, which is a trap in any round-trip test.
  ##
  ## The range is asymmetric because the format's is: at sixteen bits, -1 maps
  ## to -32768 and +1 clamps to 32767, so the most negative code is reachable
  ## and the most positive one is not.
  let peak = float32(1 shl (bitsPerSample - 1))
  var scaled = round(sample * peak)
  if scaled > peak - 1: scaled = peak - 1
  if scaled < -peak: scaled = -peak
  int32(scaled)

proc writePcm(stream: Stream; sample: float32; bitsPerSample: int) =
  ## One quantised sample, little-endian, in `bitsPerSample div 8` bytes.
  let value = quantise(sample, bitsPerSample)
  for index in 0 ..< bitsPerSample div 8:
    stream.write(uint8((value shr (8 * index)) and 0xFF))

const MaxRiffData* = high(uint32).int - 44
  ## A RIFF declares its sizes in 32 bits, so no WAV holds more than four
  ## gigabytes of samples less its header. A writer told to exceed it stops
  ## rather than wrapping the field and producing a file that reads as tiny.

proc writeWave*(stream: Stream; buffer: AudioBuffer; bitsPerSample = 16)
    {.contractual.} =
  ## Write 16- or 24-bit integer PCM. Samples outside [-1, 1] are clamped
  ## rather than left to wrap, which would turn a loud passage into noise.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  body:
    let dataBytes = buffer.samples.len * (bitsPerSample div 8)
    if dataBytes > MaxRiffData:
      raise newException(AudioError,
        "wav: this would pass the size a RIFF header can declare")
    # Checked in the body, not as a precondition: the depth comes from the
    # caller, and a precondition compiles away under -d:release, which would
    # leave a release build writing a malformed file in silence.
    if bitsPerSample notin [16, 24]:
      raise newException(AudioError,
        "wav: cannot write " & $bitsPerSample & " bits; 16 or 24")
    let bytesPerSample = bitsPerSample div 8
    stream.write("RIFF")
    stream.writeU32(36 + dataBytes)
    stream.write("WAVE")
    stream.write("fmt ")
    stream.writeU32(16)
    stream.writeU16(FormatPcm)
    stream.writeU16(buffer.format.channels)
    stream.writeU32(buffer.format.sampleRate)
    stream.writeU32(buffer.format.sampleRate * buffer.format.channels *
      bytesPerSample)
    stream.writeU16(buffer.format.channels * bytesPerSample)
    stream.writeU16(bitsPerSample)
    stream.write("data")
    stream.writeU32(dataBytes)
    for sample in buffer.samples:
      stream.writePcm(sample, bitsPerSample)

proc writeWaveFile*(path: string; buffer: AudioBuffer; bitsPerSample = 16)
    {.contractual.} =
  ## `writeWave` to a file, 16 or 24 bits. A path that cannot be opened for
  ## writing raises `IOError`; a depth this writer does not implement raises
  ## `AudioError`.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmWrite)
    if stream == nil:
      raise newException(IOError, "wav: cannot write " & path)
    defer: stream.close()
    writeWave(stream, buffer, bitsPerSample)



type WaveWriter* = object
  ## A WAV being written as its samples arrive.
  ##
  ## The batch writer needs the whole buffer, which a recording of unknown
  ## length does not have. This one writes the header with provisional sizes,
  ## appends frames, and patches the two size fields at `close`.
  ##
  ## Both writers quantise through `quantise`, so a file written either way
  ## from the same samples is byte for byte the same.
  stream: Stream
  channels, sampleRate, bitsPerSample: int
  samples: int ## values written, not frames
  ownsStream: bool
    ## Whether `close` should close the stream as well as finish the file.
    ## True only for the path constructor: a caller that passed its own stream
    ## keeps it, and closing a `StringStream` discards its data.
  closed: bool

proc newWaveWriter*(stream: Stream; sampleRate, channels: int;
                    bitsPerSample = 16): WaveWriter {.contractual.} =
  ## Write the header into `stream`, ready for frames.
  ##
  ## The sizes it declares are provisional and patched at `close`, which needs
  ## one seek — so the stream must be one that can seek. A file or a string
  ## both are; a pipe is not.
  ##
  ## Nothing is required of the caller. Every argument is checked in the body
  ## and raises `AudioError`: a precondition compiles away under `-d:release`,
  ## so one here would refuse a bad rate in debug and write a malformed header
  ## in release — and stating it twice makes the body's check unreachable in
  ## debug, which is how the two builds come to disagree about the exception.
  body:
    if bitsPerSample notin [16, 24]:
      raise newException(AudioError,
        "wav: cannot write " & $bitsPerSample & " bits; 16 or 24")
    if sampleRate notin 1 .. MaxSampleRate:
      raise newException(AudioError, "wav: sample rate out of range")
    if channels notin 1 .. MaxChannels:
      raise newException(AudioError, "wav: channel count out of range")
    if stream == nil:
      raise newException(IOError, "wav: no stream to write to")

    result.stream = stream
    result.sampleRate = sampleRate
    result.channels = channels
    result.bitsPerSample = bitsPerSample
    let bytesPerSample = bitsPerSample div 8
    stream.write("RIFF")
    stream.writeU32(0) # patched at close
    stream.write("WAVE")
    stream.write("fmt ")
    stream.writeU32(16)
    stream.writeU16(FormatPcm)
    stream.writeU16(channels)
    stream.writeU32(sampleRate)
    stream.writeU32(sampleRate * channels * bytesPerSample)
    stream.writeU16(channels * bytesPerSample)
    stream.writeU16(bitsPerSample)
    stream.write("data")
    stream.writeU32(0) # patched at close

proc newWaveWriter*(path: string; sampleRate, channels: int;
                    bitsPerSample = 16): WaveWriter {.contractual.} =
  ## `newWaveWriter` over a file. A path that cannot be opened for writing
  ## raises `IOError`; anything else the writer does not accept raises
  ## `AudioError`, in either build.
  require:
    path.len > 0
  body:
    let stream = newFileStream(path, fmWrite)
    if stream == nil:
      raise newException(IOError, "wav: cannot write " & path)
    result = newWaveWriter(stream, sampleRate, channels, bitsPerSample)
    result.ownsStream = true

proc writeFrames*(writer: var WaveWriter; samples: openArray[float32])
    {.contractual.} =
  ## Append interleaved samples: a whole number of frames, `channels` values
  ## each. Samples outside [-1, 1] are clamped rather than left to wrap.
  ##
  ## A partial frame is refused rather than padded — half a frame would shift
  ## every channel after it, which no later write can undo.
  require:
    not writer.closed
  body:
    if writer.stream == nil:
      raise newException(IOError, "wav: writer is closed")
    if samples.len mod writer.channels != 0:
      raise newException(AudioError,
        "wav: a block must hold whole frames, not a partial one")
    let bytesPerSample = writer.bitsPerSample div 8
    if samples.len > (MaxRiffData div bytesPerSample) - writer.samples:
      raise newException(AudioError,
        "wav: this would pass the size a RIFF header can declare")
    for sample in samples:
      writer.stream.writePcm(sample, writer.bitsPerSample)
    writer.samples += samples.len

proc close*(writer: var WaveWriter) {.contractual.} =
  ## Patch the two size fields and finish the file. The writer is spent
  ## afterwards.
  ##
  ## A file with no frames is still a valid WAV — an empty recording is a fact,
  ## not an error — so this does not refuse one.
  ##
  ## The stream is closed only when this writer opened it: a caller that passed
  ## its own keeps it, and closing a `StringStream` discards the data it came
  ## for.
  require:
    not writer.closed
  body:
    # A default-constructed writer never opened a stream. Saying nothing is
    # better than dereferencing nothing.
    if writer.stream == nil:
      writer.closed = true
      return
    writer.closed = true
    let dataBytes = writer.samples * (writer.bitsPerSample div 8)
    writer.stream.setPosition(4)
    writer.stream.writeU32(36 + dataBytes)
    writer.stream.setPosition(40)
    writer.stream.writeU32(dataBytes)
    if writer.ownsStream: writer.stream.close()
    else: writer.stream.setPosition(44 + dataBytes)

func frameCount*(writer: WaveWriter): int =
  ## Frames written so far, per channel. Zero for a writer that never opened
  ## anything, which has no channel count to divide by.
  if writer.channels <= 0: 0
  else: writer.samples div writer.channels


