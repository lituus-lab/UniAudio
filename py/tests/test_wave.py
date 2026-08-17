# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The Python surface over the C ABI, exercised against real files."""
import array
import math
import pathlib
import struct

import pytest

from uniaudio import (UniAudioError, decode, decode_resampled, fingerprint,
                      offset_similarity, probe, similarity, sniff, tags,
                      version, wave_probe, write_wave)

FIXTURES = pathlib.Path(__file__).resolve().parents[2] / "tests" / "fixtures"


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


def test_a_missing_file_is_an_io_failure_not_a_format_one(tmp_path):
    # The status codes exist to be acted on: a file that is not there is a
    # different problem from a file whose bytes are wrong.
    for call in (wave_probe, probe):
        with pytest.raises(UniAudioError) as failure:
            call(tmp_path / "absent.wav")
        assert failure.value.status == 2


def test_sniff_names_the_container_without_decoding(tmp_path):
    path = write_wav(tmp_path / "take.wav")
    assert sniff(path) == "wav"
    assert sniff(FIXTURES / "sweep.flac") == "flac"


def test_a_sync_word_is_recognised_but_is_not_a_decodable_file(tmp_path):
    # An MP3 frame sync with nothing behind it: named as MP3, and refused when
    # opened, rather than decoded into noise.
    path = tmp_path / "song.mp3"
    path.write_bytes(b"\xff\xfb\x90\x00" + b"\x00" * 64)
    assert sniff(path) == "mp3"
    with pytest.raises(UniAudioError):
        probe(path)


def test_an_mp3_probes_to_the_shape_of_the_wav_it_came_from():
    assert sniff(FIXTURES / "sweep-mp3.mp3") == "mp3"
    assert probe(FIXTURES / "sweep-mp3.mp3") == wave_probe(FIXTURES / "sweep.wav")


def test_an_alac_m4a_probes_to_the_shape_of_the_wav_it_came_from():
    assert sniff(FIXTURES / "sweep-alac.m4a") == "mp4"
    assert probe(FIXTURES / "sweep-alac.m4a") == wave_probe(FIXTURES / "sweep.wav")


def test_probe_agrees_with_the_wave_specific_one(tmp_path):
    path = write_wav(tmp_path / "take.wav", frames=256, rate=8000, channels=2)
    assert probe(path) == wave_probe(path)


def test_a_fingerprint_matches_itself_and_survives_re_encoding():
    duration, words = fingerprint(FIXTURES / "sweep.wav")
    assert duration == pytest.approx(3.0)
    assert len(words) > 0
    assert similarity(words, words) == pytest.approx(1.0)
    # The same samples through FLAC must fingerprint identically.
    _, from_flac = fingerprint(FIXTURES / "sweep.flac")
    assert words == from_flac


def test_something_too_short_fingerprints_to_nothing(tmp_path):
    path = write_wav(tmp_path / "brief.wav", frames=400)
    duration, words = fingerprint(path)
    assert words == []
    assert duration == pytest.approx(0.05)


def test_similarity_of_nothing_is_zero():
    assert similarity([], []) == 0.0
    assert similarity([1, 2, 3], []) == 0.0


def test_tags_come_back_as_a_dict_with_the_values_the_file_carries():
    result = tags(FIXTURES / "tagged-v24.mp3")
    assert result["title"] == "Été à Nice"
    assert result["artist"] == "Lituus Lab"
    assert result["trackNumber"] == 3
    assert result["trackTotal"] == 12
    # The date is whatever the file wrote, not a parsed date object.
    assert result["date"] == "2026"


def test_a_file_with_no_tags_reads_as_empty_fields_not_an_error():
    result = tags(FIXTURES / "sweep.wav")
    assert result["title"] == ""
    assert result["trackNumber"] == 0
    assert result["other"] == []


def test_a_name_with_no_field_of_its_own_is_kept():
    result = tags(FIXTURES / "tagged.flac")
    assert any(entry["key"] == "ENCODER" for entry in result["other"])


def test_decode_returns_one_bulk_array_not_a_list_of_objects():
    rate, channels, frames, samples = decode(FIXTURES / "sweep.flac")
    assert (rate, channels, frames) == (11025, 1, 33075)
    # A float32 array, not a Python list: a three-minute stereo track would be
    # sixteen million objects otherwise.
    assert isinstance(samples, array.array)
    assert samples.typecode == "f"
    assert len(samples) == frames * channels


def test_decode_resampled_averages_the_channels_and_changes_the_rate():
    rate, channels, frames, samples = decode_resampled(
        FIXTURES / "stereo16.wav", target_rate=22050, to_mono=True)
    assert (rate, channels, frames) == (22050, 1, 2500)
    assert len(samples) == 2500


def test_decode_resampled_leaves_the_rate_alone_when_asked_for_zero():
    rate, channels, frames, _ = decode_resampled(FIXTURES / "stereo16.wav")
    assert (rate, channels, frames) == (44100, 2, 5000)


def test_written_wav_reads_back_within_one_quantisation_step(tmp_path):
    tone = array.array("f", [0.4 * math.sin(2 * math.pi * 440 * i / 8000)
                             for i in range(500)])
    path = tmp_path / "tone.wav"
    write_wave(path, tone, 8000, 1, 16)
    rate, channels, frames, back = decode(path)
    assert (rate, channels, frames) == (8000, 1, 500)
    assert max(abs(a - b) for a, b in zip(tone, back)) < 1.0 / 30000.0


def test_write_wave_accepts_a_plain_list_too(tmp_path):
    path = tmp_path / "pair.wav"
    write_wave(path, [0.0, 0.1, 0.2, 0.3], 8000, 2, 16)
    assert wave_probe(path) == (8000, 2, 2)


def test_write_wave_refuses_a_ragged_frame_count(tmp_path):
    with pytest.raises(ValueError):
        write_wave(tmp_path / "odd.wav", [0.0, 0.1, 0.2], 8000, 2, 16)


def test_offset_similarity_finds_a_match_a_flat_comparison_misses():
    _, words = fingerprint(FIXTURES / "sweep.wav")
    shifted = words[4:]
    assert offset_similarity(words, shifted, 8) == 1.0
    assert similarity(words, shifted) < 0.9
    assert offset_similarity([], [], 8) == 0.0


def test_write_wave_refuses_a_depth_the_writer_does_not_implement(tmp_path):
    # 8-bit WAV is unsigned by convention and this writer emits signed bytes;
    # 32 bits carries no more precision than 24 from a float32 sample.
    for bits in (8, 32):
        with pytest.raises(UniAudioError):
            write_wave(tmp_path / f"d{bits}.wav", [0.0, 0.1], 8000, 1, bits)
