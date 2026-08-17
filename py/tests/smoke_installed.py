# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Exercise an installed `uniaudio` wheel from outside the source tree.

Not a pytest module: it is copied next to a fixtures directory and run there,
where `test_wave.py`'s relative paths no longer hold. Its job is to prove the
wheel is self-contained — the extension alone would import fine while the
shared library it needs stayed behind, and only a real decode catches that.
"""
import pathlib
import sys

import uniaudio

FIXTURES = pathlib.Path("tests") / "fixtures"


def main():
    if not FIXTURES.is_dir():
        sys.exit(f"fixtures not found beside this script: {FIXTURES.resolve()}")

    assert uniaudio.sniff(FIXTURES / "sweep.flac") == "flac"
    assert uniaudio.sniff(FIXTURES / "sweep-mp3.mp3") == "mp3"

    # Decoding is what reaches the bundled library, not just the extension.
    shape = uniaudio.probe(FIXTURES / "sweep-mp3.mp3")
    assert shape == (11025, 1, 33075), shape

    title = uniaudio.tags(FIXTURES / "tagged.flac")["title"]
    assert title == "Été à Nice", title

    duration, words = uniaudio.fingerprint(FIXTURES / "sweep.wav")
    assert len(words) > 0, "a three-second recording should fingerprint"
    assert 2.9 < duration < 3.1, duration

    print(f"installed wheel ok: uniaudio {uniaudio.version()}")


if __name__ == "__main__":
    main()
