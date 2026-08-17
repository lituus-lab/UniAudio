# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## What each decoder costs, measured on one piece of audio put through all of
## them. Built by `nimble bench`; not part of the default gate.
##
## The units are nanoseconds per frame and the ratio of audio duration to time
## spent decoding it. Per-frame cost is the comparable one: these fixtures are
## 11025 Hz mono, and a 44.1 kHz stereo file carries eight times as many
## frame-channels per second of audio.
##
## Every decode feeds a non-inline sink that writes a global printed at the
## end, so the release optimizer cannot delete a call whose result goes unused.

import std/[strutils, times, os, math]
import UniAudio

var sink: uint64 = 0

proc keep(value: uint64) {.inline: false.} =
  sink = sink xor value

proc keepBuffer(buffer: AudioBuffer) =
  ## Reads a sample, not the buffer's address: the address would be the same
  ## every iteration, and the sink would then not depend on what was decoded.
  if buffer.samples.len > 0:
    keep(cast[uint64](buffer.samples[buffer.samples.len div 2]))
  keep(uint64(buffer.format.frames))

const Fixtures = "tests/fixtures"

type Row = object
  name: string
  nsPerFrame, realtime: float

var rows: seq[Row]
var tagMicroseconds: float

template measure(label: string; rounds, frames, rate: int; body: untyped) =
  # One untimed round first, so the file cache is warm for every format alike.
  block:
    body
  let start = cpuTime()
  for _ in 1 .. rounds:
    body
  let elapsed = cpuTime() - start
  let perFrame = elapsed * 1_000_000_000 / float(rounds * frames)
  let audioSeconds = float(frames) / float(rate)
  let realtime = audioSeconds * float(rounds) / elapsed
  rows.add Row(name: label, nsPerFrame: perFrame, realtime: realtime)
  echo alignLeft(label, 26), " | ",
    align(formatFloat(perFrame, ffDecimal, 1), 9), " ns/frame | ",
    align($int(round(realtime)), 7), "x realtime"

proc main() =
  let reference = readWaveFile(Fixtures / "sweep.wav")
  let frames = reference.format.frames
  let rate = reference.format.sampleRate
  echo "UniAudio decode benchmarks (release)"
  echo "input: ", frames, " frames at ", rate, " Hz, ",
    reference.format.channels, " channel, ",
    formatFloat(reference.format.durationSeconds, ffDecimal, 2), " s"
  echo repeat('-', 72)

  measure("wav", 200, frames, rate):
    keepBuffer(readWaveFile(Fixtures / "sweep.wav"))
  measure("flac", 100, frames, rate):
    keepBuffer(decodeFile(Fixtures / "sweep.flac"))
  measure("alac", 100, frames, rate):
    keepBuffer(decodeFile(Fixtures / "sweep-alac.m4a"))
  measure("vorbis", 50, frames, rate):
    keepBuffer(decodeFile(Fixtures / "sweep-vorbis.ogg"))
  measure("mp3", 50, frames, rate):
    keepBuffer(decodeFile(Fixtures / "sweep-mp3.mp3"))

  echo repeat('-', 72)
  measure("fingerprint (from wav)", 50, frames, rate):
    let print = fingerprint(reference)
    keep(uint64(print.words.len))

  block:
    # Tags are read from headers alone, so the unit that means anything is time
    # per file, not per frame.
    let rounds = 2000
    let start = cpuTime()
    for _ in 1 .. rounds:
      keep(uint64(readTagsFile(Fixtures / "tagged.flac").title.len))
    tagMicroseconds = (cpuTime() - start) * 1_000_000 / float(rounds)
    echo alignLeft("tags (flac)", 26), " | ",
      align(formatFloat(tagMicroseconds, ffDecimal, 1), 9), " us/file"

  echo repeat('-', 72)
  # Bracketed for bench/export_readme.nim, which splices it into the README
  # rather than anyone retyping it.
  echo "<!-- table -->"
  echo "Input: ", frames, " frames at ", rate, " Hz, ",
    reference.format.channels, " channel, ",
    formatFloat(reference.format.durationSeconds, ffDecimal, 2), " s."
  echo ""
  echo "| operation | ns/frame | realtime |"
  echo "| --- | ---: | ---: |"
  for row in rows:
    echo "| ", row.name, " | ", formatFloat(row.nsPerFrame, ffDecimal, 1),
      " | ", $int(round(row.realtime)), "x |"

  echo ""
  echo "Tags, read from headers and never touching the audio: ",
    formatFloat(tagMicroseconds, ffDecimal, 1), " us per file."
  echo "<!-- /table -->"

  echo "sink = ", sink        # keeps every decode live across the suite

main()
