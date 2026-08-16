# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The Python surface over the C ABI, exercised against real files."""
import struct

import pytest

from uniaudio import UniAudioError, version, wave_probe


def write_wav(path, frames=400, rate=8000, channels=1):
    data = b"\x00\x00" * frames * channels
    header = (
        b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
        + b"fmt " + struct.pack("<IHHIIHH", 16, 1, channels, rate,
                                rate * channels * 2, channels * 2, 16)
        + b"data" + struct.pack("<I", len(data))
    )
    path.write_bytes(header + data)
    return path


def test_version_is_reported():
    assert version().count(".") == 2


def test_probe_reports_the_shape_the_data_actually_holds(tmp_path):
    path = write_wav(tmp_path / "take.wav", frames=400, rate=8000, channels=1)
    assert wave_probe(path) == (8000, 1, 400)


def test_probe_counts_frames_per_channel(tmp_path):
    path = write_wav(tmp_path / "stereo.wav", frames=100, rate=44100, channels=2)
    rate, channels, frames = wave_probe(path)
    assert (rate, channels) == (44100, 2)
    # 100 frames of stereo is 200 samples; frames count per channel.
    assert frames == 100


def test_a_file_that_is_not_a_wave_raises_rather_than_guessing(tmp_path):
    path = tmp_path / "not.wav"
    path.write_bytes(b"OggS and then some")
    with pytest.raises(UniAudioError) as failure:
        wave_probe(path)
    assert failure.value.status != 0
    assert str(failure.value)


def test_a_missing_file_raises(tmp_path):
    with pytest.raises(UniAudioError):
        wave_probe(tmp_path / "absent.wav")
