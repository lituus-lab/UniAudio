<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# uniaudio — Python binding

Audio containers, decoders for the formats under no licence, tags, and an
acoustic fingerprint. A thin binding over the UniAudio C library: what the C
ABI cannot reach, this cannot reach either.

```bash
pip install uniaudio
```

Every value shown below is what the call returns for the file named, one of
this repository's own test fixtures.

```python
import uniaudio

uniaudio.sniff("tagged.m4a")           # 'mp4'
uniaudio.probe("tagged.m4a")           # (44100, 1, 9000)
uniaudio.tags("tagged.m4a")["title"]   # 'Été à Nice'
```

`decode` returns the samples themselves, as one `array.array('f')` of
interleaved values in [-1, 1]:

```python
rate, channels, frames, samples = uniaudio.decode("tagged.m4a")
len(samples) == frames * channels      # True
```

`decode_resampled(path, target_rate, to_mono)` mixes and resamples in the same
pass. Three ways out: `write_wave` for uncompressed PCM, `write_flac` and
`write_alac` for the same samples losslessly compressed.

`probe` returns `(sample_rate, channels, frames)`, where `frames` counts per
channel. WAV, AIFF, FLAC, ALAC in MP4, Vorbis in Ogg and MP3 all decode; a
container holding a codec this library does not decode — AAC, Opus — raises a
`UniAudioError` naming the codec it found.

Two recordings can be compared by how they sound rather than by their bytes,
which finds duplicates no checksum would match:

```python
_, a = uniaudio.fingerprint("sweep.flac")
_, b = uniaudio.fingerprint("sweep-mp3.mp3")
uniaudio.similarity(a, b)              # 0.7738095238095238
```

That figure is a sine sweep, which is the hardest case there is for this
fingerprint: nearly all its energy sits in one band at a time, so a lossy
encode flips many bits at once. Do not read it as what the fingerprint does to
music.

## Building from a checkout

```bash
nimble clib                                    # build libUniAudio
cd py && python3 setup.py build_ext --inplace  # build the extension
cd py && python3 -m pytest -q                  # test
```

`notebooks/quickstart.ipynb` is the same tour with its output filled in by
actually running it.
