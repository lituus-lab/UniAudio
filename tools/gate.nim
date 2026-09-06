# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Runs a nimble task and fails when it did not run to its end.
##
## Nimble 0.22 exits 0 even when an `exec` inside a task failed: the exception
## is printed, the task stops, and the process still reports success. Measured,
## not assumed — and neither `try`/`except` nor `quit(1)` inside the task
## changes it, so no fix written in the manifest can work. The task's own
## success marker is therefore the only evidence it reached its last line, and
## this tool is what turns the absence of that marker into a non-zero exit.
# std only: the gate is built before `nimble install` has resolved anything,
# so it cannot import a dependency -- not even the family's NimContracts.
import std/[os, osproc, strformat]

const MarkerDir* = "build" / ".gate"
  ## Where a task drops the file proving it ran to its end.

func markerOf*(task: string): string =
  ## The marker a task writes. Kept here so the manifest and this tool cannot
  ## come to disagree about the path.
  MarkerDir / task & ".ok"

proc main() =
  if paramCount() < 1:
    quit("gate: usage: gate <task> [args...]", 2)
  let task = paramStr(1)
  let marker = markerOf(task)
  # Removed before the run, so a marker left by an earlier run cannot pass
  # for this one.
  removeFile marker
  createDir MarkerDir

  var args = @[task]
  for index in 2 .. paramCount():
    args.add paramStr(index)
  # poParentStreams: the task's output reaches the terminal as it happens.
  # Capturing it would buy nothing — the marker is a file, not a line to grep.
  let process = startProcess("nimble", args = args,
                             options = {poParentStreams, poUsePath})
  let code = process.waitForExit()
  process.close()

  if not fileExists(marker):
    quit(&"gate: `nimble {task}` did not reach its end (nimble exited {code})", 1)
  removeFile marker
  if code != 0:
    quit(&"gate: `nimble {task}` exited {code}", 1)

main()
