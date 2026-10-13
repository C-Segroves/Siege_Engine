"""HMI music emulation: driver arithmetic, voice limits and stealing, deterministic renders, seamless loops.

    python -m pytest tools/tests/test_render_music.py
The synthetic tests need nothing; the render tests use the user's Earthsiege / Battledrome files
(skipped when they are not unpacked).  No audio is played.
"""
import hashlib
import os
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import siege_paths as P  # noqa: E402
import hmi_digi  # noqa: E402
import hmi_fm  # noqa: E402
import hmi_song  # noqa: E402

ES1_MENU = P.work('extracted', 'SHELL0', 'RES32', 'MENU.HMP')
ES1_DRIVER = P.work('original', 'SOS', 'HMIMDRV.386')
BD_SONG = P.work('bd', 'installed', 'SOUND', 'ROCK3.HMP')
needs_es1 = pytest.mark.skipif(not (os.path.exists(ES1_MENU) and os.path.exists(ES1_DRIVER)), reason='Earthsiege not unpacked')
needs_bd = pytest.mark.skipif(not os.path.exists(BD_SONG), reason='Battledrome not unpacked')


# ------------------------------------------------------------------ synthetic driver

class FakeImage:
    """Tables shaped like the driver's (made-up values): fnum = 0x200 + note, block 4."""
    scales_additive_modulator = False

    def velocity_curve(self):
        return bytes(63 - min(63, i) for i in range(64))

    def voice_slots(self):
        return [(0, 3), (1, 4), (2, 5), (8, 11), (9, 12), (10, 13), (16, 19), (17, 20), (18, 21)]

    def default_bend_ranges(self):
        return [2] * 16

    def bends_at_note_on(self):
        return True

    def u32(self, offset):
        return (4 << 10) | (0x200 + (offset // 4) % 0x100)


class FakeBank:
    def record(self, index):
        return bytes(30)

    def drum_pitch(self, note):
        return 60


class KeyChip:
    """Counts keyed-on voices from the B0 writes."""

    def __init__(self):
        self.keyed = set()
        self.peak = 0

    def write(self, register, value):
        if 0xb0 <= register <= 0xb8:
            (self.keyed.add if value & 0x20 else self.keyed.discard)(register - 0xb0)
            self.peak = max(self.peak, len(self.keyed))


def make_driver():
    chip = KeyChip()
    return hmi_fm.FmDriver(FakeImage(), FakeBank(), FakeBank(), chip), chip


def test_scaled_level_multiplies_amplitudes():
    assert hmi_fm.scaled_level(0, 0) == 0
    assert hmi_fm.scaled_level(0, 40) == 40          # full velocity keeps the patch level
    assert hmi_fm.scaled_level(63, 0) == 63
    assert hmi_fm.scaled_level(32, 32) == 48         # 64 - 32*32/64


def test_pack_record_builds_register_bytes():
    d = bytearray(30)
    d[2:15] = bytes((1, 3, 5, 15, 7, 1, 2, 4, 20, 1, 0, 1, 1))     # ksl mult fb ar sl eg dr rr tl am vib ksr con
    hmi_fm.pack_record(d, 0)
    assert d[hmi_fm.PATCH_MOD_CHAR] == 0x80 | 0x20 | 0x10 | 3
    assert d[hmi_fm.PATCH_MOD_LEVEL] == (1 << 6) | 20
    assert d[hmi_fm.PATCH_CONNECTION] == 5 * 2 | 1


def test_nine_voices_at_most_and_lowest_channel_is_stolen():
    fm, chip = make_driver()
    for i in range(9):
        fm.note_on(3 + i % 2, 60 + i, 100)
    assert chip.peak == 9
    fm.note_on(5, 80, 100)                            # all busy: steal channel 3's lowest voice (0)
    assert chip.peak == 9
    assert fm.voice_channel[0] == 5 and fm.voice_note[0] == 80


def test_pitch_bent_channels_keep_their_voices():
    fm, _ = make_driver()
    for i in range(9):
        fm.note_on(2 if i < 8 else 4, 60 + i, 100)
    fm.pitch_bend(2, 70)
    fm.note_on(6, 50, 100)                            # channel 2 is protected -> channel 4's voice 8
    assert fm.voice_channel[8] == 6


def test_sustain_holds_note_offs_until_release():
    fm, chip = make_driver()
    fm.controller(0, hmi_fm.CC_SUSTAIN, 127)
    fm.note_on(0, 60, 100)
    fm.note_off(0, 60)
    assert 0 in chip.keyed
    fm.controller(0, hmi_fm.CC_SUSTAIN, 0)
    assert 0 not in chip.keyed


def test_centred_bend_keeps_the_note_frequency():
    fm, _ = make_driver()
    fm.note_on(0, 60, 100)
    assert fm.bent_frequency(64, 60, 0) == FakeImage().u32(hmi_fm.BEND_FNUM + 4 * 48)


def test_digital_drums_never_exceed_eight_voices_per_channel_steal():
    kit = hmi_digi.DigKit.__new__(hmi_digi.DigKit)
    kit.samples = {36: np.ones(11025, np.float32)}
    kit.one_shot = {36: True}
    digi = hmi_digi.DigiDriver(kit, 44100)
    for i in range(12):
        digi.note_on(i * 10, 9, 36, 100)
    assert max(len(digi._playing(t)) for t in range(0, 200)) <= hmi_digi.MAX_VOICES


# ------------------------------------------------------------------ the user's files

@needs_es1
def test_driver_image_tables_are_found():
    image = hmi_fm.FmDriverImage(ES1_DRIVER)
    assert not image.scales_additive_modulator           # the Earthsiege build
    assert image.default_bend_ranges() == [2] * 16
    assert image.u32(hmi_fm.BEND_FNUM) & 0x3ff == image.u32(hmi_fm.NOTE_ON_FNUM + 4 * 12) & 0x3ff
    assert [s for s in image.voice_slots()][3] == (8, 11)


@needs_es1
def test_loop_branch_points_come_from_the_branch_table():
    song = hmi_song.HmpSong(ES1_MENU)
    play = hmi_song.Playback(song, max_jumps=2)
    list(play.events())
    assert len(play.jumps) == 3 and play.jumps[1] - play.jumps[0] == play.jumps[2] - play.jumps[1]


def _render(path, game, variant):
    import render_music
    import music_games
    return render_music.render_song(path, music_games.GAMES[game], variant)


@needs_es1
def test_render_is_deterministic_seamless_and_within_voice_limits():
    import render_music
    a, meta = _render(ES1_MENU, 'es1', 'sb')
    b, _ = _render(ES1_MENU, 'es1', 'sb')
    assert hashlib.sha1(render_music.pcm16(a).tobytes()).digest() == hashlib.sha1(render_music.pcm16(b).tobytes()).digest()
    assert meta['max_voices'] <= hmi_fm.VOICES and meta['dropped_notes'] == 0
    assert meta['loop'] and meta['seam_error_db'] < -100        # the next pass repeats the loop pass sample for sample
    assert meta['digi_tracks'] == [2, 5]


@needs_es1
def test_adlib_variant_drops_the_digital_drum_tracks():
    _, meta = _render(ES1_MENU, 'es1', 'adlib')
    assert meta['digi_tracks'] == [] and meta['fm_tracks'] == [1, 3, 4, 6, 7]


@needs_bd
def test_battledrome_song_plays_once_with_its_bend_range():
    song = hmi_song.HmpSong(BD_SONG)
    sent = [e for e in hmi_song.Playback(song, 0).events() if e[2] & 0xf0 == 0xb0 and e[3] == hmi_fm.CC_BEND_RANGE]
    assert {e[4] for e in sent} == {2, 12}               # cc102 reaches the FM driver
    mono, meta = _render(BD_SONG, 'bd', 'sb')
    assert not meta['loop'] and len(mono) > 0


# ------------------------------------------------------------------ digital samples, callback tracks, voices

BD_SOUND = P.work('bd', 'installed', 'SOUND')
BD_TECHNO2 = os.path.join(BD_SOUND, 'TECHNO2.HMP')
BD_TECHNO2_OGG = P.pack('bd', 'audio', 'music', 'sb', 'techno2.ogg')
ES1_SONGS = [P.work('extracted', 'SIMSOUND', 'HMI', 'BATTLE1A.HMP'), P.work('extracted', 'SHELL0', 'RES32', 'SHELLA.HMP')]
DEVICE_CALLBACK = 0xA003
VOCAL_STABS = (30, 33, 48)                 # DRUM32.DIG samples that are speech (spectrogram analysis)
SAMPLE_GAIN_TOLERANCE = 0.03


@needs_bd
def test_battledrome_loads_drum32_dig_and_drum_dig_holds_the_same_samples():
    for exe in ('SIM.EXE', 'SHELL.EXE'):
        data = open(P.work('bd', 'installed', exe), 'rb').read()
        assert b'drum32.dig' in data and b'drum.dig' not in data
    a = hmi_digi.DigKit(os.path.join(BD_SOUND, 'DRUM.DIG'))
    b = hmi_digi.DigKit(os.path.join(BD_SOUND, 'DRUM32.DIG'))
    assert sorted(a.samples) == sorted(b.samples) and all(np.array_equal(a.samples[n], b.samples[n]) for n in a.samples)
    assert set(VOCAL_STABS) <= set(b.samples)


@needs_bd
def test_no_battledrome_song_has_a_callback_track():
    import glob
    for path in glob.glob(os.path.join(BD_SOUND, '*.HMP')):
        assert all(DEVICE_CALLBACK not in t.devices for t in hmi_song.HmpSong(path).tracks), path


@needs_es1
def test_earthsiege_callback_tracks_reach_no_driver():
    """The games load only the MIDI driver and 0xA005 (DBSIM 0x4f06f / 0x4f2c4): 0xA003 tracks stay silent."""
    import render_music
    for path in ES1_SONGS:
        song = hmi_song.HmpSong(path)
        callback = [t for t in song.tracks if DEVICE_CALLBACK in t.devices]
        assert callback and all(song.driver_for(t, render_music.VARIANTS['sb']['drivers']) is None for t in callback)


@pytest.mark.skipif(not (os.path.exists(BD_TECHNO2) and os.path.exists(BD_TECHNO2_OGG)), reason='Battledrome music not rendered')
def test_sound_blaster_render_carries_the_vocal_stabs_at_full_level():
    """TECHNO2's 0xA005 track (vocal stab 30 every ~7 s) projected on the shipped render: the master gain."""
    import music_games
    import render_music as R
    game = music_games.GAMES['bd']
    kit = hmi_digi.DigKit(os.path.join(BD_SOUND, 'DRUM32.DIG'))
    song = hmi_song.HmpSong(BD_TECHNO2)
    events, jumps = R.schedule(song, game.policy('techno2', False))
    timeline = R.Timeline(song.ticks_per_second, jumps)
    routes = {t.index: song.driver_for(t, R.VARIANTS['sb']['drivers']) for t in song.tracks}
    digi = hmi_digi.DigiDriver(kit, R.RATE)
    stabs = 0
    for tick, track, status, d1, d2 in events:
        if routes.get(track) != hmi_digi.DEVICE_DIGI:
            continue
        if status & 0xf0 == 0xb0 and d1 == hmi_song.CC_VOLUME:
            d2 = hmi_song.scale_volume(d2)
        stabs += status & 0xf0 == 0x90 and d2 > 0 and d1 in VOCAL_STABS
        digi.send(timeline.sample(tick), status, d1, d2)
    shipped = R.decode(BD_TECHNO2_OGG)
    solo = R.highpass1(digi.render(len(shipped)), R.DC_BLOCK_HZ / (R.RATE / 2))
    gain = float(np.dot(shipped, solo) / np.dot(solo, solo))
    assert stabs >= 10
    assert abs(gain - R.MASTER_GAIN) < SAMPLE_GAIN_TOLERANCE


@needs_bd
def test_end_of_round_announcer_and_shield_warning_are_decoded():
    import bd_hud
    import bd_voices
    v = bd_voices.make_voices(bd_hud.load_image())
    e = v['end_of_round']
    assert e['voices'] == ['endrnd1', 'arean01'] and (e['winner_voice'], e['loser_voice']) == ('arean11', 'arean12')
    assert e['delays_s'] == [2.048, 2.048, 3.072]
    assert v['shield_warning']['depleted_max'] == 25 and v['shield_warning']['low_max'] == 63
    assert v['message_spacing_s'] == 2.048
    assert [m['voice'] for m in v['messages'][:3]] == ['sher05', 'sher04', 'sher03']
