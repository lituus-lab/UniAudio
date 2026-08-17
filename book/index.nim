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

The WAV writer is the one place this library produces a file rather than
consuming one. It exists so a decode can be checked against something you can
open elsewhere.
"""

nbCode:
  let scratch = getTempDir() / "uniaudio-book-tone.wav"
  writeWaveFile(scratch, tone)
  let reread = readWaveFile(scratch)
  echo "read back ", reread.format.frames, " frames at ",
    reread.format.sampleRate, " Hz"
  removeFile(scratch)

nbText: """
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
## What is deliberately absent

There is no AAC decoder here. The library implements formats nobody charges
for: FLAC and Vorbis, royalty-free by design; ALAC, whose reference codec Apple
released under Apache 2.0, with the patent grant that licence carries; and MP3,
whose last patents expired in 2017.

AAC is the line that draws itself: it carries an active patent licence, and a
decoder here would hand that obligation to everything downstream.

A format it will not decode is named in the error rather than approximated:
knowing a file is AAC and unsupported is something you can act on, "unsupported
file" is not.

The same rule decides what a recognised container may hold. An MP4 or an Ogg is
read as a container either way, and the error names the codec found inside.

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
