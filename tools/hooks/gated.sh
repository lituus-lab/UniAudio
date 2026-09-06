#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Runs a nimble task through the failure gate, building the gate if it is not
# there yet. pre-commit calls this rather than `nimble <task>`: nimble exits 0
# on a task whose `exec` failed, so a hook calling it bare blocks nothing.
set -eu

cd "$(git rev-parse --show-toplevel)"

gate=build/unigate
[ "${OS:-}" = Windows_NT ] && gate=build/unigate.exe
# `build/` is ignored, so an executable from an older checkout can outlive the
# source it was built from and answer for it. Rebuild whenever the source is
# newer, not merely when the binary is missing.
if [ ! -x "$gate" ] || [ tools/gate.nim -nt "$gate" ]; then
  nim c --hints:off -o:"$gate" tools/gate.nim >/dev/null
fi

exec "$gate" "$@"
