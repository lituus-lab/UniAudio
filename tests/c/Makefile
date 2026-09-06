# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Shell-free: `pwd` and `rm` are unavailable under mingw32-make on Windows.
ifeq ($(origin CC),default)
  ifeq ($(OS),Windows_NT)
    CC := gcc
  else
    CC := cc
  endif
endif

ROOT   := $(CURDIR)/../..
CFLAGS := -I$(ROOT)/include -O2 -Wall -Wextra -std=c11
LIB    := $(ROOT)/libUniAudio.a
# The codecs call round, roundf and sin. glibc keeps libm separate, so Linux
# must ask for it; macOS resolves -lm through libSystem and MinGW ships its own.
LIBS   := -lm

ifeq ($(OS),Windows_NT)
  BIN  := test_uniaudio.exe
  RUN  := $(BIN)
  RM_F := del /q
else
  BIN  := test_uniaudio
  RUN  := ./$(BIN)
  RM_F := rm -f
endif

.PHONY: all run clean
all: run
run: $(BIN)
	$(RUN)
$(BIN): test_uniaudio.c $(ROOT)/include/UniAudio.h $(LIB)
	$(CC) $(CFLAGS) -o $(BIN) test_uniaudio.c $(LIB) $(LIBS)
# File target, not phony: `nimble ctest` already built the lib, don't redo it.
$(LIB):
	cd $(ROOT) && nimble clibStatic
clean:
	$(RM_F) $(BIN)
