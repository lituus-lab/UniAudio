// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
#ifndef UNIAUDIO_H
#define UNIAUDIO_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UNIAUDIO_VERSION_MAJOR 0
#define UNIAUDIO_VERSION_MINOR 1
#define UNIAUDIO_VERSION_PATCH 0
#define UNIAUDIO_VERSION "0.1.0"

#define UNIAUDIO_VERSION_AT_LEAST(ma, mi, pa) \
  ((UNIAUDIO_VERSION_MAJOR > (ma)) || \
   (UNIAUDIO_VERSION_MAJOR == (ma) && UNIAUDIO_VERSION_MINOR > (mi)) || \
   (UNIAUDIO_VERSION_MAJOR == (ma) && UNIAUDIO_VERSION_MINOR == (mi) && \
    UNIAUDIO_VERSION_PATCH >= (pa)))

typedef enum {
  UAUD_OK = 0,
  UAUD_ERR_ARG = 1,    /* a null pointer or an empty path */
  UAUD_ERR_IO = 2,     /* the file could not be opened or read */
  UAUD_ERR_FORMAT = 3  /* not a container this build understands */
} uaud_status;

/* Static version string; do not free. */
const char *uaud_version(void);

/* Most recent failure on this thread, "" when there is none. Owned by the
 * library; valid until the next failing call on the same thread. */
const char *uaud_last_error(void);

/* Container codes, matching uaud_container_name's output. */
typedef enum {
  UAUD_UNKNOWN = 0,
  UAUD_WAV = 1,
  UAUD_AIFF = 2,
  UAUD_FLAC = 3,
  UAUD_OGG = 4,
  UAUD_MP3 = 5,
  UAUD_MP4 = 6
} uaud_container;

/* Name of a container code. Static; do not free. */
const char *uaud_container_name(int container);

/* Identify a file from its leading bytes, without decoding it. */
int uaud_sniff(const char *path, int *container);

/* Shape of any container this build decodes. One it recognises but does not
 * decode is named in uaud_last_error rather than silently skipped. */
int uaud_probe(const char *path, int *sample_rate, int *channels,
               long long *frames);

/* Decode a file to interleaved floats in [-1, 1]. frames counts per channel,
 * so the block holds frames * channels values. It is allocated by the library
 * and released with uaud_free; a file that decoded to nothing yields a count
 * of zero and a NULL pointer, not an error. */
int uaud_decode(const char *path, int *sample_rate, int *channels,
                long long *frames, float **samples);

/* Decode, then optionally average the channels and change the rate. A
 * target_rate of 0 leaves the rate alone; to_mono is a flag.
 *
 * The resampling is linear, which suits analysis and does not suit listening;
 * a resampler meant for listening would be a different call. */
int uaud_decode_resampled(const char *path, int target_rate, int to_mono,
                          int *sample_rate, int *channels, long long *frames,
                          float **samples);

/* Write interleaved floats as a RIFF/WAVE file. bits_per_sample is 16 or 24;
 * samples outside [-1, 1] are clamped rather than left to wrap. */
int uaud_write_wave(const char *path, const float *samples, int sample_rate,
                    int channels, long long frames, int bits_per_sample);

/* Encode interleaved floats to a native FLAC file, losslessly.
 * bits_per_sample is 8, 16 or 24, and up to 8 channels are accepted.
 *
 * Fixed predictors, so the file is larger than the reference encoder's default
 * and decodes to exactly the same samples. */
int uaud_write_flac(const char *path, const float *samples, int sample_rate,
                    int channels, long long frames, int bits_per_sample);

/* Encode interleaved floats to an .m4a holding one ALAC track, losslessly.
 * bits_per_sample is 16 or 24; mono and stereo only. */
int uaud_write_alac(const char *path, const float *samples, int sample_rate,
                    int channels, long long frames, int bits_per_sample);

