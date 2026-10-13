"""Emulation of the HMI SOS FM MIDI driver that Earthsiege and Battledrome play their music through.

The only FM choice in both games' sound setup (STUFF/SOUNDSET.INI, "drv01=FM: a002") is device 0xA002,
`fmmidi.com` inside SOS/HMIMDRV.386 ("HMI MIDI Driver For OPL2", Copyright 1994).  The OPL3 driver
`fmmidi3.com` (0xA009) is in the same file but never offered, so a Sound Blaster 16 ran this OPL2 driver on
its OPL3 chip in OPL2-compatible mode.  Every behaviour below was decoded from the driver code; addresses
are offsets in the Earthsiege build of fmmidi.com (code starts at HMIMDRV.386 file offset 0x5c).

  0x080c  MIDI dispatch: 0x9n vel>0 -> note on (0xf4c); 0x8n and 0x9n vel 0 -> note off (0x143c);
          0xBn -> controller (0x174a); 0xCn -> program (0x16fd); 0xEn -> pitch bend (0x18bf, data MSB only)
  0x1dde  voice allocation over the 9 OPL2 voices (see FmDriver._allocate_voice)
  0x0f4c  note on: key off the voice, damp it, load the patch (0x1f25), carrier total level from velocity x
          channel volume (curve table 0x2d9c), frequency from table 0x2db8, then the channel's pitch bend
  0x1981  pitch bend -> F-number interpolation between table notes (range = cc102, default 2 semitones)
  0x0d21  bank conversion at load: AdLib BNK records -> OPL register bytes, in place
The Battledrome build (bd/installed/SOUND/HMIMDRV.386) is identical except that it scales an additive
(con = 1) patch's modulator by velocity with the modulator's own level; the Earthsiege build instead
rescales the modulator of patches whose packed feedback/connection byte is 0, using the carrier's level.

The driver's data tables are read from the user's own HMIMDRV.386 at render time (nothing is copied here).
"""
import struct

DEVICE_FM_OPL2 = 0xA002
DRIVER_NAME = b'fmmidi.com\x00'
ENTRY_NAME_OFFSET = 0x0c            # driver entry: {u32, u32 0x2c, u32 checksum, char name[...]} ...
ENTRY_CODE_SIZE = 0x30              # ... u32 total size, u32 code size, u32 device id ...
ENTRY_DEVICE_ID = 0x34
ENTRY_CODE = 0x3c                   # ... then the code image (offset 0 = entry jump)

# Data tables are found by the velocity curve signature; offsets relative to it (Earthsiege address).
VELOCITY_CURVE_SIGNATURE = bytes((0x3f, 0x3a, 0x35, 0x30, 0x2c, 0x29, 0x25, 0x24, 0x23, 0x22, 0x21, 0x20))
VELOCITY_CURVE_LENGTH = 64          # 0x2d9c: attenuation 0..63 by velocity/2
NOTE_ON_FNUM = 0x1c                 # 0x2db8: u32 block<<10|fnum per MIDI note (note 12 = first real entry)
BEND_FNUM = 0x4c                    # 0x2de8: the same table indexed by note-12 (bend code)
BEND_WRAP_DOWN = 0x1e4              # 0x2f80: u32 per bend range, fnum used when a downward bend leaves the block
BEND_WRAP_UP = 0x1e8                # 0x2f84: u32 per semitone (11 - n), fnum of the note one block higher
VOICE_SLOTS = -0x1b                 # 0x2d81: (modulator, carrier) operator offsets per voice
BEND_RANGE_DEFAULTS = -0x834        # 0x2568: u32[16] initial pitch-bend range (2 semitones)
BEND_AT_NOTE_ON = -0x91c            # 0x2480: u32, non-zero = apply a channel's bend to new notes
MODULATOR_FIX_CODE = b'\x65\xf6\x40\x0e\x01'   # 'test byte gs:[eax+0xe], 1' (Battledrome build only)

