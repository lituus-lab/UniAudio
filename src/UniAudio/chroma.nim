# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## A chroma fingerprint: the Chromaprint algorithm, in Nim.
##
## `fingerprint.nim` carries Haitsma and Kalker's band-energy fingerprint,
## which is exact through lossless re-encoding and drifts to roughly 70%
## agreement through a lossy one — the bit error rate that algorithm is
## designed around. Recognising a re-encoded copy at a high threshold needs a
## different construction, which is this one.
##
## Twelve pitch classes per frame rather than 32 band differences; the
## chromagram is smoothed across time, normalised per frame, and read by 16
## filters over rectangles of it, each quantised to two bits. A codec that
## moves energy within a pitch class leaves the filters where they were, which
## is why the result survives what the band differences do not.
##
## Ported from Chromaprint, which is MIT-licensed; see NOTICE. The words are
## bit-for-bit the reference implementation's, checked against `fpcalc` on WAV,
## FLAC, MP3, Vorbis and ALAC. Only
## Chromaprint's own sources are involved — the FFT here is `UniAudio`'s, so
## none of the LGPL code Chromaprint bundles is reached.

import UniMath/native_float
import contracts
import ./pcm
import ./fft

const
  ChromaRate* = 11025
    ## Everything is resampled here first, as the reference implementation does.
  ChromaFrameSize* = 4096
  ChromaFrameOverlap* = ChromaFrameSize - ChromaFrameSize div 3
  ChromaHopSize* = ChromaFrameSize - ChromaFrameOverlap
  ChromaBands* = 12
    ## The twelve pitch classes.
  ChromaMinFrequency* = 28.0
  ChromaMaxFrequency* = 3520.0
    ## A7. Above it a pitch class is no longer what a codec preserves.
  ChromaFilterCoefficients = [0.25, 0.75, 1.0, 0.75, 0.25]
  ChromaNormThreshold = 0.01
    ## A frame quieter than this normalises to zero rather than to amplified
    ## noise.

type
  ChromaFingerprint* = object
    ## One 32-bit word per frame, in time order, and what they were taken from.
    durationSeconds*: float
    words*: seq[uint32]

  Classifier = object
    ## One filter over the chromagram, and the thresholds that cut its output
    ## into two bits.
    kind: range[0 .. 5]
    y, height, width: int
    t0, t1, t2: float64

const Classifiers: array[16, Classifier] = [
  Classifier(kind: 0, y: 4, height: 3, width: 15,
             t0: 1.98215, t1: 2.35817, t2: 2.63523),
  Classifier(kind: 4, y: 4, height: 6, width: 15,
             t0: -1.03809, t1: -0.651211, t2: -0.282167),
  Classifier(kind: 1, y: 0, height: 4, width: 16,
             t0: -0.298702, t1: 0.119262, t2: 0.558497),
  Classifier(kind: 3, y: 8, height: 2, width: 12,
             t0: -0.105439, t1: 0.0153946, t2: 0.135898),
  Classifier(kind: 3, y: 4, height: 4, width: 8,
             t0: -0.142891, t1: 0.0258736, t2: 0.200632),
  Classifier(kind: 4, y: 0, height: 3, width: 5,
             t0: -0.826319, t1: -0.590612, t2: -0.368214),
  Classifier(kind: 1, y: 2, height: 2, width: 9,
             t0: -0.557409, t1: -0.233035, t2: 0.0534525),
  Classifier(kind: 2, y: 7, height: 3, width: 4,
             t0: -0.0646826, t1: 0.00620476, t2: 0.0784847),
  Classifier(kind: 2, y: 6, height: 2, width: 16,
             t0: -0.192387, t1: -0.029699, t2: 0.215855),
  Classifier(kind: 2, y: 1, height: 3, width: 2,
             t0: -0.0397818, t1: -0.00568076, t2: 0.0292026),
  Classifier(kind: 5, y: 10, height: 1, width: 15,
             t0: -0.53823, t1: -0.369934, t2: -0.190235),
  Classifier(kind: 3, y: 6, height: 2, width: 10,
             t0: -0.124877, t1: 0.0296483, t2: 0.139239),
  Classifier(kind: 2, y: 1, height: 1, width: 14,
             t0: -0.101475, t1: 0.0225617, t2: 0.231971),
  Classifier(kind: 3, y: 5, height: 6, width: 4,
             t0: -0.0799915, t1: -0.00729616, t2: 0.063262),
  Classifier(kind: 1, y: 9, height: 2, width: 12,
             t0: -0.272556, t1: 0.019424, t2: 0.302559),
  Classifier(kind: 3, y: 4, height: 2, width: 14,
             t0: -0.164292, t1: -0.0321188, t2: 0.0846339)]

