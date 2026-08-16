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

/* Four bytes of frame sync so the file reads as MPEG audio, padding, then a
 * 128-byte ID3v1 tag: "TAG", 30 title, 30 artist, 30 album, 4 year,
 * 30 comment, 1 genre. */
static void write_id3v1(const char *path, const char *title,
                        const char *artist, const char *year) {
  FILE *f = fopen(path, "wb");
  assert(f != NULL);
  fputc(0xFF, f);
  fputc(0xFB, f);
  fputc(0x90, f);
  fputc(0x00, f);
  for (int i = 0; i < 60; i++) fputc(0, f);

  char tag[128];
  memset(tag, 0, sizeof tag);
  memcpy(tag, "TAG", 3);
  memcpy(tag + 3, title, strlen(title));
  memcpy(tag + 33, artist, strlen(artist));
  memcpy(tag + 93, year, 4);
  tag[127] = (char)255; /* no genre */
  fwrite(tag, 1, sizeof tag, f);
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

  /* Sniffing names the container without decoding it. */
  int container = -1;
  assert(uaud_sniff(path, &container) == UAUD_OK);
  assert(container == UAUD_WAV);
  assert(strcmp(uaud_container_name(container), "wav") == 0);
  assert(strcmp(uaud_container_name(UAUD_MP3), "mp3") == 0);
  assert(strcmp(uaud_container_name(999), "unknown") == 0);
  assert(uaud_sniff(NULL, &container) == UAUD_ERR_ARG);

  /* The generic probe agrees with the WAVE-specific one. */
  int grate = 0, gchannels = 0;
  long long gframes = 0;
  assert(uaud_probe(path, &grate, &gchannels, &gframes) == UAUD_OK);
  assert(grate == rate && gchannels == channels && gframes == frames);

  /* 400 frames of silence at 8000 Hz is far too short to fingerprint: a
   * count of zero, not an error. */
  double duration = -1.0;
  unsigned int *words = NULL;
  int count = -1;
  assert(uaud_fingerprint(path, &duration, &words, &count) == UAUD_OK);
  assert(count == 0);
  assert(words == NULL);
  assert(duration > 0.049 && duration < 0.051);
  uaud_free(words);

  /* Similarity of nothing is zero, and a fingerprint matches itself. */
  const unsigned int sample[3] = {0x0F0F0F0Fu, 0x12345678u, 0u};
  assert(uaud_similarity(NULL, 0, NULL, 0) == 0.0);
  assert(uaud_similarity(sample, 3, sample, 3) > 0.999);
  const unsigned int flipped[3] = {0xF0F0F0F0u, 0x12345678u, 0u};
  {
    const double partial = uaud_similarity(sample, 3, flipped, 3);
    /* Every bit of the first word differs, none of the other two: 32 of 96. */
    assert(partial > 0.666 && partial < 0.667);
  }

  /* Tags come back as JSON the caller frees. An ID3v1 tag is 128 fixed-width
   * bytes at the end of the file, so one can be built here without a fixture:
   * a frame sync so the file reads as MPEG audio, padding, then the tag. */
  char tagged[512];
  snprintf(tagged, sizeof tagged, "%suniaudio_capi_tags.mp3", tmp ? tmp : "/tmp/");
  write_id3v1(tagged, "probe title", "probe artist", "2001");

  char *json = NULL;
  assert(uaud_tags_json(tagged, &json) == UAUD_OK);
  assert(json != NULL);
  assert(strstr(json, "\"title\":\"probe title\"") != NULL);
  assert(strstr(json, "\"artist\":\"probe artist\"") != NULL);
  assert(strstr(json, "\"date\":\"2001\"") != NULL);
  uaud_free(json);

  /* A file with nothing to say is not a failure. */
  json = NULL;
  assert(uaud_tags_json(path, &json) == UAUD_OK);
  assert(strstr(json, "\"title\":\"\"") != NULL);
  assert(strstr(json, "\"trackNumber\":0") != NULL);
  uaud_free(json);

  assert(uaud_tags_json(NULL, &json) == UAUD_ERR_ARG);

  remove(tagged);
  remove(path);
  remove(other);
  printf("c abi: ok\n");
  return 0;
}