VOICES = 9
CHANNELS = 16
DRUM_CHANNEL = 9
VOICE_FREE = 0                      # voice note byte 0x2d70 = 0 -> voice is free
MAX_LEVEL = 0x3f
KEY_ON = 0x20
DAMP_RELEASE = 0x0f                 # release rate written (5x) before a voice is re-used (0x0fab)
DAMP_REPEATS = 5
SUSTAIN_QUEUE_LIMIT = 32            # held note-offs per channel (0x149a)
BEND_CENTRE = 64
BEND_SCALE = 1000                   # 0x19da: per-mille interpolation
BEND_WRAP_LIMIT = 0x2cf             # 0x1a0d: a larger step means the target note is in another block
DEFAULT_PROGRAM = 0
DEFAULT_VOLUME = 127
DEFAULT_BEND_RANGE = 2              # cc121 restores this (0x16cc)

CC_VOLUME = 7
CC_SUSTAIN = 64
CC_BEND_RANGE = 102                 # HMI controller: pitch-bend range in semitones (0x187e)
CC_RESET_CONTROLLERS = 121
CC_ALL_NOTES_OFF = 123

# Packed patch record (after conversion 0x0d21; offsets into the 30-byte BNK record).
PATCH_MOD_CHAR = 0x0b               # 0x20 am/vib/eg/ksr/mult
PATCH_MOD_LEVEL = 0x02              # 0x40 ksl/tl
PATCH_MOD_ATTACK = 0x05             # 0x60 ar/dr
PATCH_MOD_SUSTAIN = 0x06            # 0x80 sl/rr
PATCH_CONNECTION = 0x0e             # 0xC0 fb<<1 | con
PATCH_CAR_CHAR = 0x18
PATCH_CAR_LEVEL = 0x0f
PATCH_CAR_ATTACK = 0x12
PATCH_CAR_SUSTAIN = 0x13
PATCH_MOD_WAVE = 0x1c
PATCH_CAR_WAVE = 0x1d
BNK_RECORD = 30
BNK_NAME = 12
BNK_NAME_NOTE = 2                   # DRUM.BNK name entry byte 2 = the note the drum sounds at (0x13ed)


class FmDriverImage:
    """fmmidi.com code + data as loaded from HMIMDRV.386."""

    def __init__(self, path):
        data = open(path, 'rb').read()
        name = data.find(DRIVER_NAME)
        if name < 0:
            raise ValueError('%s: no fmmidi.com driver' % path)
        entry = name - ENTRY_NAME_OFFSET
        size, device = struct.unpack_from('<II', data, entry + ENTRY_CODE_SIZE)
        if device != DEVICE_FM_OPL2:
            raise ValueError('%s: fmmidi.com device %#x, expected %#x' % (path, device, DEVICE_FM_OPL2))
        self.code = data[entry + ENTRY_CODE:entry + ENTRY_CODE + size]
        self.base = self.code.find(VELOCITY_CURVE_SIGNATURE)
        if self.base < 0:
            raise ValueError('%s: velocity table not found' % path)
        self.scales_additive_modulator = MODULATOR_FIX_CODE in self.code

    def u32(self, offset):
        """u32 at `offset` relative to the velocity table (the driver also reads outside its tables)."""
        p = self.base + offset
        if 0 <= p and p + 4 <= len(self.code):
            return struct.unpack_from('<I', self.code, p)[0]
        return 0

    def velocity_curve(self):
        return self.code[self.base:self.base + VELOCITY_CURVE_LENGTH]

    def voice_slots(self):
        p = self.base + VOICE_SLOTS
        return [(self.code[p + 2 * v], self.code[p + 2 * v + 1]) for v in range(VOICES)]

    def default_bend_ranges(self):
        return [self.u32(BEND_RANGE_DEFAULTS + 4 * c) for c in range(CHANNELS)]

    def bends_at_note_on(self):
        return self.u32(BEND_AT_NOTE_ON) != 0


