# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
# UniAudio — audio containers, patent-free decoders and the acoustic
# fingerprint, for the lituus-lab Uni* family.

version       = "0.1.0"
author        = "lituus-lab"
description   = "Audio containers, tags, patent-free decoders and acoustic fingerprinting"
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"
requires "https://github.com/lbartoletti/NimContracts#main"
# Native float mathematics: one dependency surface for the whole family.
requires "https://github.com/lituus-lab/UniMath#main"
# Container framing: the ALAC writer puts its stream in an MP4, which is a
# job the family does in one place rather than in each library that needs it.
requires "https://github.com/lituus-lab/UniContainer#main"

# nimble 0.22 exits 0 even when an `exec` inside a task fails, so a task's exit
# code says nothing about whether its body ran. Each task writes a marker as
# its last statement; `tools/gate.nim` removes the marker, runs the task, and
# fails if it is not there afterwards. `nimble canary` proves nothing on its
# own -- `build/unigate canary` is the call that does, and if it ever passes,
# every other green result is worthless.
const gateExe =
  when defined(windows): "build/unigate.exe" else: "build/unigate"

template done(task: string) =
  mkDir "build/.gate"
  writeFile("build/.gate/" & task & ".ok", "")

proc gate(task: string): string =
  ## `exec gate("test")` -- builds the tool only when it is missing, and that is
  ## deliberate. Every call here happens inside a task the gate binary is
  ## already running, and Windows locks a running executable against being
  ## overwritten. Freshness is enforced where the gate is invoked instead: CI
  ## compiles it at the start of every job, and tools/hooks/gated.sh rebuilds
  ## it when the source is newer.
  if not fileExists(gateExe):
    exec "nim c --hints:off -o:" & gateExe & " tools/gate.nim"
  gateExe & " " & task

task canary, "Must fail: proves the gate still catches a broken build":
  # No `done` here on purpose: the exec below raises, so the marker is never
  # written and the gate reports the failure nimble swallowed.
  exec "nim c -r --hints:off --path:src -o:build/canary tests/canary_broken.nim"


task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"
  done "lint"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"
  done "checkVGraph"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"
  done "docsDeps"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"
  done "book"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniAudio.nim"
  exec gate("book")
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"
  done "docs"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_bitio tests/test_bitio.nim"
  exec "nim c -r --path:src -o:build/test_pcm tests/test_pcm.nim"
  exec "nim c -r --path:src -o:build/test_wave_writer tests/test_wave_writer.nim"
  exec "nim c -r --path:src -o:build/test_aiff tests/test_aiff.nim"
  exec "nim c -r --path:src -o:build/test_flac tests/test_flac.nim"
  exec "nim c -r --path:src -o:build/test_alac tests/test_alac.nim"
  exec "nim c -r --path:src -o:build/test_ogg tests/test_ogg.nim"
  exec "nim c -r --path:src -o:build/test_vorbis tests/test_vorbis.nim"
  exec "nim c -r --path:src -o:build/test_mp3 tests/test_mp3.nim"
  exec "nim c -r --path:src -o:build/test_tags tests/test_tags.nim"
  exec "nim c -r --path:src -o:build/test_robustness tests/test_robustness.nim"
  exec "nim c -r --path:src -o:build/test_fingerprint tests/test_fingerprint.nim"
  exec "nim c -r --path:src -o:build/test_chroma tests/test_chroma.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  done "test"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_bitio_rel tests/test_bitio.nim"
  exec "nim c -r -d:release --path:src -o:build/test_pcm_rel tests/test_pcm.nim"
  exec "nim c -r -d:release --path:src -o:build/test_wave_writer_rel tests/test_wave_writer.nim"
  exec "nim c -r -d:release --path:src -o:build/test_aiff_rel tests/test_aiff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_flac_rel tests/test_flac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_alac_rel tests/test_alac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_ogg_rel tests/test_ogg.nim"
  exec "nim c -r -d:release --path:src -o:build/test_vorbis_rel tests/test_vorbis.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mp3_rel tests/test_mp3.nim"
  exec "nim c -r -d:release --path:src -o:build/test_tags_rel tests/test_tags.nim"
  exec "nim c -r -d:release --path:src -o:build/test_robustness_rel tests/test_robustness.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fingerprint_rel tests/test_fingerprint.nim"
  exec "nim c -r -d:release --path:src -o:build/test_chroma_rel tests/test_chroma.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  done "testRelease"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_pcm tests/test_pcm.nim"
  exec "nim c -r --path:src -o:build/test_aiff tests/test_aiff.nim"
  exec "nim c -r --path:src -o:build/test_flac tests/test_flac.nim"
  exec "nim c -r --path:src -o:build/test_alac tests/test_alac.nim"
  exec "nim c -r --path:src -o:build/test_ogg tests/test_ogg.nim"
  exec "nim c -r --path:src -o:build/test_vorbis tests/test_vorbis.nim"
  exec "nim c -r --path:src -o:build/test_mp3 tests/test_mp3.nim"
  exec "nim c -r --path:src -o:build/test_tags tests/test_tags.nim"
  exec "nim c -r --path:src -o:build/test_robustness tests/test_robustness.nim"
  exec "nim c -r --path:src -o:build/test_fingerprint tests/test_fingerprint.nim"
  exec "nim c -r --path:src -o:build/test_chroma tests/test_chroma.nim"
  exec "nim c -r --path:src -o:build/test_probe tests/test_probe.nim"
  done "testCi"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_pcm_rel tests/test_pcm.nim"
  exec "nim c -r -d:release --path:src -o:build/test_aiff_rel tests/test_aiff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_flac_rel tests/test_flac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_alac_rel tests/test_alac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_ogg_rel tests/test_ogg.nim"
  exec "nim c -r -d:release --path:src -o:build/test_vorbis_rel tests/test_vorbis.nim"
  exec "nim c -r -d:release --path:src -o:build/test_mp3_rel tests/test_mp3.nim"
  exec "nim c -r -d:release --path:src -o:build/test_tags_rel tests/test_tags.nim"
  exec "nim c -r -d:release --path:src -o:build/test_robustness_rel tests/test_robustness.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fingerprint_rel tests/test_fingerprint.nim"
  exec "nim c -r -d:release --path:src -o:build/test_chroma_rel tests/test_chroma.nim"
  exec "nim c -r -d:release --path:src -o:build/test_probe_rel tests/test_probe.nim"
  done "testCiRelease"

