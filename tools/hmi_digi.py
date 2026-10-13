"""HMI SOS "digital MIDI" driver (device 0xA005): drum tracks played as samples from DRUM32.DIG.

HMP tracks routed to 0xA005 play on the Sound Blaster's DSP through this driver, which lives in the SOS
library linked into the games (Earthsiege DBSIM.EXE addresses; GO.EXE and Battledrome carry the same code):
  0x81789  MIDI in.  Note on: sample = kit[note]; volume = (driver volume * velocity >> 7) << 8; at the
           voice limit the oldest sample of the same MIDI channel is stopped first (0x821a7).  Samples whose
           header word +0x24 is 0xffff8000 (every DRUM32.DIG sample) ignore note-offs and re-triggers and
           always play to their end.  No pitch change.
  0x81a2f  cc7 sets ONE volume for the whole driver (all channels) and re-levels playing samples.
  0x81a9d  cc10 sets one pan for the driver (unused here: the music is rendered mono, see render_music).
  0x4f254  DBSIM's driver init: 8 voices, velocity/volume scaling on.
DRUM32.DIG ("HMIDIGIP"): 0x28-byte header, then per sample a 0x74-byte SOS start-sample image
(+0x08 u32 length, +0x14 volume, +0x18 u32 note, +0x24 u32 flags) followed by u8 PCM at 11025 Hz.
"""
import struct

import numpy as np

DEVICE_DIGI = 0xA005
DIG_MAGIC = b'HMIDIGIP'
DIG_HEADER = 0x28
SAMPLE_HEADER = 0x74
SAMPLE_LENGTH = 0x08
SAMPLE_NOTE = 0x18
SAMPLE_FLAGS = 0x24
ONE_SHOT = 0xffff8000               # 0x81827: such samples ignore note-off / re-trigger
SAMPLE_RATE = 11025                 # DBSIM digital driver rate (VA 0x959f0)
MAX_VOICES = 8                      # DBSIM 0x4f254
DEFAULT_VOLUME = 0x7f               # 0xa259c initial driver volume
FULL_SCALE = 0x8000                 # SOS sample volume 0x7fff = full


class DigKit:
    """Drum samples by MIDI note, as float PCM (-1..1) at SAMPLE_RATE."""

    def __init__(self, path):
        d = open(path, 'rb').read()
        if not d.startswith(DIG_MAGIC):
            raise ValueError('not an HMI DIG file: ' + path)
        self.samples, self.one_shot = {}, {}
        p = DIG_HEADER
        while p + SAMPLE_HEADER <= len(d):
            length, = struct.unpack_from('<I', d, p + SAMPLE_LENGTH)
            note, = struct.unpack_from('<I', d, p + SAMPLE_NOTE)
            flags, = struct.unpack_from('<I', d, p + SAMPLE_FLAGS)
            pcm = d[p + SAMPLE_HEADER:p + SAMPLE_HEADER + length]
            self.samples[note] = (np.frombuffer(pcm, np.uint8).astype(np.float32) - 128.0) / 128.0
            self.one_shot[note] = flags == ONE_SHOT
            p += SAMPLE_HEADER + length


class DigiVoice:
    """One playing drum sample: start time, sample, gain changes and an optional stop, in output samples."""

    def __init__(self, start, note, channel, velocity, pcm, gain):
        self.start, self.note, self.channel, self.velocity = start, note, channel, velocity
        self.pcm = pcm
        self.gains = [(start, gain)]
        self.stop = start + len(pcm)

    def playing(self, now):
        return self.start <= now < self.stop


class DigiDriver:
    """0xA005 state machine.  Events arrive with their time in output samples (`at`); `render` mixes."""

    def __init__(self, kit, rate):
        self.kit = kit
        self.upsample = rate / SAMPLE_RATE
        self.volume = DEFAULT_VOLUME
        self.voices = []
        self._resampled = {}

    def send(self, at, status, data1, data2=0):
        kind, channel = status & 0xf0, status & 0x0f
        if kind == 0x90 and data2:
            self.note_on(at, channel, data1, data2)
        elif kind in (0x80, 0x90):
            self.note_off(at, channel, data1)
        elif kind == 0xb0 and data1 == 7:
            self.set_volume(at, data2)
        elif kind == 0xb0 and data1 == 123:
            self.stop_channel(at, channel)

    def note_on(self, at, channel, note, velocity):
        if note not in self.kit.samples:
            return
        if not self.kit.one_shot[note]:
            self._stop(at, lambda v: v.note == note and v.channel == channel)
        if len(self._playing(at)) >= MAX_VOICES:
            self._stop_oldest(at, channel)
        gain = ((self.volume * velocity) >> 7 << 8) / FULL_SCALE
        self.voices.append(DigiVoice(at, note, channel, velocity, self._pcm(note), gain))

    def note_off(self, at, channel, note):
        if note in self.kit.one_shot and not self.kit.one_shot[note]:
            self._stop(at, lambda v: v.note == note and v.channel == channel)

    def set_volume(self, at, value):
        """0x81a2f: re-level every playing sample (value * velocity * 2 in SOS volume units)."""
        self.volume = value
        for v in self._playing(at):
            v.gains.append((at, value * v.velocity * 2 / FULL_SCALE))

    def stop_channel(self, at, channel):
        self._stop(at, lambda v: v.channel == channel)

    def render(self, total):
        out = np.zeros(total, np.float32)
        for v in self.voices:
            end = min(v.stop, total)
            for k, (t0, gain) in enumerate(v.gains):
                t1 = v.gains[k + 1][0] if k + 1 < len(v.gains) else end
                t1 = min(t1, end)
                if t1 > t0:
                    out[t0:t1] += v.pcm[t0 - v.start:t1 - v.start] * gain
        return out

    def _playing(self, at):
        return [v for v in self.voices if v.playing(at)]

    def _stop(self, at, match):
        for v in self._playing(at):
            if match(v):
                v.stop = at

    def _stop_oldest(self, at, channel):
        same = [v for v in self._playing(at) if v.channel == channel]
        if same:
            same[0].stop = at

    def _pcm(self, note):
        """Upsampled from 11025 Hz by linear interpolation (the DSP's analogue output filter smooths)."""
        if note not in self._resampled:
            x = self.kit.samples[note]
            n = int(len(x) * self.upsample)
            self._resampled[note] = np.interp(np.arange(n) / self.upsample, np.arange(len(x)), x).astype(np.float32)
        return self._resampled[note]
