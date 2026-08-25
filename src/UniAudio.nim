# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniAudio — umbrella module. Re-exports every public submodule.
##
## Audio containers, tags and decoders, plus the acoustic fingerprint built on
## them. A file this library cannot decode is reported with the codec named.
import UniAudio/pcm
import UniAudio/riff
import UniAudio/aiff
import UniAudio/flac
import UniAudio/isobmff
import UniAudio/alac
import UniAudio/ogg
import UniAudio/vorbis
import UniAudio/mp3
import UniAudio/tags
import UniAudio/fft
import UniAudio/chroma
import UniAudio/fingerprint
import UniAudio/decode
import UniAudio/probe
export pcm, riff, aiff, flac, isobmff, alac, ogg, vorbis, mp3, tags, fft,
  chroma, fingerprint, decode, probe

const UniAudioVersion* = "0.1.0"


