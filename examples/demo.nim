# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Write a tone, read it back, and report what came out.
import std/[math, os]
import UniAudio

echo "UniAudio " & UniAudioVersion

var tone = initAudioBuffer(44100, 2, 44100)
for index in 0 ..< tone.format.frames:
  for channel in 0 ..< tone.format.channels:
    let hz = 440.0 * float(channel + 1)
    tone.samples[index * tone.format.channels + channel] =
      float32(0.4 * sin(2.0 * PI * hz * float(index) / 44100.0))

let path = getTempDir() / "uniaudio_demo.wav"
writeWaveFile(path, tone)
let reloaded = readWaveFile(path)
removeFile(path)
echo "wrote and read back ", reloaded.format.frames, " frames, ",
  reloaded.format.channels, " channels at ", reloaded.format.sampleRate, " Hz (",
  reloaded.format.durationSeconds, " s)"
echo "mono mix: ", reloaded.toMono().format.channels, " channel"
echo "resampled to 11025 Hz: ", reloaded.resample(11025).format.frames, " frames"
