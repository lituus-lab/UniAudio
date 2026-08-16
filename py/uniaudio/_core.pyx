# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniAudio C ABI.

A thin wrapper, never a second implementation: what the ABI cannot reach, this
cannot reach either.
"""
from libc.stdint cimport uint32_t
from libc.stdlib cimport malloc, free

cdef extern from "UniAudio.h":
    const char *uaud_version()
    const char *uaud_last_error()
    const char *uaud_container_name(int container)
    int uaud_sniff(const char *path, int *container)
    int uaud_probe(const char *path, int *sample_rate, int *channels,
                   long long *frames)
    void uaud_free(void *buffer)
    int uaud_fingerprint(const char *path, double *duration,
                         unsigned int **words, int *count)
    double uaud_similarity(const unsigned int *a, int a_count,
                           const unsigned int *b, int b_count)
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


def sniff(path):
    """Name the container a file holds, without decoding it."""
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int container = 0
    cdef int status = uaud_sniff(encoded, &container)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    return uaud_container_name(container).decode("ascii")


def probe(path):
    """Shape of any container this build decodes: (rate, channels, frames)."""
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int rate = 0
    cdef int channels = 0
    cdef long long frames = 0
    cdef int status = uaud_probe(encoded, &rate, &channels, &frames)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    return rate, channels, frames


def fingerprint(path):
    """Fingerprint a file: (duration_seconds, words).

    A recording too short to compare yields an empty word list, not an error.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef double duration = 0.0
    cdef unsigned int *words = NULL
    cdef int count = 0
    cdef int status = uaud_fingerprint(encoded, &duration, &words, &count)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    try:
        return duration, [words[i] for i in range(count)]
    finally:
        uaud_free(words)


def similarity(a, b):
    """How alike two word lists are, in [0, 1], over the length they share."""
    cdef list left = [int(w) & 0xFFFFFFFF for w in a]
    cdef list right = [int(w) & 0xFFFFFFFF for w in b]
    if not left or not right:
        return 0.0
    cdef unsigned int *lbuf = <unsigned int *>malloc(len(left) * sizeof(unsigned int))
    cdef unsigned int *rbuf = <unsigned int *>malloc(len(right) * sizeof(unsigned int))
    if lbuf == NULL or rbuf == NULL:
        free(lbuf); free(rbuf)
        raise MemoryError()
    cdef int i
    try:
        for i in range(len(left)):
            lbuf[i] = left[i]
        for i in range(len(right)):
            rbuf[i] = right[i]
        return uaud_similarity(lbuf, len(left), rbuf, len(right))
    finally:
        free(lbuf)
        free(rbuf)
