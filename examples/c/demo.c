// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Name a file, decode it, and read what it says about itself — through the C
 * ABI only, with no knowledge of which format was handed over. */
#include "UniAudio.h"

#include <stdio.h>

int main(int argc, char **argv) {
  printf("UniAudio %s\n", uaud_version());
  if (argc < 2) {
    printf("usage: demo <audio file>\n");
    return 0;
  }
  const char *path = argv[1];

  int container = 0;
  if (uaud_sniff(path, &container) != UAUD_OK) {
    printf("%s: %s\n", path, uaud_last_error());
    return 1;
  }
  printf("%s: %s\n", path, uaud_container_name(container));

  int rate = 0, channels = 0;
  long long frames = 0;
  float *samples = NULL;
  if (uaud_decode(path, &rate, &channels, &frames, &samples) != UAUD_OK) {
    /* A container this build reads holding a codec it does not decode says
     * which codec it found, rather than failing as though the file were
     * broken. */
    printf("  cannot decode: %s\n", uaud_last_error());
    return 1;
  }

  /* The loudest sample: the cheapest thing to report that proves the samples
   * really arrived rather than just their shape. */
  float peak = 0.0f;
  for (long long i = 0; i < frames * channels; i++) {
    const float value = samples[i] < 0.0f ? -samples[i] : samples[i];
    if (value > peak) peak = value;
  }
  uaud_free(samples);

  printf("  %d Hz, %d channel(s), %lld frames (%.3f s), peak %.4f\n", rate,
         channels, frames, (double)frames / (double)rate, (double)peak);

  char *tags = NULL;
  if (uaud_tags_json(path, &tags) == UAUD_OK) {
    printf("  tags: %s\n", tags);
    uaud_free(tags);
  }
  return 0;
}
