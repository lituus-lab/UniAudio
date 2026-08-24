# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Three checks over the sources, and it rewrites nothing:
##
## 1. nimpretty would reformat the file.
## 2. a module under `src/` ends too close to its last statement, which breaks
##    `nimble coverage`.
## 3. a module under `src/` imports `std/math` instead of taking its maths from
##    UniMath.
import std/[os, osproc, strformat, strutils, sequtils]
import contracts

const Roots = ["src", "tests", "examples", "book"]

proc sources(): seq[string] {.contractual.} =
  ensure:
    result.allIt(it.endsWith(".nim"))
  body:
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

  # Nim attributes a trailing statement past the end of the file, and a
  # contractual proc at the end pushes it one line further still. `genhtml`
  # refuses coverage data pointing past a file's last line, so `nimble
  # coverage` fails on a source that stops too soon. Two blank lines clear
  # both cases; nimpretty leaves them alone.
  var short: seq[string]
  for src in files:
    if src.startsWith("src" & DirSep) and not readFile(src).endsWith("\n\n\n"):
      short.add src
  if short.len > 0:
    echo "lint: these must end with two blank lines, or coverage breaks:"
    for src in short:
      echo "  ", src
    quit("lint: append a blank line to the files above", 1)

  # The family takes its maths from UniMath, so a module under src/ importing
  # std/math bypasses the one numeric layer the dependency graph declares.
  # `UniMath/native_float` re-exports std/math, so the fix is the import line
  # and nothing else.
  var bypass: seq[string]
  for src in files:
    if not src.startsWith("src" & DirSep): continue
    for line in readFile(src).splitLines():
      let text = line.strip()
      if not text.startsWith("import "): continue
      if text.contains("std/math") or
          (text.contains("std/[") and "math" in text[text.find('[') + 1 ..<
           text.find(']')].split(',').mapIt(it.strip())):
        bypass.add &"{src}: {text}"
        break
  if bypass.len > 0:
    echo "lint: take maths from UniMath, not std/math directly:"
    for entry in bypass:
      echo "  ", entry
    quit("lint: import UniMath/native_float in the files above", 1)

  echo &"lint: {files.len} files clean"

main()
