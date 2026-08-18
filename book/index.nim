# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import std/[os, math, strformat]
import nimib

nbInit
nb.title = "UniAudio"

nbText: """
# UniAudio

Audio containers, decoders and tags, plus an acoustic fingerprint built on
them. Give it a file and it gives you samples, whatever the file turned out to
be.

Every Nim block below is compiled and run when this page is built, and the
output shown is what the code actually produced. Prose that outlives the API it
describes breaks the build rather than quietly misleading you.

## Samples are one shape

Every decoder produces the same thing: interleaved 32-bit floats in [-1, 1],
with the rate and channel count that give them meaning. Fixing one
representation at the boundary is what lets a fingerprint, a waveform display
and a converter all consume the same buffer without caring which decoder filled
it.
"""

nbCode:
  import UniAudio

  echo "UniAudio ", UniAudioVersion

  # Half a second of a 440 Hz tone, in stereo.
  var tone = initAudioBuffer(sampleRate = 44100, channels = 2, frames = 22050)
  for frame in 0 ..< tone.format.frames:
    let value = float32(0.4 * sin(2 * PI * 440 * float(frame) / 44100.0))
    tone.samples[frame * 2] = value
    tone.samples[frame * 2 + 1] = value

  echo "rate ", tone.format.sampleRate,
    ", channels ", tone.format.channels,
    ", frames ", tone.format.frames,
    ", ", tone.format.durationSeconds, " s"

nbText: """
`frames` counts per channel, so a buffer holds `frames * channels` samples. The
two are easy to confuse, and confusing them halves or doubles a duration.

## Writing and reading back

Three formats go out as well as come in: WAV uncompressed, FLAC and ALAC
losslessly compressed.
"""

nbCode:
  let stem = getTempDir() / "uniaudio-book-tone"
  writeWaveFile(stem & ".wav", tone)
  writeFlacFile(stem & ".flac", tone)
  writeAlacFile(stem & ".m4a", tone)
  for suffix in [".wav", ".flac", ".m4a"]:
    let path = stem & suffix
    let reread = decodeFile(path)
    var worst = 0.0
    for index in 0 ..< tone.samples.len:
      worst = max(worst, abs(float(reread.samples[index]) -
        float(tone.samples[index])))
    echo suffix, ": ", getFileSize(path), " bytes, ", reread.format.frames,
      " frames back, worst difference ", worst
    removeFile(path)

nbText: """
All three report the same worst difference, and it is not zero. `tone` holds
`float32` samples, the files hold 16-bit integers, and no 16-bit integer sits
exactly where most of those floats do. Each writer rounds to the nearest one, so
the worst it can be off by is half a step — 1/65536, the number printed above.
Lossless means the integers survive, not that a float source passes through
untouched. Ask for 24 bits and the difference shrinks by a factor of 256.

The sizes differ for a different reason. The ALAC encoder fits an adaptive
filter to the signal; the FLAC encoder here uses the format's fixed predictors
only, which is what `flac -0` does. On a smooth tone the adaptive filter wins
easily. Both files decode to exactly the same samples.

## Writing a file whose length you do not know yet

`writeWaveFile` needs every sample at once. A recording being captured does not
have them: it has the block that just arrived. `newWaveWriter` writes the header
with provisional sizes, takes frames as they come, and patches the sizes at
`close`.
"""

nbCode:
  let streamed = getTempDir() / "uniaudio-book-streamed.wav"
  block:
    var writer = newWaveWriter(streamed, tone.format.sampleRate,
                               tone.format.channels)
    # Blocks of whatever size arrives; the split must not reach the file.
    var sent = 0
    for size in [64, 300, 1000]:
      let take = min(size * tone.format.channels, tone.samples.len - sent)
      if take <= 0: break
      writer.writeFrames(tone.samples.toOpenArray(sent, sent + take - 1))
      sent += take
    writer.writeFrames(tone.samples.toOpenArray(sent, tone.samples.len - 1))
    echo "frames written: ", writer.frameCount
    writer.close()

  let batch = getTempDir() / "uniaudio-book-batch.wav"
  writeWaveFile(batch, tone)
  echo "same bytes as the batch writer: ",
    readFile(streamed) == readFile(batch)
  removeFile(streamed)
  removeFile(batch)

nbText: """
The two files are identical, byte for byte. Both quantise the same way, so
where the block boundaries fell leaves no trace — which is the property that
makes a streamed capture safe to compare against a file written in one go.

A writer that is never closed leaves the provisional sizes in place, and the
file does not read back as a WAV at all — however many frames went into it.
That is the one thing to get right: `close` is what finishes the file.

## One entry point, whatever the container

A caller should not have to know what a file is before opening it, and the
extension is not evidence: a `.wav` holding a FLAC stream is a real thing.
`sniffFile` names the container from the bytes, and `decodeFile` decodes it.

Below are the same three seconds of a sine sweep, put through five formats.
"""

