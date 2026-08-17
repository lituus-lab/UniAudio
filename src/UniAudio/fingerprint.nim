# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## An acoustic fingerprint: what a recording sounds like, in a form two
## recordings can be compared by.
##
## The algorithm is Haitsma and Kalker's (*A Highly Robust Audio Fingerprinting
## System*, ISMIR 2002): band energies over short overlapping frames, one bit
## per band from the sign of a difference taken across both time and
## frequency. That double difference is what makes it survive re-encoding, a
## volume change or a different codec — anything that shifts energy uniformly
## cancels out.
##
## What it is for: recognising that two files in one library hold the same
## recording. The algorithm comes from the paper rather than from an
## implementation, so every step of it is testable against a written definition.

import UniMath/native_float
import contracts
import ./pcm
import ./fft

const
  FingerprintRate* = 11025
    ## Everything is resampled here first. Above about 5 kHz a recording
    ## carries little that survives lossy encoding, so a higher rate would
    ## cost time without making the fingerprint more distinctive.
  FrameSize* = 4096
    ## 371 ms at the fingerprint rate: long enough to resolve the low bands,
    ## short enough that one frame holds one musical moment.
  HopSize* = 1365
    ## Two thirds overlap, giving 8.08 frames per second.
  BandCount* = 33
    ## 33 band edges yield 32 differences, hence a 32-bit word per frame.
  MinFrequency* = 300.0
  MaxFrequency* = 3000.0
    ## The range where a recording's identity survives compression. Below 300
    ## Hz the spectrum is dominated by energy every codec preserves; above
    ## 3 kHz is what a codec discards first.

type Fingerprint* = object
  ## One 32-bit word per frame, in time order, and what they were taken from.
  durationSeconds*: float
  words*: seq[uint32]

func bandEdges(): seq[int] =
  ## Spectrum bin index of each band edge, spaced logarithmically so every
  ## band spans the same musical interval rather than the same number of hertz.
  result = newSeq[int](BandCount + 1)
  let ratio = MaxFrequency / MinFrequency
  for index in 0 .. BandCount:
    let frequency = MinFrequency * pow(ratio, float(index) / float(BandCount))
    result[index] = int(round(frequency * float(FrameSize) /
      float(FingerprintRate)))

proc fingerprint*(buffer: AudioBuffer): Fingerprint {.contractual.} =
  ## Fingerprint a decoded buffer. A recording shorter than two frames yields
  ## no words: one frame has nothing to be different from.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  body:
    result.durationSeconds = buffer.format.durationSeconds
    let mono = buffer.toMono().resample(FingerprintRate)
    if mono.format.frames < FrameSize + HopSize: return

    let window = hannWindow(FrameSize)
    let edges = bandEdges()
    let limit = FrameSize div 2
    var previous = newSeq[float64](BandCount)
    var current = newSeq[float64](BandCount)
    var first = true
    var offset = 0
    var frame = newSeq[float32](FrameSize)

    while offset + FrameSize <= mono.format.frames:
      for index in 0 ..< FrameSize:
        frame[index] = mono.samples[offset + index]
      let spectrum = powerSpectrum(frame, window)
      for band in 0 ..< BandCount:
        var total = 0.0
        let low = min(edges[band], limit)
        let high = min(edges[band + 1], limit)
        for bin in low ..< high:
          total += spectrum[bin]
        current[band] = total
      if first:
        first = false
      else:
        var word = 0'u32
        for bit in 0 ..< BandCount - 1:
          # The energy difference between neighbouring bands, differenced
          # again against the previous frame: a gain change moves every term
          # by the same factor and cancels.
          let now = current[bit] - current[bit + 1]
          let before = previous[bit] - previous[bit + 1]
          if now - before > 0.0:
            word = word or (1'u32 shl bit)
        result.words.add word
      swap(previous, current)
      offset += HopSize

func popcount(value: uint32): int {.inline.} =
  ## Set bits in a word, by Kernighan's method: `bits and (bits - 1)` clears the
  ## lowest set bit, so the loop turns once per set bit rather than 32 times.
  ## The Hamming distance between two fingerprint words is the popcount of their
  ## xor, which is what every comparison here reduces to.
  var bits = value
  while bits != 0:
    inc result
    bits = bits and (bits - 1)

proc similarity*(a, b: Fingerprint): float {.contractual.} =
  ## How alike two fingerprints are, in [0, 1], over the length they share.
  ##
  ## Compared over the common prefix rather than the whole of either: two
  ## copies of one recording often differ in trailing silence or an encoder's
  ## padding, and the shorter should not be penalised for what the longer has
  ## after it ends.
  ensure:
    result >= 0.0 and result <= 1.0
  body:
    let common = min(a.words.len, b.words.len)
    if common == 0: return 0.0
    var differing = 0
    for index in 0 ..< common:
      differing += popcount(a.words[index] xor b.words[index])
    1.0 - float(differing) / float(common * 32)

proc offsetSimilarity*(a, b: Fingerprint;
    maxShift = 64): float {.contractual.} =
  ## The best similarity over a bounded time shift, for two copies that start
  ## at different points — a track with a few seconds trimmed off the front is
  ## still the same recording.
  require:
    maxShift >= 0
  ensure:
    result >= 0.0 and result <= 1.0
  body:
    result = similarity(a, b)
    for shift in 1 .. maxShift:
      if shift < a.words.len:
        result = max(result,
          similarity(Fingerprint(words: a.words[shift .. ^1]), b))
      if shift < b.words.len:
        result = max(result,
          similarity(a, Fingerprint(words: b.words[shift .. ^1])))


