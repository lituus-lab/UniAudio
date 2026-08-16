# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniAudio C ABI.

A thin wrapper, never a second implementation: what the ABI cannot reach, this
cannot reach either.
"""
cdef extern from "UniAudio.h":
    const char *uaud_version()
    const char *uaud_last_error()
    int uaud_wave_probe(const char *path, int *sample_rate, int *channels,
                        long long *frames)


class UniAudioError(RuntimeError):
    """A call into the library failed. `status` carries the uaud_status code."""

    def __init__(self, status, message):
        super().__init__(message or f"UniAudio error {status}")
        self.status = status


def version():
    return uaud_version()


def wave_probe(path):
    """Shape of a RIFF/WAVE file: (sample_rate, channels, frames)."""
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int rate = 0
    cdef int channels = 0
    cdef long long frames = 0
    cdef int status = uaud_wave_probe(encoded, &rate, &channels, &frames)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    return rate, channels, frames
