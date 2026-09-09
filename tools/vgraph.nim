# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
## Enforces the dependency directions declared in vgraph.cfg: no module
## imports a higher layer, no `requires` names an undeclared sibling package
## (ADR-0001).
## Line-based scan of import/from/include, which covers the forms Nim sources
## actually use; a macro-built import would slip past it.
import std/[os, strformat, strutils]

const Cfg = "vgraph.cfg"

proc manifest(): string =
  ## The repo's own .nimble, found rather than named: this tool is the same
  ## file in every Uni* repo, and a hard-coded name is the one line that would
  ## have to differ -- so it is the one line that would drift.
  for path in walkFiles("*.nimble"):
    return path
  ""

proc section(name: string): seq[string] =
  ## Entries under `[name]`, in file order.
  var inside = false
  for line in readFile(Cfg).splitLines:
    let entry = line.split('#')[0].strip
    if entry.len == 0: continue
    if entry.startsWith('[') and entry.endsWith(']'):
      inside = entry[1 ..< ^1] == name
    elif inside:
      result.add entry

proc layerOf(path: string, order: seq[string]): int =
  ## Index of the layer owning `path`, or -1 when unconstrained.
  let parts = path.relativePath("src").split({DirSep, AltSep})
  for i, name in order:
    for part in parts:
      if part == name or part == name & ".nim":
        return i
  -1

proc layerOfModule(modulePath: string, order: seq[string]): int =
  ## Index of the layer owning an imported module path, or -1. Matches a layer
  ## name against any path component, so `Lib/spaces/oklab` resolves to the
  ## `spaces` layer and a bare `c_api` to the `c_api` layer. A `std/`-prefixed
  ## import is Nim stdlib (external infra), never a family layer — without this
  ## guard `std/math` would collide with the `math` layer.
  if modulePath.startsWith("std/"):
    return -1
  let parts = modulePath.split({'/', '\\'})
  for i, name in order:
    for part in parts:
      if part == name or part == name & ".nim":
        return i
  -1

proc expandGrouped(body: string): string =
  ## Flatten grouped imports while keeping the path prefix on every member:
  ## `std/[os, strutils]` -> `std/os, std/strutils`. Top-level commas separate
  ## distinct imports; commas inside `[...]` separate members sharing the prefix
  ## before the bracket. Without this, `std/[math, os]` would emit bare `math`
  ## and collide with the `math` layer in `layerOfModule`.
  result = ""
  var prefix = ""
  var cur = ""
  var depth = 0
  for ch in body:
    case ch
    of '[':
      depth = 1
      prefix = cur.strip
      if prefix.len > 0 and prefix[^1] != '/':
        prefix &= '/'
      cur = ""
    of ']':
      if cur.strip.len > 0:
        result &= prefix & cur.strip & ","
      # Reset the prefix: it belongs to the group that just closed.
      prefix = ""
      depth = 0
      cur = ""
    of ',':
      if cur.strip.len > 0:
        result &= prefix & cur.strip & ","
      cur = ""
    else:
      cur &= ch
  if cur.strip.len > 0:
    result &= cur.strip & ","

iterator importedModules(path: string): string =
  ## Full slash-separated path of every module the file pulls in. Directory
  ## components are preserved so a directory layer (`spaces`) can be resolved.
  for raw in readFile(path).splitLines:
    let line = raw.split('#')[0].strip
    var body = ""
    if line.startsWith("import "): body = line[7 .. ^1]
    elif line.startsWith("include "): body = line[8 .. ^1]
    elif line.startsWith("from "): body = line[5 .. ^1].split(" import ")[0]
    else: continue
    body = expandGrouped(body)
    for item in body.split(','):
      let module = item.strip
      if module.len > 0:
        yield module

proc packageName(spec: string): string =
  ## `nim >= 2.0.0` -> nim; `https://host/user/NimContracts#branch` -> NimContracts.
  result = spec
  for sep in [" ", ">", "<", "=", "#"]:
    result = result.split(sep)[0]
  result = result.split({'/', '\\'})[^1]

func withoutComment(line: string): string =
  ## The line up to a `#` outside a string. The `#` of a quoted branch
  ## specification stays.
  var inString = false
  for at, ch in line:
    case ch
    of '"': inString = not inString
    of '#':
      if not inString: return line[0 ..< at]
    else: discard
  line

func requiredOn(line: string): seq[string] =
  ## Package names a single `requires` line declares. Nimble accepts several
  ## per directive, comma separated inside one string and as several strings
  ## on one line; reading the first alone would let the rest past the
  ## [engines] allowlist. A trailing comment is not read, while the `#` of a
  ## quoted branch specification is.
  let trimmed = line.strip
  if not trimmed.startsWith("requires"): return
  # The directive, not a name starting with it: requiresExtra is not one.
  if trimmed.len > 8 and trimmed[8] in IdentChars: return
  let body = withoutComment(trimmed)
  var index = body.find('"')
  while index >= 0:
    let stop = body.find('"', index + 1)
    if stop <= index: break
    for spec in body[index + 1 ..< stop].split(','):
      let name = packageName(spec.strip)
      if name.len > 0:
        result.add name
    index = body.find('"', stop + 1)