class FmBank:
    """An HMI AdLib-format bank (MELODIC.BNK / DRUM.BNK) as the driver holds it after loading.

    0x0d21 packs the first `used - 2` records into register bytes in place; the last two keep their raw
    bytes (and are read as if packed).  Records are indexed directly by program / drum note."""

    def __init__(self, path):
        data = bytearray(open(path, 'rb').read())
        if data[2:8] != b'ADLIB-':
            raise ValueError('not an AdLib BNK: ' + path)
        used, count, self.name_ofs, self.data_ofs = struct.unpack_from('<HHII', data, 8)
        for i in range(max(0, used - 2)):
            pack_record(data, self.data_ofs + i * BNK_RECORD)
        self.data = bytes(data)

    def record(self, index):
        p = self.data_ofs + (index & 0xff) * BNK_RECORD
        return self.data[p:p + BNK_RECORD]

    def drum_pitch(self, note):
        return self.data[self.name_ofs + (note & 0xff) * BNK_NAME + BNK_NAME_NOTE]


def pack_record(d, p):
    """0x0d21: BNK operator fields (ksl, mult, fb, ar, sl, eg, dr, rr, tl, am, vib, ksr, con) -> OPL bytes."""
    d[p + PATCH_MOD_CHAR] = (d[p + 11] << 7 | d[p + 12] << 6 | d[p + 7] << 5 | d[p + 13] << 4 | d[p + 3]) & 0xff
    d[p + PATCH_MOD_LEVEL] = (d[p + 2] << 6 | d[p + 10]) & 0xff
    d[p + PATCH_MOD_ATTACK] = (d[p + 5] << 4 | d[p + 8]) & 0xff
    d[p + PATCH_MOD_SUSTAIN] = (d[p + 6] << 4 | d[p + 9]) & 0xff
    d[p + PATCH_CONNECTION] = (d[p + 4] * 2 | d[p + 14]) & 0xff
    d[p + PATCH_CAR_CHAR] = (d[p + 24] << 7 | d[p + 25] << 6 | d[p + 20] << 5 | d[p + 26] << 4 | d[p + 16]) & 0xff
    d[p + PATCH_CAR_LEVEL] = (d[p + 15] << 6 | d[p + 23]) & 0xff
    d[p + PATCH_CAR_ATTACK] = (d[p + 18] << 4 | d[p + 21]) & 0xff
    d[p + PATCH_CAR_SUSTAIN] = (d[p + 19] << 4 | d[p + 22]) & 0xff


def scaled_level(attenuation, level):
    """0x10ca: total level for a patch level and a velocity attenuation (both 0..63, 63 = silent):
    amplitudes multiply, 64 - (64 - a)(64 - l)/64."""
    return (0x2000 - 2 * (64 - attenuation) * (64 - level)) >> 7


