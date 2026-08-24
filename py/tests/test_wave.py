# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""The Python surface over the C ABI, exercised against real files."""
import array
import math
import pathlib
import struct

import pytest

from uniaudio import (UniAudioError, WaveWriter, chroma_fingerprint,
                      chroma_similarity, decode, decode_resampled,
                      fingerprint, offset_similarity, probe, similarity, sniff,
                      tags, version, wave_probe, write_alac, write_flac,
                      write_wave)

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


def test_a_written_flac_reads_back_exactly(tmp_path):
    rate, channels, frames, samples = decode(FIXTURES / "stereo16.wav")
    path = tmp_path / "out.flac"
    write_flac(path, samples, rate, channels, 16)
    assert sniff(path) == "flac"
    back_rate, back_channels, back_frames, back = decode(path)
    assert (back_rate, back_channels, back_frames) == (rate, channels, frames)
    assert max(abs(a - b) for a, b in zip(samples, back)) < 1.0 / 30000.0


def test_a_written_flac_is_smaller_than_the_wav_it_came_from(tmp_path):
    rate, channels, frames, samples = decode(FIXTURES / "tone16.wav")
    path = tmp_path / "tone.flac"
    write_flac(path, samples, rate, channels, 16)
    assert path.stat().st_size < (FIXTURES / "tone16.wav").stat().st_size


def test_a_written_alac_reads_back_exactly(tmp_path):
    rate, channels, frames, samples = decode(FIXTURES / "stereo16.wav")
    path = tmp_path / "out.m4a"
    write_alac(path, samples, rate, channels, 16)
    # An .m4a is sniffed as its container, not its codec: which codec it holds
    # is what decoding it finds inside.
    assert sniff(path) == "mp4"
    back_rate, back_channels, back_frames, back = decode(path)
    assert (back_rate, back_channels, back_frames) == (rate, channels, frames)
    assert max(abs(a - b) for a, b in zip(samples, back)) < 1.0 / 30000.0


def test_write_alac_refuses_what_it_does_not_implement(tmp_path):
    rate, channels, frames, samples = decode(FIXTURES / "stereo16.wav")
    for bits in (8, 20, 32):
        with pytest.raises(UniAudioError):
            write_alac(tmp_path / f"d{bits}.m4a", samples, rate, channels, bits)
    # A channel count that does not divide the buffer is caught by the binding,
    # before the ABI is ever entered — the ABI cannot see a length.
    with pytest.raises(ValueError):
        write_alac(tmp_path / "odd.m4a", samples, rate, 3, 16)
    # One that does divide it reaches the ABI, which refuses more than two.
    thirds = samples[: len(samples) // 3 * 3]
    with pytest.raises(UniAudioError):
        write_alac(tmp_path / "wide.m4a", thirds, rate, 3, 16)


def _tone(frames, channels=2):
    """Interleaved samples that exercise both signs and the clamp at the ends."""
    out = array.array("f")
    for index in range(frames):
        value = math.sin(index * 0.05)
        for channel in range(channels):
            out.append(value if channel % 2 == 0 else -value)
    return out


def test_streaming_writer_lands_on_the_same_bytes_as_the_batch_writer(tmp_path):
    samples = _tone(500)
    batch = tmp_path / "batch.wav"
    streamed = tmp_path / "streamed.wav"
    write_wave(batch, samples, 8000, 2)
    with WaveWriter(streamed, 8000, 2) as writer:
        # Two unequal blocks: where the split falls must not reach the file.
        writer.write(samples[:200 * 2])
        writer.write(samples[200 * 2:])
    assert streamed.read_bytes() == batch.read_bytes()


def test_streaming_writer_counts_frames_per_channel(tmp_path):
    path = tmp_path / "counted.wav"
    with WaveWriter(path, 8000, 2) as writer:
        assert writer.frame_count == 0
        writer.write(_tone(120))
        assert writer.frame_count == 120
        writer.write(_tone(30))
        assert writer.frame_count == 150
    assert wave_probe(path) == (8000, 2, 150)


def test_a_writer_left_unclosed_still_finishes_the_file(tmp_path):
    path = tmp_path / "dropped.wav"
    writer = WaveWriter(path, 8000, 1)
    writer.write(_tone(64, channels=1))
    del writer  # __dealloc__ patches the sizes the header declares
    assert wave_probe(path) == (8000, 1, 64)


def test_a_partial_frame_is_refused_rather_than_padded(tmp_path):
    with WaveWriter(tmp_path / "partial.wav", 8000, 2) as writer:
        with pytest.raises(ValueError):
            writer.write(array.array("f", [0.0]))


def test_a_closed_writer_refuses_further_work(tmp_path):
    writer = WaveWriter(tmp_path / "closed.wav", 8000, 1)
    writer.close()
    writer.close()  # closing twice is a no-op, not a second free
    with pytest.raises(ValueError):
        writer.write(array.array("f", [0.0]))
    with pytest.raises(ValueError):
        writer.frame_count


def test_a_width_the_writer_does_not_implement_is_refused(tmp_path):
    with pytest.raises(UniAudioError):
        WaveWriter(tmp_path / "eight.wav", 8000, 1, bits_per_sample=8)


def test_an_empty_streamed_file_is_still_a_valid_wave(tmp_path):
    path = tmp_path / "empty.wav"
    with WaveWriter(path, 8000, 1):
        pass
    assert wave_probe(path) == (8000, 1, 0)


def test_chroma_survives_a_lossy_re_encode():
    """The band-energy fingerprint drifts here; the chroma one is why it exists."""
    duration, original = chroma_fingerprint(FIXTURES / "sweep.wav")
    assert original
    assert duration > 0
    for encoded in ["sweep-mp3.mp3", "sweep-vorbis.ogg", "sweep-alac.m4a"]:
        _, copy = chroma_fingerprint(FIXTURES / encoded)
        assert copy
        assert chroma_similarity(original, copy) > 0.95


def test_chroma_is_identical_to_itself():
    _, words = chroma_fingerprint(FIXTURES / "sweep.wav")
    assert chroma_similarity(words, words) > 0.999


def test_chroma_of_nothing_is_zero():
    assert chroma_similarity([], []) == 0.0


def test_a_recording_under_three_seconds_yields_no_chroma_words(tmp_path):
    path = tmp_path / "brief.wav"
    write_wav(path, frames=8000, rate=8000)
    _, words = chroma_fingerprint(path)
    assert words == []


def test_chroma_rejects_a_missing_file(tmp_path):
    with pytest.raises(UniAudioError):
        chroma_fingerprint(tmp_path / "absent.flac")
