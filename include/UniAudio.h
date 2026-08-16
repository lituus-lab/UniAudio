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

/* Shape of a RIFF/WAVE file. Reads the whole file, because a WAV declares its
 * size in a header that cannot be trusted: the frame count reported is the one
 * the data actually holds. Frames count per channel. */
int uaud_wave_probe(const char *path, int *sample_rate, int *channels,
                    long long *frames);

#ifdef __cplusplus
}
#endif

#endif /* UNIAUDIO_H */
