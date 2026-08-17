# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Runs the benchmarks and splices their real output into `bench/README.md`.
##
## Numbers copied into a README by hand stop being measurements the moment
## anything changes. This reads what the harness actually printed.
##
## Each machine owns a block delimited by its own slug, so a second machine
## appends alongside the first instead of overwriting it, and re-running on the
## same machine replaces only its own block.

import std/[os, osproc, strutils, strformat]

const
  Anchor = "<!-- bench:insert -->"
  Readme = "bench" / "README.md"
  Binary = "build" / "bench_decode"
  TableOpen = "<!-- table -->"
  TableClose = "<!-- /table -->"

proc cpuName(): string =
  ## The processor as the system names it, or nothing when it will not say: a
  ## slug missing the model beats one that invents it.
  when defined(macosx):
    let (output, code) = execCmdEx("sysctl -n machdep.cpu.brand_string")
    if code == 0: return output.strip()
  elif defined(linux):
    if fileExists("/proc/cpuinfo"):
      for line in lines("/proc/cpuinfo"):
        if line.startsWith("model name"):
          let split = line.find(':')
          if split >= 0: return line[split + 1 .. ^1].strip()
  ""

proc slugify(text: string): string =
  var lastWasDash = true
  for character in text:
    if character.isAlphaNumeric:
      result.add character.toLowerAscii
      lastWasDash = false
    elif not lastWasDash:
      result.add '-'
      lastWasDash = true
  result.strip(chars = {'-'})

proc machineSlug(): string =
  let override = getEnv("UNIAUDIO_BENCH_MACHINE")
  if override.len > 0: return slugify(override)
  let cpu = cpuName()
  if cpu.len > 0: slugify(hostOS & "-" & cpu) else: slugify(hostOS)

proc main() =
  if not fileExists(Binary):
    quit(&"{Binary} not found: run `nimble bench` first", 1)
  let (output, code) = execCmdEx(Binary)
  if code != 0:
    quit(&"{Binary} exited {code}", 1)

  # The harness brackets its table, so the prose around it can change without
  # breaking the extraction.
  let start = output.find(TableOpen)
  let stop = output.find(TableClose)
  if start < 0 or stop < start:
    quit("the benchmark printed no table markers", 1)
  let table = output[start + TableOpen.len ..< stop].strip()

  let slug = machineSlug()
  let opening = &"<!-- bench:machine={slug} -->"
  let closing = &"<!-- /bench:machine={slug} -->"
  let section = opening & "\n\n" & table & "\n\n" & closing

  var readme = readFile(Readme)
  let existing = readme.find(opening)
  if existing >= 0:
    let tail = readme.find(closing, existing)
    if tail < 0: quit(&"{Readme}: {opening} has no closing marker", 1)
    readme = readme[0 ..< existing] & section & readme[tail + closing.len .. ^1]
    echo &"replaced the block for {slug}"
  else:
    let at = readme.find(Anchor)
    if at < 0: quit(&"{Readme}: no {Anchor} to insert at", 1)
    let after = at + Anchor.len
    readme = readme[0 ..< after] & "\n\n" & section & readme[after .. ^1]
    echo &"added a block for {slug}"
  writeFile(Readme, readme)

main()