func requiredIn(lines: openArray[string]): seq[string] =
  ## Package names a manifest declares. A directive continued after a comma is
  ## joined before it is read, since Nim allows the argument list to span lines.
  var pending = ""
  for raw in lines:
    let body = withoutComment(raw).strip
    if pending.len > 0:
      # A comment-only line leaves nothing: appending it would drop the comma
      # the continuation is recognised by.
      if body.len == 0: continue
      pending.add " " & body
    elif body.startsWith("requires"):
      pending = body
    else:
      continue
    if pending.endsWith(","): continue
    result.add requiredOn(pending)
    pending = ""
  if pending.len > 0:
    result.add requiredOn(pending)

iterator requiredPackages(path: string): string =
  ## Package name of every requirement in the manifest.
  for name in requiredIn(readFile(path).splitLines):
    yield name

proc confinements(): seq[(string, string)] =
  ## Entries under `[confined]`, each `Package = path`: only that path may
  ## import the package or anything under it. A repo whose architecture
  ## confines a dependency to one adapter says so here, in data, so this tool
  ## stays the same file in every Uni* repo.
  for entry in section("confined"):
    let parts = entry.split('=')
    if parts.len == 2:
      result.add (parts[0].strip, parts[1].strip)

proc mayImport*(path, module: string, rules: seq[(string, string)]): bool =
  ## False when `module` is a confined package and `path` is not its keeper.
  ## Separators are normalised first: vgraph.cfg names the keeper with forward
  ## slashes, walkDirRec yields backslashes on Windows, and comparing the two
  ## raw accused the keeper itself of the import it is there to hold.
  let here = path.replace('\\', '/')
  for rule in rules:
    if module == rule[0] or module.startsWith(rule[0] & "/"):
      if here != rule[1].replace('\\', '/'):
        return false
  true

proc checkParser() =
  ## Check the parsers against known inputs before judging any repository.
  ## They travel with the tool rather than a test file each manifest would
  ## wire in.
  const cases = {
    "std/[os, strutils]": "std/os,std/strutils,",
    "std/[os], a, b": "std/os,a,b,",
    "std/[os, strutils], c_api/private, other":
    "std/os,std/strutils,c_api/private,other,",
    "std/[os], x/[y, z], w": "std/os,x/y,x/z,w,",
    "a, b, c": "a,b,c,",
  }
  for (input, want) in cases:
    let got = expandGrouped(input)
    if got != want:
      quit(&"vgraph: parser regression on `{input}`: got `{got}`, want `{want}`", 1)

  # Several requirements per directive, which nimble accepts and the allowlist
  # must see.
  const requireCases = {
    """requires "nim >= 2.0.0"""": @["nim"],
    """requires "nim >= 2.0.0, UniUndeclared"""": @["nim", "UniUndeclared"],
    """requires "a", "b"""": @["a", "b"],
    """requires "UniVector" # "UniPlot"""": @["UniVector"],
    """requiresExtra "UniVector"""": newSeq[string](),
    """requires "https://github.com/lbartoletti/NimContracts#main"""":
    @["NimContracts"],
  }
  for (line, want) in requireCases:
    let got = requiredOn(line)
    if got != want:
      quit(&"vgraph: requires regression on `{line}`: got `{got}`, want `{want}`", 1)

  # A directive whose argument list spans lines, which Nim allows after a comma.
  const manifestCases = [
    (@["requires \"a\",", "         \"UniUndeclared\""],
     @["a", "UniUndeclared"]),
    (@["requires \"a\", # note", "         \"b\""], @["a", "b"]),
    (@["requires \"a\",", "  # a note on its own line", "  \"UniUndeclared\""],
     @["a", "UniUndeclared"]),
    (@["requires \"a\"", "requires \"b\""], @["a", "b"]),
  ]
  for (lines, want) in manifestCases:
    let got = requiredIn(lines)
    if got != want:
      quit(&"vgraph: manifest regression on `{lines}`: got `{got}`, want `{want}`", 1)

proc main() =
  checkParser()
  if not fileExists(Cfg):
    quit(&"vgraph: {Cfg} not found", 1)
  let order = section("layers")
  let confined = confinements()

  var violations: seq[string]

  var checked = 0
  for path in walkDirRec("src"):
    if not path.endsWith(".nim"): continue
    let own = layerOf(path, order)
    if own >= 0:
      inc checked
    # Confinement applies to every module under src, layered or not; only the
    # layer-order comparison needs a layer.
    for module in importedModules(path):
      if not mayImport(path, module, confined):
        violations.add &"{path}: imports {module}, confined elsewhere"
      if own >= 0:
        let other = layerOfModule(module, order)
        if other > own:
          violations.add &"{path}: imports {module} ({order[other]}) from {order[own]}"

  # Only packages listed under [engines] may appear in `requires` (ADR-0001).
  let allowed = section("engines")
  var engines = 0
  let Nimble = manifest()
  if Nimble.len > 0 and fileExists(Nimble):
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

when isMainModule:
  main()
