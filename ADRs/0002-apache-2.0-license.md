<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# ADR-0002: Apache License 2.0 for the engines

- Status: Accepted
- Date: 2026-07-15
- Scope: every `Uni*` engine (open-source)

## Decision

`Uni*` engine repos are Apache-2.0. Apps (closed-source) are private and not
covered. The MIT→Apache relicense is unambiguous (each repo is author-single).
Forks `NimContracts`/`nimsimd` keep MIT (upstream preserved).

Every repo ships `LICENSE`, `NOTICE`, and `CONTRIBUTING.md` (DCO). Apache-2.0
grants an explicit patent license; `NOTICE` records the bundled MIT dep.
