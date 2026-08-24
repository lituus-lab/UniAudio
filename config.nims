# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## UniAudio build config.
##
## No compiler flags of its own. The decoders are integer and float32 work with
## no architecture-specific paths, and a flag added without a measurement to
## justify it would be worse than none. What follows is nimble's own block,
## which includes the generated `nimble.paths` when one is present.
# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

# The ALAC writer muxes through UniMovie, which reaches UniImage for the box
# writer they share. UniMovie is not published, so it is found beside this repo
# in the lituus-lab checkout; UniImage follows the same route because nimble
# never reads UniMovie's own requires when UniMovie arrives by path. A clone
# on its own cannot build the ALAC writer until UniMovie is published.
switch("path", "../UniMovie/src")
switch("path", "../UniImage/src")
