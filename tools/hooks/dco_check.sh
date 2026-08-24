#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# Local mirror of the CI dco job: a commit must carry a Signed-off-by trailer.
# pre-commit passes the commit-msg file path as $1.
set -eu
if [ "$#" -lt 1 ]; then
  echo "usage: dco_check.sh <commit-msg-file>" >&2
  exit 2
fi
msg_file="$1"
if [ ! -r "$msg_file" ]; then
  echo "cannot read commit message file: $msg_file" >&2
  exit 2
fi
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  exit 0
fi
if ! trailers=$(git interpret-trailers --parse <"$msg_file"); then
  echo "cannot parse commit message trailers: $msg_file" >&2
  exit 2
fi
if ! printf '%s\n' "$trailers" | grep -qE '^Signed-off-by: .+ <.+@.+>$'; then
  echo "Missing Signed-off-by trailer in the commit message." >&2
  echo "Re-run with:  git commit -s   (or  git commit -s --amend)" >&2
  exit 1
fi
