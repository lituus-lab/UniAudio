# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniAudio C ABI.

A thin wrapper, never a second implementation: what the ABI cannot reach, this
cannot reach either.
"""
import array as _array
import json as _json

from libc.stdint cimport uint32_t
from libc.string cimport memcpy
from libc.stdlib cimport malloc, free

cdef extern from "UniAudio.h":
    const char *uaud_version()
    const char *uaud_last_error()
    const char *uaud_container_name(int container)
    int uaud_sniff(const char *path, int *container)
    int uaud_probe(const char *path, int *sample_rate, int *channels,
                   long long *frames)
    void uaud_free(void *buffer)
    int uaud_decode(const char *path, int *sample_rate, int *channels,
                    long long *frames, float **samples)
    int uaud_decode_resampled(const char *path, int target_rate, int to_mono,
                              int *sample_rate, int *channels,
                              long long *frames, float **samples)
    int uaud_write_wave(const char *path, const float *samples,
                        int sample_rate, int channels, long long frames,
                        int bits_per_sample)
    int uaud_write_flac(const char *path, const float *samples,
                        int sample_rate, int channels, long long frames,
                        int bits_per_sample)
    double uaud_offset_similarity(const unsigned int *a, int a_count,
                                  const unsigned int *b, int b_count,
                                  int max_shift)
    int uaud_tags_json(const char *path, char **json)
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


cdef object _take_samples(float *samples, int channels, long long frames):
    """Copy the library's block into one array, then release it.

    One bulk copy, not a Python object per sample: a three-minute stereo track
    is sixteen million of them.
    """
    cdef Py_ssize_t count = <Py_ssize_t> frames * channels
    out = _array.array("f")
    if count > 0 and samples != NULL:
        out.frombytes((<char *> samples)[:count * sizeof(float)])
    if samples != NULL:
        uaud_free(samples)
    return out


def decode(path):
    """Decode a file: (sample_rate, channels, frames, samples).

    `samples` is an `array.array('f')` of interleaved values in [-1, 1], and
    `frames` counts per channel — so it holds `frames * channels` of them.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int rate = 0
    cdef int channels = 0
    cdef long long frames = 0
    cdef float *samples = NULL
    cdef int status = uaud_decode(encoded, &rate, &channels, &frames, &samples)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    return rate, channels, frames, _take_samples(samples, channels, frames)


def decode_resampled(path, target_rate=0, to_mono=False):
    """Decode, then average the channels and change the rate.

    `target_rate` of 0 leaves the rate alone. The resampling is linear, which
    suits analysis and does not suit listening.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int rate = 0
    cdef int channels = 0
    cdef long long frames = 0
    cdef float *samples = NULL
    cdef int status = uaud_decode_resampled(
        encoded, <int> target_rate, 1 if to_mono else 0,
        &rate, &channels, &frames, &samples)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    return rate, channels, frames, _take_samples(samples, channels, frames)


def write_wave(path, samples, sample_rate, channels, bits_per_sample=16):
    """Write interleaved floats as a WAV: the only format this library writes.

    `bits_per_sample` is 16 or 24. Anything supporting the buffer protocol as
    contiguous float32 is read directly; any other iterable is copied through
    an array first.
    """
    cdef const float[::1] view
    try:
        view = samples
    except (TypeError, ValueError, BufferError):
        view = _array.array("f", samples)
    cdef Py_ssize_t count = view.shape[0]
    if channels <= 0:
        raise ValueError("channels must be positive")
    if count % channels:
        raise ValueError("sample count is not a whole number of frames")
    if count == 0:
        raise ValueError("nothing to write")
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int status = uaud_write_wave(encoded, &view[0], sample_rate, channels,
                                     count // channels, bits_per_sample)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))


def write_flac(path, samples, sample_rate, channels, bits_per_sample=16):
    """Encode interleaved floats to a native FLAC file, losslessly.

    `bits_per_sample` is 8, 16 or 24. Fixed predictors, so the file is larger
    than the reference encoder's default and decodes to exactly the same
    samples.
    """
    cdef const float[::1] view
    try:
        view = samples
    except (TypeError, ValueError, BufferError):
        view = _array.array("f", samples)
    cdef Py_ssize_t count = view.shape[0]
    if channels <= 0:
        raise ValueError("channels must be positive")
    if count % channels:
        raise ValueError("sample count is not a whole number of frames")
    if count == 0:
        raise ValueError("nothing to write")
    cdef bytes encoded = str(path).encode("utf-8")
    cdef int status = uaud_write_flac(encoded, &view[0], sample_rate, channels,
                                     count // channels, bits_per_sample)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))


def offset_similarity(a, b, max_shift=64):
    """The best similarity over a bounded time shift.

    Two copies of a recording that start at different points still match; a
    plain comparison would miss it.
    """
    cdef Py_ssize_t a_count = len(a)
    cdef Py_ssize_t b_count = len(b)
    if a_count == 0 or b_count == 0:
        return 0.0
    cdef uint32_t *a_buf = <uint32_t *> malloc(a_count * sizeof(uint32_t))
    cdef uint32_t *b_buf = <uint32_t *> malloc(b_count * sizeof(uint32_t))
    if a_buf == NULL or b_buf == NULL:
        free(a_buf)
        free(b_buf)
        raise MemoryError()
    cdef Py_ssize_t index
    try:
        for index in range(a_count):
            a_buf[index] = <uint32_t> a[index]
        for index in range(b_count):
            b_buf[index] = <uint32_t> b[index]
        return uaud_offset_similarity(a_buf, <int> a_count, b_buf,
                                      <int> b_count, <int> max_shift)
    finally:
        free(a_buf)
        free(b_buf)


def tags(path):
    """What the file says about itself, as a dict.

    `date` is whatever the file wrote and is not parsed: tag dates follow no
    agreed format. Names with no field of their own are under `other`.
    """
    cdef bytes encoded = str(path).encode("utf-8")
    cdef char *out = NULL
    cdef int status = uaud_tags_json(encoded, &out)
    if status != 0:
        raise UniAudioError(status,
                            uaud_last_error().decode("utf-8", "replace"))
    try:
        return _json.loads((<bytes> out).decode("utf-8"))
    finally:
        uaud_free(out)


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
