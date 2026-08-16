# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniAudio — umbrella module. Re-exports every public submodule.
##
## Audio containers, tags and decoders for formats that carry no active patent,
## plus the acoustic fingerprint built on them. Codecs under licence — AAC, and
## anything a video container brings — are deliberately absent: see the codec
## amendment in the family structure document.
import UniAudio/pcm
import UniAudio/riff
import UniAudio/aiff
import UniAudio/flac
import UniAudio/isobmff
import UniAudio/alac
import UniAudio/ogg
import UniAudio/fft
import UniAudio/fingerprint
import UniAudio/decode
export pcm, riff, aiff, flac, isobmff, alac, ogg, fft, fingerprint, decode

const UniAudioVersion* = "0.1.0"
