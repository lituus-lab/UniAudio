# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
import nimib

nbInit
nb.title = "UniAudio"

nbText: """
# UniAudio

The reference scaffold every `Uni*` engine is cloned from. It carries one
hello-world function, `fibonacci`, exposed across the three surfaces each engine
must ship: **Nim**, a **C ABI**, and a **Python** binding.

This page is a nimib book: every Nim block below is compiled and run when the
book is built, and the output shown is what the code actually produced. A change
that breaks the API breaks the docs build, so the two cannot drift apart.

## The Nim surface

The umbrella module re-exports every public submodule.
"""

nbCode:
  import UniAudio

  echo "version ", UniAudioVersion
  echo "fib(10) = ", fibonacci(10)
  echo "fib(92) = ", fibonacci(92)

nbText: """
## The domain is part of the contract

`fibonacci` is not defined for every `int`. `FibMaxN` is the largest argument
whose result still fits in `int64`, and that bound is stated as a precondition
rather than left to the caller to remember.
"""

nbCode:
  echo "FibMaxN = ", FibMaxN
  echo "fib(FibMaxN) = ", fibonacci(FibMaxN)

nbText: """
The contract is written with NimContracts (`require:` / `ensure:` / `body:`).
Under `-d:release` it compiles away entirely: the release build pays nothing,
while debug builds and the test suite catch a violation at the call site.

A postcondition never re-derives the result by calling the function again — it
states a property cheaper to check than the body is to run. Here, `result >= 0`.

## The C ABI

The same function, reachable from anything that speaks C. The header is
hand-written and kept in sync with `src/UniAudio/c_api.nim`; `tests/c` links
one against the other on every CI run, so a drift is caught rather than shipped.

```c
#define UNITEMPLATE_FIB_MAX_N 92

const char *uniaudio_version(void);
long long   uniaudio_fibonacci(int n);
```

The C ABI **never raises**. Where the Nim function has a precondition, the C
entry point clamps instead: out-of-range input returns a defined value rather
than unwinding across the ABI boundary, which would be undefined behaviour.

```c
uniaudio_fibonacci(-5);   /* 0       — clamped, not a trap */
uniaudio_fibonacci(200);  /* fib(92) — clamped to the domain */
```

## The Python surface

A Cython extension over the C ABI, shipped as a self-contained wheel: the
library travels inside the package, so installing it needs neither Nim nor a
compiler.

```python
import uniaudio

uniaudio.fibonacci(10)   # 55
uniaudio.version()       # '0.1.0'
```

Here the domain check returns, because Python has exceptions to carry it:
`fibonacci(-1)` and `fibonacci(93)` raise `ValueError`, a non-`int` argument
raises `TypeError`. Each surface expresses one contract in the terms its own
callers expect — a precondition in Nim, a clamp in C, an exception in Python.

`py/notebooks/quickstart.ipynb` runs these calls against an installed wheel and
renders on GitHub directly.

## Cloning this into an engine

Rename the tokens (`UniAudio` → `UniFoo`, `uniaudio` → `unifoo`, `uaud_` →
the engine's prefix), replace `fibonacci.nim` with the domain modules, then
rewrite this book for the domain. The generated reference lists the API; the
book is where the domain gets explained.
"""

nbSave
