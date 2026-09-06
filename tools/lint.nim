# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Fails if nimpretty would reformat any source. Checks, never rewrites.
import std/[os, osproc, strformat, strutils]

# Every directory any Uni* repo keeps Nim in. Absent ones are skipped by
# `dirExists` below, so the list is the same file everywhere -- it used to
# be the one line that differed, and three repos were quietly not checking
# their bin/, bench/ or tools/ sources at all.
const Roots = ["src", "tests", "examples", "book", "tools", "bin", "bench",
               "benchmarks"]

proc sources(): seq[string] =
  for root in Roots:
    if dirExists(root):
      for path in walkDirRec(root):
        if path.endsWith(".nim"):
          result.add path

proc main() =
  let tmp = "build" / "lint"
  removeDir tmp

  let files = sources()
  var dirty: seq[string]
  for src in files:
    let formatted = tmp / src
    createDir formatted.parentDir
    if execCmd(&"nimpretty --out:{formatted.quoteShell} {src.quoteShell}") != 0:
      quit(&"lint: nimpretty failed on {src}", 1)
    if readFile(src) != readFile(formatted):
      dirty.add src

  if dirty.len > 0:
    echo "lint: nimpretty would reformat:"
    for src in dirty:
      echo "  ", src
    quit("lint: run nimpretty on the files above", 1)
  echo &"lint: {files.len} files clean"

main()
