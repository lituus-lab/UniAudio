<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# bench — what the decoders cost

Isolated benchmark harness. **Not part of the default gate** (`test` /
`testAll` / `lint` / `checkVGraph` / `docs`); run it explicitly:

```bash
nimble bench          # print the timings
nimble benchReadme    # print them and splice them into this file
```

It builds with `-d:release`, so the `NimContracts` postconditions compile away
and the timings reflect the code that actually ships. The fixtures are read by
relative path, so the run has to start from the repository root — which is what
both tasks do.

## What is measured

One piece of audio — three seconds of a sine sweep — put through five formats,
so the per-frame costs are directly comparable: same signal, same length, same
rate. Then the fingerprint over the same samples, and a tag read.

## Reading the numbers

**Per-frame cost is the comparable figure; the realtime multiple is not.** The
input is 11025 Hz mono. A 44.1 kHz stereo file carries eight times as many
frame-channels per second of audio, so at the same per-frame cost its realtime
multiple would be roughly an eighth of what appears below. Nothing here is a
claim about decoding music at CD rate.

Every timed result feeds a non-inline sink that writes a global printed at the
end of the run. Without it a release build is free to notice that a decoded
buffer is never read and delete the call, which would read as an implausibly
fast decoder rather than as a missing one.

Each format gets one untimed round before the timed ones, so a cold file cache
does not land on whichever decoder happens to run first. Run-to-run variation
on a shared machine is real and visible — a figure here is one measurement, not
a specification.

WAV is close to free — it converts integers to floats and does nothing else —
and stands as the floor the rest are measured against, not as a decoder worth
comparing.

MP3 coming out ahead of FLAC says nothing about the formats. The MP3 path is a
port of an implementation tuned over years, with a hand-unrolled synthesis
filter; the FLAC path is written for clarity and has had no such attention.
Both are far faster than any use this library was built for needs.

## Results

Written by `nimble benchReadme` from a real run. Each machine keeps its own
block, so a second one appends rather than overwriting the first.

<!-- bench:insert -->

<!-- bench:machine=macosx-apple-m4 -->

Input: 33075 frames at 11025 Hz, 1 channel, 3.00 s.

| operation | ns/frame | realtime |
| --- | ---: | ---: |
| wav | 1.8 | 50171x |
| flac | 38.6 | 2353x |
| alac | 63.7 | 1423x |
| vorbis | 65.1 | 1393x |
| mp3 | 26.6 | 3414x |
| fingerprint (from wav) | 35.3 | 2570x |

Tags, read from headers and never touching the audio: 12.4 us per file.

<!-- /bench:machine=macosx-apple-m4 -->