task testAll, "debug + release + C ABI":
  exec gate("test")
  exec gate("testRelease")
  exec gate("ctest")
  done "testAll"

# Isolated benchmark harness, not in the default gate. Release build so the
# NimContracts postconditions compile away and the timings reflect the shipped
# code path. Reads fixtures by relative path, so it runs from the repo root.
task bench, "Decode and fingerprint benchmarks (release; not in the default gate)":
  exec "nim c -r -d:release --path:src -o:build/bench_decode bench/bench_decode.nim"
  done "bench"

task benchReadme, "Run the benchmarks and splice their output into bench/README.md":
  exec gate("bench")
  exec "nim c -r -d:release --hints:off -o:build/bench_export bench/export_readme.nim"
  done "benchReadme"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"
  done "example"

# Nim takes `-o:` literally and appends no platform extension.
const
  sharedLib =
    when defined(windows): "libUniAudio.dll"
    elif defined(macosx): "libUniAudio.dylib"
    else: "libUniAudio.so"
  staticLib = "libUniAudio.a"  # MinGW `ar` on Windows, so `.a` everywhere.

  # @rpath install_name, so the copy bundled in the wheel is found at import.
  macArgs =
    when defined(macosx): " --passL:\"-Wl,-install_name,@rpath/" & sharedLib & "\""
    else: ""

task clib, "C shared library":
  exec "nim c --app:lib --noMain --mm:arc -d:release -o:" & sharedLib & macArgs &
       " src/UniAudio/c_api.nim"
  done "clib"

task clibStatic, "C static library":
  exec "nim c --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release -o:" & staticLib &
       " src/UniAudio/c_api.nim"
  done "clibStatic"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib -d:staticNoAutoInit --noMain --mm:arc -d:release" &
       " -o:UniAudio.lib src/UniAudio/c_api.nim"
  done "clibMsvc"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec gate("clibStatic")
  exec makeExe & " -C tests/c"
  done "ctest"

task cexample, "C demo":
  exec gate("clibStatic")
  exec makeExe & " -C examples/c"
  done "cexample"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"
  done "pyDeps"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec gate("clibMsvc")
  else:
    exec gate("clib")
  done "pyLib"

task buildCython, "Cython extension in-place":
  exec gate("pyLib")
  exec gate("pyDeps")
  # nimscript `cd` changes the VM cwd for the next exec without a shell, so
  # the task works under nimble's no-shell exec on Windows.
  cd "py"
  exec "python3 setup.py build_ext --inplace"
  cd ".."
  done "buildCython"

task pyTest, "Cython extension + pytest":
  exec gate("buildCython")
  cd "py"
  exec "python3 -m pytest -q"
  cd ".."
  done "pyTest"

task pyWheel, "wheel":
  exec gate("pyLib")
  exec gate("pyDeps")
  cd "py"
  exec "python3 setup.py bdist_wheel"
  cd ".."
  done "pyWheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen.
  # `mismatch` is the one capture suppression, and it is not optional: lcov 2.x
  # checks its own end line for a function against gcov's, and Nim's generated
  # destructors disagree. Every other lcov error still fails the build.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  # One cache per suite, then a merge. Compiling several suites into a shared
  # nimcache replaces the gcov files rather than adding to them, and the report
  # ends up describing whichever suite was built last — a module its own tests
  # cover well then reads as zero.
  var pieces: seq[string]
  for suite in ["pcm", "aiff", "flac", "alac", "ogg", "vorbis", "mp3", "tags",
                "fingerprint", "robustness", "probe"]:
    let here = cache & "/" & suite
    exec "nim c --path:src --nimcache:" & here &
         " --debugger:native --passC:--coverage --passL:--coverage" &
         " -o:build/cov_" & suite & " tests/test_" & suite & ".nim"
    exec "./build/cov_" & suite
    let piece = here & ".info"
    exec "lcov --capture --directory " & here & " --base-directory ." &
         " --include \"*/src/UniAudio/*\" --output-file " & piece &
         " --quiet --ignore-errors mismatch"
    pieces.add piece
  var merge = "lcov"
  for piece in pieces: merge.add " --add-tracefile " & piece
  exec merge & " --output-file lcov.info --quiet --ignore-errors mismatch"
  # gcov can attribute a final generated expression to EOF + 1, and that one
  # artefact answers to two names: lcov 2.0, the version ubuntu-latest installs,
  # calls it `unmapped` and rejects `range` as a category outright, while 2.5
  # calls it `range` and can filter those lines away. Ask which one is there.
  let genhtmlRange =
    if gorgeEx("genhtml --version").output.contains("LCOV version 2.0"):
      " --ignore-errors unmapped"
    else: " --filter range --ignore-errors range"
  exec "genhtml lcov.info" & genhtmlRange &
       " --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
  done "coverage"
