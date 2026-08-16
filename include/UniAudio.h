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

/* Release a buffer this library allocated. NULL is accepted. */
void uaud_free(void *buffer);

/* Fingerprint a file: one 32-bit word per frame, in time order. The words are
 * allocated by the library and released with uaud_free. A recording too short
 * to compare yields a count of zero and a NULL pointer, not an error. */
int uaud_fingerprint(const char *path, double *duration, unsigned int **words,
                     int *count);

/* How alike two fingerprints are, in [0, 1], over the length they share. Two
 * empty fingerprints are not alike: they are unknown, which reads as 0. */
double uaud_similarity(const unsigned int *a, int a_count,
                       const unsigned int *b, int b_count);

/* Shape of a RIFF/WAVE file. Reads the whole file, because a WAV declares its
 * size in a header that cannot be trusted: the frame count reported is the one
 * the data actually holds. Frames count per channel. */
int uaud_wave_probe(const char *path, int *sample_rate, int *channels,
                    long long *frames);

#ifdef __cplusplus
}
#endif

#endif /* UNIAUDIO_H */
