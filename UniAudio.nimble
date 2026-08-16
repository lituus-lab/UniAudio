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
requires "https://github.com/lituus-lab/UniMath#feat/native-float-math"

task lint, "Fail if nimpretty would reformat a source":
  exec "nim c -r --hints:off -o:build/lint_tool tools/lint.nim"

task checkVGraph, "Fail on an import that climbs the layers in vgraph.cfg":
  exec "nim c -r --hints:off -o:build/vgraph_tool tools/vgraph.nim"

task docsDeps, "Install the docs toolchain (nimib)":
  exec "nimble install -y nimib"

task book, "Build the nimib book (needs nimib)":
  # nimib compiles and runs the book's code blocks: a drift fails the build.
  exec "nim c -r --path:src --hints:off -o:build/book book/index.nim"

task docs, "API reference + book into pages/ — what CI publishes":
  rmDir "pages"
  exec "nim doc --index:on --outdir:pages/api --project --hints:off src/UniAudio.nim"
  exec "nimble book"
  # The book is the landing page; the generated reference sits under api/.
  cpFile "book/index.html", "pages/index.html"

task test, "Nim tests (debug, contracts active)":
  exec "nim c -r --path:src -o:build/test_pcm tests/test_pcm.nim"
  exec "nim c -r --path:src -o:build/test_aiff tests/test_aiff.nim"
  exec "nim c -r --path:src -o:build/test_flac tests/test_flac.nim"
  exec "nim c -r --path:src -o:build/test_alac tests/test_alac.nim"
  exec "nim c -r --path:src -o:build/test_ogg tests/test_ogg.nim"
  exec "nim c -r --path:src -o:build/test_vorbis tests/test_vorbis.nim"
  exec "nim c -r --path:src -o:build/test_fingerprint tests/test_fingerprint.nim"

task testRelease, "Nim tests (release, contracts compiled away)":
  exec "nim c -r -d:release --path:src -o:build/test_pcm_rel tests/test_pcm.nim"
  exec "nim c -r -d:release --path:src -o:build/test_aiff_rel tests/test_aiff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_flac_rel tests/test_flac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_alac_rel tests/test_alac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_ogg_rel tests/test_ogg.nim"
  exec "nim c -r -d:release --path:src -o:build/test_vorbis_rel tests/test_vorbis.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fingerprint_rel tests/test_fingerprint.nim"

task testCi, "Nim tests (CI subset, debug)":
  exec "nim c -r --path:src -o:build/test_pcm tests/test_pcm.nim"
  exec "nim c -r --path:src -o:build/test_aiff tests/test_aiff.nim"
  exec "nim c -r --path:src -o:build/test_flac tests/test_flac.nim"
  exec "nim c -r --path:src -o:build/test_alac tests/test_alac.nim"
  exec "nim c -r --path:src -o:build/test_ogg tests/test_ogg.nim"
  exec "nim c -r --path:src -o:build/test_vorbis tests/test_vorbis.nim"
  exec "nim c -r --path:src -o:build/test_fingerprint tests/test_fingerprint.nim"

task testCiRelease, "Nim tests (CI subset, release)":
  exec "nim c -r -d:release --path:src -o:build/test_pcm_rel tests/test_pcm.nim"
  exec "nim c -r -d:release --path:src -o:build/test_aiff_rel tests/test_aiff.nim"
  exec "nim c -r -d:release --path:src -o:build/test_flac_rel tests/test_flac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_alac_rel tests/test_alac.nim"
  exec "nim c -r -d:release --path:src -o:build/test_ogg_rel tests/test_ogg.nim"
  exec "nim c -r -d:release --path:src -o:build/test_vorbis_rel tests/test_vorbis.nim"
  exec "nim c -r -d:release --path:src -o:build/test_fingerprint_rel tests/test_fingerprint.nim"

task testAll, "debug + release + C ABI":
  exec "nimble test"
  exec "nimble testRelease"
  exec "nimble ctest"

task example, "Nim demo":
  exec "nim c -r --path:src -o:build/demo examples/demo.nim"

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

task clibStatic, "C static library":
  exec "nim c --app:staticlib --noMain --mm:arc -d:release -o:" & staticLib &
       " src/UniAudio/c_api.nim"

task clibMsvc, "C static library, MSVC ABI (Windows Python extension)":
  # CPython on Windows is MSVC-built and cannot link MinGW output.
  exec "nim c --cc:vcc --app:staticlib --noMain --mm:arc -d:release" &
       " -o:UniAudio.lib src/UniAudio/c_api.nim"

# Nim's MinGW toolchain names it mingw32-make.
let makeExe = if findExe("mingw32-make").len > 0: "mingw32-make" else: "make"

# `make -C`, not `cd dir && make`: nimble's exec runs no shell on Windows.
task ctest, "C ABI tests":
  exec "nimble clibStatic"
  exec makeExe & " -C tests/c"

task cexample, "C demo":
  exec "nimble clibStatic"
  exec makeExe & " -C examples/c"

task pyDeps, "Install Python build deps (setuptools, Cython, pytest) if missing":
  exec "python3 -m pip install --break-system-packages --quiet setuptools wheel \"Cython>=3.0.0\" pytest"

# The extension links the vcc static lib on Windows, the shared lib elsewhere.
task pyLib, "Build the library the Python extension links against":
  when defined(windows):
    exec "nimble clibMsvc"
  else:
    exec "nimble clib"

task buildCython, "Cython extension in-place":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  exec "cd py && python3 setup.py build_ext --inplace"

task pyTest, "Cython extension + pytest":
  exec "nimble buildCython"
  exec "cd py && python3 -m pytest -q"

task pyWheel, "wheel":
  exec "nimble pyLib"
  exec "nimble pyDeps"
  exec "cd py && python3 setup.py bdist_wheel"

task coverage, "LCOV + HTML coverage report for the Nim sources (needs lcov)":
  # gcov and lcov driven directly, no coco. Linux and macOS only.
  # --debugger:native attributes lines to the .nim sources, not the generated C.
  # --include keeps stdlib out of the capture, where lcov 2.x aborts on Nim's
  # codegen. Together they leave nothing to suppress: no --ignore-errors here,
  # so a real problem still fails the build.
  let cache = "build/covcache"
  rmDir cache
  rmDir "coverage"
  exec "nim c --path:src --nimcache:" & cache &
       " --debugger:native --passC:--coverage --passL:--coverage" &
       " -o:build/test_coverage tests/test_pcm.nim"
  exec "./build/test_coverage"
  exec "lcov --capture --directory " & cache & " --base-directory ." &
       " --include \"*/src/UniAudio/*\" --output-file lcov.info --quiet"
  exec "genhtml lcov.info --output-directory coverage --legend --quiet"
  exec "lcov --summary lcov.info"
