<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0001: Acyclic DAG + anti-cycle invariants

- Status: Accepted
- Date: 2026-07-15
- Scope: every `Uni*` repo

## Decision

Family dependencies form a strictly acyclic DAG (layers 0–7); a library
depends only on lower layers. Topological order = build order. A back-edge is
rejected in review and fails CI.

## Invariants

1. Layer-0 primitives have no domain dependency (`UniColor`, `UniMIDI` → none).
2. Type modules never import algorithm modules within a library
   (`types/` ↛ `algorithms/`; `io/` → `types/` only).
3. `UniLinalg` is a repo above `UniMath`; `UniGeom` consumes it, no redefined Vec.
4. No library depends on an app. Apps may depend on anything below.
5. Optional deps (`nimsimd`, `NimContracts`) stay optional — never a hard edge.

Extraction into its own repo requires a consumer wanting the piece *without*
the parent's main subject; else one repo with a documented internal DAG.
