// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Links include/UniAudio.h against the static library, so a header that drifts
 * from src/UniAudio/c_api.nim fails to compile rather than at a caller's site.
 *
 * It writes a small WAV of its own and probes it, then checks that malformed
 * input is reported rather than guessed at.
 */
#include "UniAudio.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void put_u32(FILE *f, unsigned long value) {
  for (int i = 0; i < 4; i++) fputc((int)((value >> (8 * i)) & 0xFF), f);
}

static void put_u16(FILE *f, unsigned value) {
  for (int i = 0; i < 2; i++) fputc((int)((value >> (8 * i)) & 0xFF), f);
}

/* 16-bit mono PCM at 8000 Hz, `frames` samples of silence. */
static void write_wav(const char *path, int frames) {
  FILE *f = fopen(path, "wb");
  assert(f != NULL);
  const unsigned long data_bytes = (unsigned long)frames * 2u;
  fwrite("RIFF", 1, 4, f);
  put_u32(f, 36u + data_bytes);
  fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f);
  put_u32(f, 16);
  put_u16(f, 1);      /* PCM */
  put_u16(f, 1);      /* mono */
  put_u32(f, 8000);   /* sample rate */
  put_u32(f, 16000);  /* byte rate */
  put_u16(f, 2);      /* block align */
  put_u16(f, 16);     /* bits per sample */
  fwrite("data", 1, 4, f);
  put_u32(f, data_bytes);
  for (int i = 0; i < frames; i++) put_u16(f, 0);
  fclose(f);
}

int main(void) {
  assert(strcmp(uaud_version(), UNIAUDIO_VERSION) == 0);
  assert(UNIAUDIO_VERSION_AT_LEAST(0, 1, 0));

  int rate = 0, channels = 0;
  long long frames = 0;

  /* Bad arguments are reported, never dereferenced. */
  assert(uaud_wave_probe(NULL, &rate, &channels, &frames) == UAUD_ERR_ARG);
  assert(uaud_wave_probe("x.wav", NULL, &channels, &frames) == UAUD_ERR_ARG);
  assert(uaud_wave_probe("", &rate, &channels, &frames) == UAUD_ERR_ARG);
  assert(strlen(uaud_last_error()) > 0);

  const char *missing = "/nonexistent/uniaudio/never.wav";
  assert(uaud_wave_probe(missing, &rate, &channels, &frames) != UAUD_OK);

  const char *tmp = getenv("TMPDIR");
  char path[512], other[512];
  snprintf(path, sizeof path, "%suniaudio_capi.wav", tmp ? tmp : "/tmp/");
  write_wav(path, 400);

  assert(uaud_wave_probe(path, &rate, &channels, &frames) == UAUD_OK);
  assert(rate == 8000);
  assert(channels == 1);
  assert(frames == 400);
  assert(strlen(uaud_last_error()) == 0); /* success clears the reason */

  /* A file that is not a WAV is a format error, not an I/O one. */
  snprintf(other, sizeof other, "%suniaudio_capi_bad.wav", tmp ? tmp : "/tmp/");
  FILE *f = fopen(other, "wb");
  assert(f != NULL);
  fwrite("OggS and then some", 1, 18, f);
  fclose(f);
  assert(uaud_wave_probe(other, &rate, &channels, &frames) == UAUD_ERR_FORMAT);
  assert(strlen(uaud_last_error()) > 0);

  remove(path);
  remove(other);
  printf("c abi: ok\n");
  return 0;
}
