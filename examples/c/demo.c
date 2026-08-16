// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 lituus-lab
/* Probe a WAV through the C ABI. */
#include "UniAudio.h"

#include <stdio.h>

int main(int argc, char **argv) {
  printf("UniAudio %s\n", uaud_version());
  if (argc < 2) {
    printf("usage: demo <file.wav>\n");
    return 0;
  }
  int rate = 0, channels = 0;
  long long frames = 0;
  const int status = uaud_wave_probe(argv[1], &rate, &channels, &frames);
  if (status != UAUD_OK) {
    printf("%s: %s\n", argv[1], uaud_last_error());
    return 1;
  }
  printf("%s: %d Hz, %d channel(s), %lld frames (%.3f s)\n", argv[1], rate,
         channels, frames, (double)frames / (double)rate);
  return 0;
}
