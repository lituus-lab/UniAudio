# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Exercise an installed `uniaudio` wheel from outside the source tree.

`test_wave.py` resolves its fixtures relative to the repository, which no
longer holds once the wheel is installed elsewhere. This module is copied to a
neutral directory and run there: importing the extension proves little on its
own, because it imports fine while the shared library it needs stays behind.
Only a real decode catches that, so the decoding checks run when the fixtures
travel alongside and skip, loudly, when they do not.

The name matters: pytest collects `test_*.py`. Under its previous name, and as
a `__main__` script, it ran nowhere -- neither CI nor `nimble pyTest` executed
a line of it.
"""
import pathlib

import pytest

import uniaudio

HERE = pathlib.Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"


def test_the_wheel_reports_its_version():
    assert uniaudio.version()


@pytest.mark.skipif(not FIXTURES.is_dir(),
                    reason="no fixtures directory beside this file")
def test_the_bundled_library_decodes():
    # Decoding is what reaches the bundled library, not just the extension.
    assert uniaudio.sniff(FIXTURES / "sweep.flac") == "flac"
    assert uniaudio.sniff(FIXTURES / "sweep-mp3.mp3") == "mp3"

    shape = uniaudio.probe(FIXTURES / "sweep-mp3.mp3")
    assert shape == (11025, 1, 33075), shape

    title = uniaudio.tags(FIXTURES / "tagged.flac")["title"]
    assert title == "\u00c9t\u00e9 \u00e0 Nice", title

    duration, words = uniaudio.fingerprint(FIXTURES / "sweep.wav")
    assert len(words) > 0, "a three-second recording should fingerprint"
    assert 2.9 < duration < 3.1, duration
