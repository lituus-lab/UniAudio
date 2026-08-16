<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# The Book

`index.nim` is the whole book: one nimib page, built by `nimble book` into
`index.html`. Its code blocks are compiled and run at build time, so a change
that breaks the API breaks the build instead of leaving the page wrong.

The blocks read fixtures from `tests/fixtures` by relative path, so the build
has to run from the repository root — which is what `nimble book` does.
