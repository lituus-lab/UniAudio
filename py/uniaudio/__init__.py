# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""uniaudio — Python binding over the UniAudio C library.

Audio containers, patent-free decoders and acoustic fingerprinting::

    from uniaudio import wave_probe

    rate, channels, frames = wave_probe("take.wav")
"""
from ._core import (UniAudioError, fingerprint, probe, similarity, sniff,
                    wave_probe, version as _version_c)

__version__ = _version_c().decode("ascii")


def version():
    """C library version string."""
    return _version_c().decode("ascii")


__all__ = ["UniAudioError", "fingerprint", "probe", "similarity", "sniff",
           "wave_probe", "version", "__version__"]