nbCode:
  const Fixtures = "tests/fixtures"
  for name in ["sweep.wav", "sweep.flac", "sweep-alac.m4a",
               "sweep-vorbis.ogg", "sweep-mp3.mp3"]:
    let path = Fixtures / name
    let decoded = decodeFile(path)
    echo &"{name:<18} {sniffFile(path):<5} " &
      &"{decoded.format.sampleRate} Hz, {decoded.format.channels} ch, " &
      &"{decoded.format.frames} frames"

nbText: """
Each of them decodes to the same shape. The formats differ in what they keep,
not in what they claim to be.

## What lossless means, measured

FLAC and ALAC give back exactly what went in. Vorbis and MP3 do not, and the
interesting question is by how much. Comparing each decode against the original
WAV answers it.
"""

nbCode:
  let original = readWaveFile(Fixtures / "sweep.wav")

  proc worstDifference(other: AudioBuffer): float =
    for index in 0 ..< min(original.samples.len, other.samples.len):
      result = max(result,
        abs(float(original.samples[index]) - float(other.samples[index])))

  for name in ["sweep.flac", "sweep-alac.m4a", "sweep-vorbis.ogg",
               "sweep-mp3.mp3"]:
    echo &"{name:<18} worst sample difference " &
      &"{worstDifference(decodeFile(Fixtures / name)):.6f}"

nbText: """
The two lossless formats come back at zero. The two lossy ones do not, and no
amount of care in the decoder would change that — the information went at the
encoder.

## Tags

Four unrelated tagging schemes grew up around these formats. `readTagsFile`
reads whichever one a file uses into the same shape, so a caller never has to
know which.
"""

nbCode:
  let tags = readTagsFile(Fixtures / "tagged.flac")
  echo "title  ", tags.title
  echo "artist ", tags.artist
  echo "album  ", tags.album
  echo "date   ", tags.date
  echo "track  ", tags.trackNumber, " of ", tags.trackTotal

nbText: """
`date` is whatever the file wrote, kept as a string and not parsed. Tags carry
`2019`, `2019-04-01` and worse; deciding which half of a bare `01/02/2019` is
the month would be an invention, and the file does not answer it.

A name with no field of its own is not dropped — it goes to `other`, under the
name the file used.
"""

nbCode:
  for (key, value) in tags.other:
    echo key, " = ", value

nbText: """
## Recognising a recording by how it sounds

The fingerprint is an acoustic one: it describes how a recording sounds, not
what its bytes are. Two encodings of the same audio give nearly the same
fingerprint, which is what makes it useful for finding duplicates no checksum
would match.

It works on the sound, so it needs the decode, not the file.
"""

nbCode:
  let fromWave = fingerprint(readWaveFile(Fixtures / "sweep.wav"))
  let fromFlac = fingerprint(decodeFile(Fixtures / "sweep.flac"))
  echo "words: ", fromWave.words.len
  echo "wav against flac: ", similarity(fromWave, fromFlac)

nbText: """
FLAC is lossless, so the two decodes are identical and the fingerprint matches
exactly. A lossy encode moves it. How far depends on the material, and a pure
sweep is the hardest case there is: almost all its energy sits in one band at a
time, so a small change there flips many bits at once. Do not read the numbers
below as what the fingerprint does to music.
"""

nbCode:
  let fromMp3 = fingerprint(decodeFile(Fixtures / "sweep-mp3.mp3"))
  let fromVorbis = fingerprint(decodeFile(Fixtures / "sweep-vorbis.ogg"))
  echo "wav against mp3:    ", similarity(fromWave, fromMp3)
  echo "wav against vorbis: ", similarity(fromWave, fromVorbis)

nbText: """
## When a file cannot be decoded

MP4 and Ogg are containers, and each carries more codecs than this library
decodes. Both are recognised as containers either way, so the useful answer is
available: the error names the codec found inside, which is something you can
act on where "unsupported file" is not.

## The other two surfaces

The same library is a C ABI and a Python package. Both are thin: what the ABI
cannot reach, the Python binding cannot reach either.

```c
#include "UniAudio.h"

int rate, channels;
long long frames;
float *samples;
if (uaud_decode("take.flac", &rate, &channels, &frames, &samples) != UAUD_OK)
    fprintf(stderr, "%s\n", uaud_last_error());
else
    uaud_free(samples);   /* frames * channels interleaved floats */
```

```python
from uniaudio import decode, tags

rate, channels, frames, samples = decode("take.flac")
print(tags("take.flac")["title"])
```

`samples` comes back as one `array.array('f')`, not a list — a three-minute
stereo track is sixteen million values, and building a Python object for each
of them would cost more than the decode.

No Nim exception crosses the C boundary: every entry point returns a status,
with the reason available from `uaud_last_error`.
"""

nbSave