class FmDriver:
    """fmmidi.com state machine.  `chip.write(register, value)` receives the OPL register writes."""

    def __init__(self, image, melodic, drums, chip):
        self.image, self.melodic, self.drums, self.chip = image, melodic, drums, chip
        self.curve = image.velocity_curve()
        self.slots = image.voice_slots()
        self.bend_at_note_on = image.bends_at_note_on()
        self.voice_note = [VOICE_FREE] * VOICES        # 0x2d70
        self.voice_channel = [0] * VOICES               # 0x24c4
        self.voice_velocity = [DEFAULT_VOLUME] * CHANNELS   # 0x25ec (indexed by voice, reset by channel)
        self.program = [DEFAULT_PROGRAM] * CHANNELS     # 0x2484
        self.volume = [DEFAULT_VOLUME] * CHANNELS       # 0x25ac
        self.bend = [BEND_CENTRE] * CHANNELS            # 0x24e8
        self.bent = [False] * CHANNELS                  # 0x2528: channel has received a pitch bend
        self.bend_range = image.default_bend_ranges()   # 0x2568
        self.sustain = [0] * CHANNELS                   # 0x2650
        self.held = [[] for _ in range(CHANNELS)]       # 0x26ec: note-offs held by the sustain pedal
        self.level_shadow = [0] * 0x20                  # 0x2d10: 0x40 register per operator
        self.release_shadow = [0] * 0x20                # 0x2d30: 0x80 register per operator
        self.block_shadow = [0] * VOICES                # 0x2d49: 0xB0 register per voice
        self.dropped_notes = 0
        self.peak_voices = 0                            # most voices keyed at once (diagnostics)
        self._reset_chip()

    # ------------------------------------------------------------------ MIDI in

    def send(self, status, data1, data2=0):
        kind, channel = status & 0xf0, status & 0x0f
        if kind == 0x90 and data2:
            self.note_on(channel, data1, data2)
        elif kind in (0x80, 0x90):
            self.note_off(channel, data1)
        elif kind == 0xb0:
            self.controller(channel, data1, data2)
        elif kind == 0xc0:
            self.program[channel] = data1
        elif kind == 0xe0:
            self.pitch_bend(channel, data2)

    def note_on(self, channel, note, velocity):
        voice = self._allocate_voice(channel, note)
        if voice is None:
            self.dropped_notes += 1
            return
        self._key_off(voice)
        self.voice_channel[voice] = channel
        self._damp(voice)
        if channel == DRUM_CHANNEL:
            self._start_drum(voice, note, velocity)
        else:
            self._start_melodic(voice, channel, note, velocity)
        self.peak_voices = max(self.peak_voices, sum(1 for n in self.voice_note if n != VOICE_FREE))

    def note_off(self, channel, note):
        if self.sustain[channel] and len(self.held[channel]) < SUSTAIN_QUEUE_LIMIT:
            self.held[channel].append(note)
            return
        for v in range(VOICES):
            if self.voice_note[v] == note and self.voice_channel[v] == channel:
                self._key_off(v)

    def controller(self, channel, number, value):
        if number == CC_VOLUME:
            self._set_volume(channel, value)
        elif number == CC_SUSTAIN:
            self._set_sustain(channel, value)
        elif number == CC_BEND_RANGE:
            self.bend_range[channel] = value
        elif number == CC_RESET_CONTROLLERS:
            self._reset_controllers(channel)
        elif number == CC_ALL_NOTES_OFF:
            self._all_notes_off(channel)

    def pitch_bend(self, channel, msb):
        """0x18bf: only the MSB is used; the drum channel ignores bends."""
        if channel == DRUM_CHANNEL:
            return
        self.bend[channel] = msb
        self.bent[channel] = True
        for v in range(VOICES):
            if self.voice_note[v] != VOICE_FREE and self.voice_channel[v] == channel:
                self._write_frequency(v, self.bent_frequency(msb, self.voice_note[v], v))

    # ------------------------------------------------------------------ voices

    def _allocate_voice(self, channel, note):
        """0x1dde: the lowest free voice; else the lowest voice of the lowest-numbered channel that has never
        been pitch-bent; else voice = note (minus 9 once) -- out of range for notes >= 18 (dropped here; the
        original would write past its register tables)."""
        for v in range(VOICES):
            if self.voice_note[v] == VOICE_FREE:
                return v
        for c in range(CHANNELS):
            if not self.bent[c]:
                for v in range(VOICES):
                    if self.voice_channel[v] == c:
                        return v
        v = note - VOICES if note >= VOICES else note
        return v if v < VOICES else None

    def _key_off(self, voice):
        """0x1ea5"""
        if self.voice_note[voice] == VOICE_FREE:
            return
        self.block_shadow[voice] &= ~KEY_ON & 0xff
        self._write(0xb0 + voice, self.block_shadow[voice])
        self.voice_note[voice] = VOICE_FREE

    def _damp(self, voice):
        """0x0fab: fastest release on both operators before the new patch is written."""
        mod, car = self.slots[voice]
        for _ in range(DAMP_REPEATS):
            self._write(0x80 + car, self.release_shadow[car] | DAMP_RELEASE)
            self._write(0x80 + mod, self.release_shadow[mod] | DAMP_RELEASE)

    def _start_melodic(self, voice, channel, note, velocity):
        patch = self.melodic.record(self.program[channel])
        self._load_patch(voice, patch)
        self.voice_velocity[voice] = velocity
        self._apply_level(voice, channel, self._attenuation(channel, velocity))
        self._key_on(voice, self.image.u32(NOTE_ON_FNUM + 4 * note), note)
        if self.bend_at_note_on and self.bent[channel]:
            self._write_frequency(voice, self.bent_frequency(self.bend[channel], note, voice))

    def _start_drum(self, voice, note, velocity):
        """0x120f: the drum patch is indexed by note and sounds at the bank's fixed pitch; no bend."""
        self._load_patch(voice, self.drums.record(note))
        self.voice_velocity[voice] = velocity
        self._apply_level(voice, DRUM_CHANNEL, self._attenuation(DRUM_CHANNEL, velocity), drum=True)
        self._key_on(voice, self.image.u32(NOTE_ON_FNUM + 4 * self.drums.drum_pitch(note)), note)

    def _load_patch(self, voice, patch):
        """0x1f25: the carrier level is only shadowed (written by the velocity code)."""
        mod, car = self.slots[voice]
        self.release_shadow[car] = patch[PATCH_CAR_SUSTAIN]
        self.release_shadow[mod] = patch[PATCH_MOD_SUSTAIN]
        self._write(0x20 + mod, patch[PATCH_MOD_CHAR])
        self._write(0x40 + mod, patch[PATCH_MOD_LEVEL])
        self.level_shadow[mod] = patch[PATCH_MOD_LEVEL]
        self._write(0x60 + mod, patch[PATCH_MOD_ATTACK])
        self._write(0x80 + mod, patch[PATCH_MOD_SUSTAIN])
        self._write(0xc0 + voice, patch[PATCH_CONNECTION])
        self._write(0xe0 + mod, patch[PATCH_MOD_WAVE])
        self._write(0x20 + car, patch[PATCH_CAR_CHAR])
        self.level_shadow[car] = patch[PATCH_CAR_LEVEL]
        self._write(0x60 + car, patch[PATCH_CAR_ATTACK])
        self._write(0x80 + car, patch[PATCH_CAR_SUSTAIN])
        self._write(0xe0 + car, patch[PATCH_CAR_WAVE])

    def _key_on(self, voice, frequency, note):
        """0x212e: A0, B0 without key, B0 with key."""
        self.block_shadow[voice] = ((frequency >> 8) | KEY_ON) & 0xff
        self._write(0xa0 + voice, frequency & 0xff)
        self._write(0xb0 + voice, self.block_shadow[voice] & ~KEY_ON & 0xff)
        self._write(0xb0 + voice, self.block_shadow[voice])
        self.voice_note[voice] = note

    def _write_frequency(self, voice, frequency):
        """0x21f0"""
        self.block_shadow[voice] = ((frequency >> 8) | KEY_ON) & 0xff
        self._write(0xa0 + voice, frequency & 0xff)
        self._write(0xb0 + voice, self.block_shadow[voice])

    # ------------------------------------------------------------------ levels

    def _attenuation(self, channel, velocity):
        """0x1068: velocity scaled by channel volume, then the driver's curve (index velocity/2)."""
        scaled = (velocity * ((self.volume[channel] << 7) // 127)) >> 7
        return self.curve[(scaled & 0xff) >> 1]

    def _apply_level(self, voice, channel, attenuation, drum=False):
        mod, car = self.slots[voice]
        if self._scales_modulator(channel, drum):
            reference = mod if self.image.scales_additive_modulator else car
            level = scaled_level(attenuation, self.level_shadow[reference] & MAX_LEVEL)
            self._write(0x40 + mod, (self.level_shadow[mod] & 0xc0) | (level & 0xff))
        level = scaled_level(attenuation, self.level_shadow[car] & MAX_LEVEL)
        self._write(0x40 + car, (self.level_shadow[car] & 0xc0) | (level & 0xff))

    def _scales_modulator(self, channel, drum):
        """Earthsiege (0x111c): melodic notes only, when the channel patch's packed C0 byte is 0.
        Battledrome: when that patch is additive -- for drums too, testing the melodic patch of
        program[9] instead of the drum patch (as the code does)."""
        connection = self.melodic.record(self.program[channel])[PATCH_CONNECTION]
        if self.image.scales_additive_modulator:
            return bool(connection & 1)
        return not drum and connection == 0

    def _set_volume(self, channel, value):
        """0x2286: re-level the channel's sounding voices with their note-on velocity."""
        self.volume[channel] = value
        for v in range(VOICES):
            if self.voice_note[v] != VOICE_FREE and self.voice_channel[v] == channel:
                scaled = (((value << 7) // 127) * self.voice_velocity[v]) >> 7
                self._apply_level(v, channel, self.curve[(scaled & 0xff) >> 1])

    def _set_sustain(self, channel, value):
        """0x17f5: any non-zero value holds; releasing replays the held note-offs newest first."""
        self.sustain[channel] = value
        if value:
            return
        held = self.held[channel]
        while held:
            self.note_off(channel, held.pop())

    def _reset_controllers(self, channel):
        """0x1653 (cc121).  Writes the per-voice velocity array at the channel index, as the code does."""
        self.volume[channel] = DEFAULT_VOLUME
        self.voice_velocity[channel] = DEFAULT_VOLUME
        self.sustain[channel] = 0
        self.bend[channel] = BEND_CENTRE
        self.bend_range[channel] = DEFAULT_BEND_RANGE

    def _all_notes_off(self, channel):
        """0x15aa (cc123): also restores full channel volume."""
        self.volume[channel] = DEFAULT_VOLUME
        self.voice_velocity[channel] = DEFAULT_VOLUME
        self.sustain[channel] = 0
        for v in range(VOICES):
            if self.voice_channel[v] == channel:
                self._key_off(v)

    # ------------------------------------------------------------------ pitch bend

    def bent_frequency(self, bend, note, voice):
        """0x1981: F-number for `note` bent by `bend` (MSB 0..127), interpolated in per-mille steps towards the
        note `range` semitones away; crossing a block boundary uses the driver's wrap tables."""
        n = note - 12
        semitone = n % 12
        rng = self.bend_range[self.voice_channel[voice]]
        f = self._bend_table(n)
        if bend < BEND_CENTRE:
            scale = ((63 - bend) * BEND_SCALE) >> 6
            step = (f - self._bend_table(n - rng)) & 0xffffffff
            if step > BEND_WRAP_LIMIT:
                step = ((f & 0x3ff) - self.image.u32(BEND_WRAP_DOWN + 4 * rng)) & 0x3ff
            return (f - ((step * scale) & 0xffffffff) // BEND_SCALE) & 0xffffffff
        scale = ((bend - BEND_CENTRE) * BEND_SCALE) >> 6
        target = self._bend_table(n + rng)
        step = (target - f) & 0xffffffff
        if step > BEND_WRAP_LIMIT:
            f = ((f & 0x1c00) + 0x400) | self.image.u32(BEND_WRAP_UP + 4 * (11 - semitone))
            step = (target - f) & 0xffffffff
        return (f + ((step * scale) & 0xffffffff) // BEND_SCALE) & 0xffffffff

    def _bend_table(self, index):
        return self.image.u32(BEND_FNUM + 4 * index)

    # ------------------------------------------------------------------ chip

    def _reset_chip(self):
        """0x1b39 / 0x1bb8: waveform select on, all voices keyed off, melodic mode."""
        self._write(0x01, 0x20)
        for v in range(VOICES):
            self._write(0xb0 + v, 0)
        self._write(0xbd, 0)

    def _write(self, register, value):
        self.chip.write(register, value & 0xff)