/* Release a buffer this library allocated. NULL is accepted.
 *
 * Every entry point that allocates through an output pointer — uaud_decode,
 * uaud_decode_resampled, uaud_tags_json, uaud_fingerprint and
 * uaud_chroma_fingerprint — clears that pointer to NULL, and its count to
 * zero, before doing anything that can fail. A caller may therefore free
 * unconditionally: on any status but UAUD_OK there is nothing to free and the
 * pointer says so. A NULL output pointer is refused with UAUD_ERR_ARG, never
 * written through.
 *
 * The remaining outputs — a sample rate, a channel count — are written on
 * success only, and left untouched otherwise. */
void uaud_free(void *buffer);

/* What the file says about itself, as a UTF-8 JSON object: title, artist,
 * album, albumArtist, composer, genre, comment and date as strings,
 * trackNumber, trackTotal, discNumber and discTotal as numbers, and other as
 * an array of {key, value} for names with no field of their own. The string is
 * allocated by the library and released with uaud_free.
 *
 * A file carrying no tags yields empty fields, not an error. date is whatever
 * the file wrote, unparsed: tag dates follow no agreed format. */
int uaud_tags_json(const char *path, char **json);

/* Fingerprint a file: one 32-bit word per frame, in time order. The words are
 * allocated by the library and released with uaud_free. A recording too short
 * to compare yields a count of zero and a NULL pointer, not an error. */
int uaud_fingerprint(const char *path, double *duration, unsigned int **words,
                     int *count);

/* How alike two fingerprints are, in [0, 1], over the length they share. Two
 * empty fingerprints are not alike: they are unknown, which reads as 0. */
double uaud_similarity(const unsigned int *a, int a_count,
                       const unsigned int *b, int b_count);

/* Fingerprint a file the way a lossy re-encode survives. uaud_fingerprint is
 * exact through a lossless re-encode and drifts to roughly 0.7 through a lossy
 * one; this holds above 0.98, at the cost of needing about three seconds of
 * recording before it yields a word. The words are bit-for-bit the ones
 * Chromaprint produces, so one taken here compares directly with one from
 * fpcalc; submitting to AcoustID would need Chromaprint's compressed
 * encoding of them, which this library does not produce.
 * Allocated by the library and released with uaud_free. */
int uaud_chroma_fingerprint(const char *path, double *duration,
                            unsigned int **words, int *count);

/* How alike two chroma fingerprints are, in [0, 1]. */
double uaud_chroma_similarity(const unsigned int *a, int a_count,
                              const unsigned int *b, int b_count);

/* The best similarity over a bounded time shift, for two copies of a recording
 * that start at different points. */
double uaud_offset_similarity(const unsigned int *a, int a_count,
                              const unsigned int *b, int b_count,
                              int max_shift);

/* Shape of a RIFF/WAVE file. Reads the whole file, because a WAV declares its
 * size in a header that cannot be trusted: the frame count reported is the one
 * the data actually holds. Frames count per channel. */
int uaud_wave_probe(const char *path, int *sample_rate, int *channels,
                    long long *frames);

/* Start a RIFF/WAVE file whose length is not known yet, 16 or 24 bits. The
 * batch writer above needs every sample at once; this one takes them as they
 * arrive. On success *writer holds a handle, released by
 * uaud_wave_writer_close — which is also what patches the sizes the header
 * declares, so a file abandoned without it does not read back as a WAV. */
int uaud_wave_writer_open(const char *path, int sample_rate, int channels,
                          int bits_per_sample, void **writer);

/* Append count interleaved values: whole frames only, channels values each.
 * A partial frame is refused rather than padded. */
int uaud_wave_writer_write(void *writer, const float *samples,
                           long long count);

/* Frames written so far, per channel. */
int uaud_wave_writer_frames(void *writer, long long *frames);

/* Patch the sizes, close the file and release the handle. The handle is spent:
 * passing it again is undefined, as with a pointer already freed. */
int uaud_wave_writer_close(void *writer);

#ifdef __cplusplus
}
#endif

#endif /* UNIAUDIO_H */
