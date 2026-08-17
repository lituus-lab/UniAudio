# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Radix-2 FFT, enough for a spectrogram and no more.
##
## An acoustic fingerprint needs the magnitude spectrum of short overlapping
## frames — no inverse transform, no arbitrary lengths, no convolution.
##
## Iterative Cooley-Tukey with bit reversal, in place. Lengths must be powers
## of two: an audio frame size is chosen, not given.
##
## The values are `UniMath`'s `Complex[float64]`, re-exported here so a caller
## needs one import: what a complex number is belongs to the numeric layer, not
## to this one.

import UniMath/native_float
import UniMath/complex
import contracts

export complex

func isPowerOfTwo*(n: int): bool =
  n > 0 and (n and (n - 1)) == 0

proc bitReverse(values: var seq[Complex[float64]]) =
  ## Reorder so the butterflies below read contiguous pairs.
  let n = values.len
  var target = 0
  for source in 0 ..< n - 1:
    if source < target:
      swap(values[source], values[target])
    var mask = n shr 1
    while target >= mask and mask > 0:
      target -= mask
      mask = mask shr 1
    target += mask

proc fft*(values: var seq[Complex[float64]]) {.contractual.} =
  ## In-place forward transform. `values.len` must be a power of two.
  require:
    isPowerOfTwo(values.len)
  body:
    let n = values.len
    if n == 1: return
    bitReverse(values)
    var span = 2
    while span <= n:
      # The twiddle factor advances by one rotation per butterfly, so it is
      # multiplied rather than recomputed from a cosine each time.
      let angle = -2.0 * PI / float(span)
      let step = complex(cos(angle), sin(angle))
      var start = 0
      while start < n:
        var twiddle = complex(1.0, 0.0)
        for offset in 0 ..< span div 2:
          let a = values[start + offset]
          let product = values[start + offset + span div 2] * twiddle
          values[start + offset] = a + product
          values[start + offset + span div 2] = a - product
          twiddle = twiddle * step
        start += span
      span = span shl 1

proc hannWindow*(size: int): seq[float64] {.contractual.} =
  ## Raised cosine. Chosen over a rectangular window because a frame cut out
  ## of a continuous signal has discontinuous ends, whose spectral leakage
  ## would swamp the band energies a fingerprint compares.
  require:
    size > 1
  ensure:
    result.len == size
  body:
    result = newSeq[float64](size)
    for index in 0 ..< size:
      result[index] = 0.5 * (1.0 - cos(2.0 * PI * float(index) /
        float(size - 1)))

proc powerSpectrum*(samples: openArray[float32];
                    window: openArray[float64]): seq[float64] {.contractual.} =
  ## Squared magnitude of the first half of the spectrum — the only half a
  ## real signal carries information in.
  require:
    isPowerOfTwo(samples.len)
    window.len == samples.len
  ensure:
    result.len == samples.len div 2
  body:
    var values = newSeq[Complex[float64]](samples.len)
    for index in 0 ..< samples.len:
      values[index] = complex(float64(samples[index]) * window[index])
    fft(values)
    result = newSeq[float64](samples.len div 2)
    for index in 0 ..< result.len:
      result[index] = norm2(values[index])


