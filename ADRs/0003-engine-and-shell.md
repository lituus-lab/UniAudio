<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0003: Engine & Shell

- Status: Accepted
- Date: 2026-07-15
- Scope: every `Uni*` library consumed by a native app

## Decision

- **Engine** (pure Nim): the library + a thin C ABI (`src/<Lib>/c_api.nim`),
  built `--app:staticlib`/`--app:lib --noMain --mm:arc -d:release` →
  `lib<Lib>.a` / `lib<Lib>.so`. No UI in the engine.
- **Shell** (native UI, separate private repo): links the C ABI, owns the UI.
- **C header** (`include/<Lib>.h`): hand-written, kept in sync with `c_api.nim`.
  `tests/c` links the header against the lib — a renamed/retyped symbol fails
  to link, so the C test is the ABI drift detector. (`--header:X.h` auto-gen is
  not used.)
- `--mm:arc`: deterministic memory model for foreign callers (no cycle
  collector). `--noMain`: no `NimMain()` call needed from C.
- **Python binding**: Cython over the shared lib, RPATH `$ORIGIN`.
