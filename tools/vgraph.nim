# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Enforces the dependency directions declared in vgraph.cfg (ADR-0001):
## no module imports a higher layer, no `requires` names an undeclared engine.
## Line-based scan of import/from/include, which covers the forms Nim sources
## actually use; a macro-built import would slip past it.
import std/[os, strformat, strutils, tables]
import contracts

const
  Cfg = "vgraph.cfg"
  Nimble = "UniAudio.nimble"

proc section(name: string): seq[string] {.contractual.} =
  ## Entries under `[name]`, in file order.
  require:
    name.len > 0
  body:
    var inside = false
    for line in readFile(Cfg).splitLines:
      let entry = line.split('#')[0].strip
      if entry.len == 0: continue
      if entry.startsWith('[') and entry.endsWith(']'):
        inside = entry[1 ..< ^1] == name
      elif inside:
        result.add entry

proc layerOf(path: string, order: seq[string]): int {.contractual.} =
  ## Index of the layer owning `path`, or -1 when unconstrained.
  ensure:
    result >= -1 and result < order.len
  body:
    let parts = path.relativePath("src").split({DirSep, AltSep})
    for i, name in order:
      for part in parts:
        if part == name or part == name & ".nim":
          return i
    -1

iterator importedModules(path: string): string {.contractual.} =
  ## Last path component of every module the file pulls in.
  require:
    path.len > 0
  body:
    for raw in readFile(path).splitLines:
      let line = raw.split('#')[0].strip
      var body = ""
      if line.startsWith("import "): body = line[7 .. ^1]
      elif line.startsWith("include "): body = line[8 .. ^1]
      elif line.startsWith("from "): body = line[5 .. ^1].split(" import ")[0]
      else: continue
      # `std/[os, strutils]` -> the bracket members carry the meaningful names.
      body = body.multiReplace(("[", ","), ("]", ","))
      for item in body.split(','):
        let module = item.strip.split({'/', '\\'})[^1].strip
        if module.len > 0:
          yield module

proc packageName(spec: string): string {.contractual.} =
  ## `nim >= 2.0.0` -> nim; `https://host/user/NimContracts#branch` -> NimContracts.
  ensure:
    not result.contains('/')
  body:
    result = spec
    for sep in [" ", ">", "<", "=", "#"]:
      result = result.split(sep)[0]
    result = result.split({'/', '\\'})[^1]

iterator requiredPackages(path: string): string {.contractual.} =
  ## Package name of every `requires` line.
  require:
    path.len > 0
  body:
    for raw in readFile(path).splitLines:
      let line = raw.strip
      if not line.startsWith("requires"): continue
      let a = line.find('"')
      let b = line.find('"', a + 1)
      if a >= 0 and b > a:
        let name = packageName(line[a + 1 ..< b])
        if name.len > 0:
          yield name

proc main() =
  if not fileExists(Cfg):
    quit(&"vgraph: {Cfg} not found", 1)
  let order = section("layers")
  var index = initTable[string, int]()
  for i, name in order:
    index[name] = i

  var violations: seq[string]

  var checked = 0
  for path in walkDirRec("src"):
    if not path.endsWith(".nim"): continue
    let own = layerOf(path, order)
    if own < 0: continue
    inc checked
    for module in importedModules(path):
      let other = index.getOrDefault(module, -1)
      if other > own:
        violations.add &"{path}: imports {module} ({order[other]}) from {order[own]}"

  # Family DAG: only engines listed under [engines] may appear in `requires`.
  let allowed = section("engines")
  var engines = 0
  if fileExists(Nimble):
    for package in requiredPackages(Nimble):
      if not package.startsWith("Uni"): continue
      inc engines
      if package notin allowed:
        violations.add &"{Nimble}: requires {package}, absent from [engines]"

  if violations.len > 0:
    echo "vgraph: violations found:"
    for v in violations:
      echo "  ", v
    quit(1)
  echo &"vgraph: {checked} modules respect {order.join(\" < \")}; " &
       &"{engines} engine deps declared"

main()