const GrayCodes = [0'u32, 1, 3, 2]
  ## Two adjacent quantiser levels differ in one bit, so a value that lands
  ## just the wrong side of a threshold costs one bit rather than two.

func hammingWindow(size: int): seq[float64] =
  ## The window the reference implementation uses. Not `hannWindow`: the two
  ## leak differently at the band edges, and a fingerprint that must agree with
  ## another implementation agrees on the window too.
  result = newSeq[float64](size)
  for index in 0 ..< size:
    result[index] = 0.54 - 0.46 * cos(2.0 * PI * float(index) /
      float(size - 1))

func noteOf(frequency: float): int =
  ## Which pitch class a frequency falls in. The base is 27.5 Hz, A0, so an
  ## octave starts on A.
  let octave = ln(frequency / (440.0 / 16.0)) / ln(2.0)
  int(float(ChromaBands) * (octave - floor(octave)))

type IntegralImage = object
  ## Running sums of the chromagram over both axes, so a rectangle costs four
  ## reads whatever its size.
  rows: seq[array[ChromaBands, float64]]

proc addRow(image: var IntegralImage;
            features: array[ChromaBands, float64]) =
  var row: array[ChromaBands, float64]
  var running = 0.0
  for band in 0 ..< ChromaBands:
    running += features[band]
    row[band] = running
    if image.rows.len > 0:
      row[band] += image.rows[^1][band]
  image.rows.add row

func area(image: IntegralImage; x1, y1, x2, y2: int): float64 =
  ## The sum over rows `x1 ..< x2` and bands `y1 ..< y2`.
  if x2 == x1 or y2 == y1: return 0.0
  let right = image.rows[x2 - 1]
  result = right[y2 - 1]
  if y1 > 0: result -= right[y1 - 1]
  if x1 > 0:
    let left = image.rows[x1 - 1]
    result -= left[y2 - 1]
    if y1 > 0: result += left[y1 - 1]

func subtractLog(a, b: float64): float64 =
  ln((1.0 + a) / (1.0 + b))

func applyFilter(image: IntegralImage; c: Classifier; x: int): float64 =
  let
    y = c.y
    w = c.width
    h = c.height
  case c.kind
  of 0:
    subtractLog(image.area(x, y, x + w, y + h), 0.0)
  of 1:
    let h2 = h div 2
    subtractLog(image.area(x, y + h2, x + w, y + h),
                image.area(x, y, x + w, y + h2))
  of 2:
    let w2 = w div 2
    subtractLog(image.area(x + w2, y, x + w, y + h),
                image.area(x, y, x + w2, y + h))
  of 3:
    let w2 = w div 2
    let h2 = h div 2
    subtractLog(image.area(x, y + h2, x + w2, y + h) +
                  image.area(x + w2, y, x + w, y + h2),
                image.area(x, y, x + w2, y + h2) +
                  image.area(x + w2, y + h2, x + w, y + h))
  of 4:
    let h3 = h div 3
    subtractLog(image.area(x, y + h3, x + w, y + 2 * h3),
                image.area(x, y, x + w, y + h3) +
                  image.area(x, y + 2 * h3, x + w, y + h))
  of 5:
    let w3 = w div 3
    subtractLog(image.area(x + w3, y, x + 2 * w3, y + h),
                image.area(x, y, x + w3, y + h) +
                  image.area(x + 2 * w3, y, x + w, y + h))

func quantise(c: Classifier; value: float64): int =
  if value < c.t1:
    if value < c.t0: 0 else: 1
  else:
    if value < c.t2: 2 else: 3

proc chromaFingerprint*(buffer: AudioBuffer): ChromaFingerprint
    {.contractual.} =
  ## Fingerprint a decoded buffer.
  ##
  ## The widest filter spans 16 rows and the smoothing costs four frames, so a
  ## recording shorter than about three seconds yields no word at all rather
  ## than a short one: there is no rectangle for the filters to read.
  require:
    buffer.format.isValid
    buffer.samples.len == buffer.format.sampleCount
  body:
    result.durationSeconds = buffer.format.durationSeconds
    let mono = buffer.toMono().resample(ChromaRate)
    if mono.format.frames < ChromaFrameSize: return

    let window = hammingWindow(ChromaFrameSize)
    let limit = ChromaFrameSize div 2
    let minIndex = max(1, int(ChromaMinFrequency * float(ChromaFrameSize) /
      float(ChromaRate)))
    let maxIndex = min(limit, int(ChromaMaxFrequency *
      float(ChromaFrameSize) / float(ChromaRate)))

    # Which pitch class each bin belongs to, computed once.
    var notes = newSeq[int](maxIndex)
    for bin in minIndex ..< maxIndex:
      notes[bin] = noteOf(float(bin) * float(ChromaRate) /
        float(ChromaFrameSize))

    var widest = 0
    for c in Classifiers:
      if c.width > widest: widest = c.width

    var smoothing: seq[array[ChromaBands, float64]]
    var image: IntegralImage
    var frame = newSeq[float32](ChromaFrameSize)
    var offset = 0

    while offset + ChromaFrameSize <= mono.format.frames:
      for index in 0 ..< ChromaFrameSize:
        frame[index] = mono.samples[offset + index]
      let spectrum = powerSpectrum(frame, window)

      var features: array[ChromaBands, float64]
      for bin in minIndex ..< maxIndex:
        features[notes[bin]] += spectrum[bin]

      # Smoothed across five frames before it is normalised: one frame's noise
      # would otherwise reach the filters.
      smoothing.add features
      if smoothing.len >= ChromaFilterCoefficients.len:
        var smoothed: array[ChromaBands, float64]
        let base = smoothing.len - ChromaFilterCoefficients.len
        for band in 0 ..< ChromaBands:
          var total = 0.0
          for step in 0 ..< ChromaFilterCoefficients.len:
            total += smoothing[base + step][band] *
              ChromaFilterCoefficients[step]
          smoothed[band] = total

        var squares = 0.0
        for band in 0 ..< ChromaBands:
          squares += smoothed[band] * smoothed[band]
        let norm = if squares > 0.0: sqrt(squares) else: 0.0
        if norm < ChromaNormThreshold:
          for band in 0 ..< ChromaBands: smoothed[band] = 0.0
        else:
          for band in 0 ..< ChromaBands: smoothed[band] /= norm

        image.addRow(smoothed)
        if image.rows.len >= widest:
          let at = image.rows.len - widest
          var bits = 0'u32
          for c in Classifiers:
            bits = (bits shl 2) or
              GrayCodes[c.quantise(applyFilter(image, c, at))]
          result.words.add bits

      offset += ChromaHopSize

func chromaSimilarity*(a, b: ChromaFingerprint): float {.contractual.} =
  ## How alike two chroma fingerprints are, in [0, 1], over the length they
  ## share.
  ensure:
    result >= 0.0 and result <= 1.0
  body:
    let common = min(a.words.len, b.words.len)
    if common == 0: return 0.0
    var differing = 0
    for index in 0 ..< common:
      var bits = a.words[index] xor b.words[index]
      while bits != 0:
        inc differing
        bits = bits and (bits - 1)
    1.0 - float(differing) / float(common * 32)



