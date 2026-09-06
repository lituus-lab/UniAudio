# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Does not compile, on purpose. `nimble canary`, run through the gate, must
## fail; a CI step asserts it does. The day this file compiles, or the day the
## gate lets it pass, every other green result in this repo stops meaning
## anything -- which is why the proof is a test and not a comment.
import UniArchive

echo theCanaryIsSupposedToBeUndefined
