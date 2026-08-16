# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel; this script only
regenerates it after an API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniAudio — Python quickstart

`uniaudio` is a Cython extension over the UniAudio C ABI, shipped as a
self-contained wheel: the native library travels inside the package, so
installing it needs neither Nim nor a compiler.

```
pip install uniaudio
```

CI executes this notebook against the wheel the release actually publishes, so
an output below that stops matching fails the build."""),
    ("md", "## The API"),
    ("code", """import uniaudio

uniaudio.version(), uniaudio.__version__"""),
    ("md", "`fibonacci` is the template's hello-world, iterative and O(n)."),
    ("code", "[uniaudio.fibonacci(n) for n in range(11)]"),
    ("md", """## The domain is part of the contract

`fibonacci` is defined on `[0, 92]` — 92 being the largest argument whose result
still fits in a signed 64-bit integer. The bound is not advisory."""),
    ("code", "uniaudio.fibonacci(92)"),
    ("md", """Past it the binding raises, rather than returning a silently wrong
number. This is the contract the Nim library states as a precondition; each
surface expresses it in the terms its own callers expect."""),
    ("code", """try:
    uniaudio.fibonacci(93)
except ValueError as exc:
    print("ValueError:", exc)"""),
    ("code", """try:
    uniaudio.fibonacci(-1)
except ValueError as exc:
    print("ValueError:", exc)"""),
    ("md", "A non-integer argument is a type error, not a coercion."),
    ("code", """try:
    uniaudio.fibonacci(10.0)
except TypeError as exc:
    print("TypeError:", exc)"""),
    ("md", """## The C ABI underneath

The same entry points are reachable from anything that speaks C. There the
contract is expressed by clamping instead of raising — an exception must never
unwind across an ABI boundary:

```c
uniaudio_fibonacci(-5);   /* 0       — clamped */
uniaudio_fibonacci(200);  /* fib(92) — clamped */
```

See `include/UniAudio.h`, and the book for the full picture."""),
]


def main():
    nb = nbf.v4.new_notebook()
    nb.cells = [
        nbf.v4.new_markdown_cell(src) if kind == "md" else nbf.v4.new_code_cell(src)
        for kind, src in CELLS
    ]
    nb.metadata["kernelspec"] = {
        "display_name": "Python 3",
        "language": "python",
        "name": "python3",
    }
    # Execute from the repo root, never from py/: there, `import uniaudio`
    # would resolve to the py/uniaudio source tree instead of the installed
    # package, and the notebook would stop testing what it claims to test.
    NotebookClient(nb, timeout=120, kernel_name="python3",
                   resources={"metadata": {"path": ROOT}}).execute()
    with open(OUT, "w") as f:
        nbf.write(nb, f)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
