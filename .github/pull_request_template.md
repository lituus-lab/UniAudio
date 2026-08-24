<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
<!-- markdownlint-disable-file MD041 -->
<!-- A pull request body is a fragment, not a document: a top-level heading
     here would render as one inside the PR. -->
## What changes, and why

<!-- The problem, then the fix. Link the issue if there is one. -->

## AI assistance

<!-- Optional disclosure — not a gate. The DCO sign-off is the accountability
     mechanism; the human contributor owns the change either way. -->
- [ ] I used AI/LLM assistance for this change

If yes, I have reviewed the output, ensured it introduces no third-party code
without a compatible license/attribution, and can stand behind it.

## Checks

- [ ] Every commit carries `Signed-off-by:` (`git commit -s`) — the DCO job blocks otherwise
- [ ] Commits and this PR title follow Conventional Commits — the `commitizen` job blocks otherwise
- [ ] Commits are atomic (one logical change each; several per PR is fine, but not one monolithic commit)
- [ ] `nimble testAll` passes
- [ ] `nimble lint` and `nimble checkVGraph` pass
- [ ] C ABI touched → `include/UniAudio.h` updated in the same commit
- [ ] Public API touched → `book/index.nim` still builds and describes it
