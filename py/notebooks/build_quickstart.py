# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Author py/notebooks/quickstart.ipynb, then execute it so the committed file
carries real outputs for GitHub to render. Run from the repo root:

    python3 py/notebooks/build_quickstart.py

CI re-executes the notebook against an installed wheel and compares the fresh
outputs with the committed ones, so a stale value fails the build. Re-run this
after any API change."""
import os

import nbformat as nbf
from nbclient import NotebookClient

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(HERE, "quickstart.ipynb")

CELLS = [
    ("md", """# UniAudio — Python quickstart

`uniaudio` is a Cython extension over the UniAudio C ABI. It reads audio
containers, decodes the ones under no licence, reads tags, and fingerprints
a recording by how it sounds.

It is a thin binding: what the C ABI cannot reach, this cannot reach either.

```
pip install lituus-uniaudio
```

The cells below read the repository's own test fixtures, so this notebook
runs from where it sits in the source tree."""),
    ("code", """import importlib.resources

import uniaudio

# The audio below ships inside the wheel, so this notebook runs wherever
# uniaudio is installed -- not only inside a checkout.
FIXTURES = importlib.resources.files("uniaudio") / "data"
uniaudio.version()"""),
    ("md", """## Naming a container without decoding it

The extension is not evidence of what a file holds. `sniff` reads the
leading bytes and says what is really there."""),
    ("code", """for name in ["sweep.wav", "sweep.flac", "sweep-alac.m4a",
             "sweep-vorbis.ogg", "sweep-mp3.mp3"]:
    print(f"{name:<18} {uniaudio.sniff(FIXTURES / name)}")"""),
    ("md", """## The shape of the audio

`probe` returns `(sample_rate, channels, frames)` for any container the
library decodes. `frames` counts per channel.

These five files are the same three seconds of a sine sweep."""),
    ("code", """for name in ["sweep.wav", "sweep.flac", "sweep-alac.m4a",
             "sweep-vorbis.ogg", "sweep-mp3.mp3"]:
    rate, channels, frames = uniaudio.probe(FIXTURES / name)
    print(f"{name:<18} {rate} Hz, {channels} ch, {frames} frames")"""),
    ("md", """## Tags

Four unrelated tagging schemes grew up around these formats — ID3 in MPEG
audio, Vorbis comments in Ogg and FLAC, iTunes atoms in MP4. `tags` reads
whichever one a file uses into the same dictionary."""),
    ("code", """uniaudio.tags(FIXTURES / "tagged-v24.mp3")"""),
    ("md", """`date` is whatever the file wrote, kept as a string. Tag dates follow no
agreed format, and deciding which half of a bare `01/02/2019` is the month
would be an invention.

A name with no field of its own is not dropped; it lands in `other`."""),
    ("md", """## Recognising a recording by how it sounds

The fingerprint describes the sound, not the bytes, so two encodings of the
same audio give nearly the same one. It finds duplicates that no checksum
would match."""),
    ("code", """duration, words = uniaudio.fingerprint(FIXTURES / "sweep.wav")
print(f"{duration:.2f} s, {len(words)} words")
print(words[:6])"""),
    ("code", """_, from_flac = uniaudio.fingerprint(FIXTURES / "sweep.flac")
_, from_mp3 = uniaudio.fingerprint(FIXTURES / "sweep-mp3.mp3")

print("wav against flac:", uniaudio.similarity(words, from_flac))
print("wav against mp3: ", uniaudio.similarity(words, from_mp3))"""),
    ("md", """FLAC is lossless, so its fingerprint matches exactly. A lossy encode moves
it, and a pure sweep is the hardest case there is: nearly all its energy
sits in one band at a time, so a small change flips many bits at once. Do
not read the second number as what the fingerprint does to music."""),
    ("md", """## When a file cannot be read

Every failure is a `UniAudioError` carrying both the reason the library gave
and a status: `2` for a file that is not there, `3` for bytes that are not
what they claim. The two are different problems and are worth telling apart."""),
    ("code", """try:
    uniaudio.probe("no-such-file.flac")
except uniaudio.UniAudioError as failure:
    print(f"status {failure.status}: {failure}")"""),
    ("md", """A container the library reads but a codec it does not decode is the second
kind. The file below is a real Ogg — the container parses — carrying FLAC
rather than Vorbis, and the error says so instead of guessing."""),
    ("code", """try:
    uniaudio.probe(FIXTURES / "sweep-oggflac.ogg")
except uniaudio.UniAudioError as failure:
    print(f"status {failure.status}: {failure}")"""),
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
