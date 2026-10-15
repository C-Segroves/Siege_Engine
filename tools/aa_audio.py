"""Aerial Assault audio banks (TRIBES/DATA/AUDIO/*.PKG, magic "inevaud"): PS2 SPU-ADPCM (VAG) sounds.

Layout (found by inspection): a 0x6000-byte header of sound records, then the samples, each starting on a 0x2000 boundary
and made of 16-byte ADPCM blocks (shift | predictor << 4, flag, 14 data bytes = 28 nibbles, low nibble first); flag bit 0
marks the last block. The header also holds one 0x48-byte record per sound (see records(): rate, size, offset from the data base at 0x18); the
rates are 22050 Hz almost everywhere (11025 and 17640 occur in EFFECTS/VOICE). MUSIC is 6 mono 22050 Hz tracks of about 8
minutes (checked: split channels decode worse than mono). The sound NAMES are not in the bank (the mission logic that names them is in the ELF): sounds are numbered by position.
"""
import struct

import numpy as np

HEADER = 0x6000
ALIGN = 0x2000
RATE = 22050
FILTERS = ((0, 0), (60, 0), (115, -52), (98, -55), (122, -60))
MAGIC = b'inevaud'


def decode_vag(data):
    """ADPCM blocks -> int16 samples (stops after the block with the end flag)."""
    n = len(data) // 16
    raw = np.frombuffer(data, np.uint8, n * 16).reshape(n, 16)
    ends = np.nonzero(raw[:, 1] & 1)[0]
    if len(ends):
        n = int(ends[0]) + 1
        raw = raw[:n]
    body = raw[:, 2:]
    nib = np.empty((n, 28), np.int32)
    nib[:, 0::2] = body & 15
    nib[:, 1::2] = body >> 4
    nib = np.where(nib > 7, nib - 16, nib)
    shifts = np.minimum(raw[:, 0] & 15, 12).astype(np.int32)
    vals = ((nib << 12) >> shifts[:, None]).tolist()
    preds = (raw[:, 0] >> 4).tolist()
    out = []
    append = out.append
    s1 = s2 = 0
    for k in range(n):
        f0, f1 = FILTERS[min(preds[k], 4)]
        for v in vals[k]:
            s = v + ((s1 * f0 + s2 * f1) >> 6)
            s = -32768 if s < -32768 else 32767 if s > 32767 else s
            append(s)
            s2, s1 = s1, s
    return np.array(out, '<i2')


def split(data):
    """[(offset, length in bytes)] of the samples: aligned starts after the header, each ending at its end-flag block."""
    if data[:7] != MAGIC:
        raise ValueError('not an inevaud bank')
    found = []
    pos = HEADER
    while pos + 16 <= len(data):
        p = pos
        ok = data[p] >> 4 <= 4 and data[p + 1] in (0, 2, 4, 6, 1, 3, 7)
        end = None
        if ok:
            q = p
            while q + 16 <= len(data):
                if data[q] >> 4 > 4 or data[q + 1] > 7:
                    break
                if data[q + 1] & 1:
                    end = q + 16
                    break
                q += 16
        if end:
            found.append((p, end - p))
            pos = (end + ALIGN - 1) // ALIGN * ALIGN
        else:
            pos += ALIGN
    return found


def read_bank(iso_path, name):
    """Bytes of TRIBES/DATA/AUDIO/<name>.PKG straight from the ISO."""
    import pycdlib
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    try:
        rec = iso.get_record(iso_path='/TRIBES/DATA/AUDIO/%s.PKG;1' % name)
        start, size = rec.extent_location() * 2048, rec.get_data_length()
    finally:
        iso.close()
    with open(iso_path, 'rb') as f:
        f.seek(start)
        return f.read(size)


def records(data):
    """[(rate, offset, size)] of the sound records in the header: a u32 at 0x18 gives the data base, then 0x48-byte
    records from 0x58 (u16 rate just before, u16 id, u16 flags, u32 size, u32 offset from the base); a record with a
    size or offset of 0xFFFFFFFF is an empty slot. Records may share data, so duplicates by offset are dropped."""
    if data[:7] != MAGIC:
        raise ValueError('not an inevaud bank')
    count, base = struct.unpack_from('<II', data, 12)[0], struct.unpack_from('<I', data, 0x18)[0]
    out, seen = [], set()
    for k in range(count):
        b = 0x58 + 0x48 * k
        if b + 12 > len(data):
            break
        size, off = struct.unpack_from('<II', data, b + 4)
        rate = struct.unpack_from('<H', data, b - 2)[0]
        if size in (0, 0xFFFFFFFF) or off == 0xFFFFFFFF or base + off + 16 > len(data) or base + off in seen:
            continue
        seen.add(base + off)
        out.append((rate if 4000 <= rate <= 48000 else RATE, base + off, size))
    return out


def _encode_ogg(pcm, rate, path):
    import subprocess
    from video import ffmpeg_exe
    subprocess.run([ffmpeg_exe(), '-y', '-loglevel', 'error', '-f', 's16le', '-ar', str(rate), '-ac', '1', '-i', '-',
                    '-c:a', 'libvorbis', '-q:a', '4', path], input=pcm.tobytes(), check=True)


def export_bank(iso_path, name, out_dir, ogg=False, by_records=False, progress=None):
    """Writes <out_dir>/<name lower>/NNN.wav (or .ogg, mono 16-bit) for every sound; returns the sound count.
    by_records takes the sounds and their sample rates from the header records (VOICE/TRAINING/MUSIC); without it the
    banks are split by scanning (EFFECTS, 22050 Hz)."""
    import json
    import os
    import wave
    data = read_bank(iso_path, name)
    folder = os.path.join(out_dir, name.lower())
    os.makedirs(folder, exist_ok=True)
    found = ([(rate, off, size) for rate, off, size in records(data)] if by_records
             else [(RATE, off, size) for off, size in split(data)])
    index = []
    for k, (rate, off, size) in enumerate(found):
        pcm = decode_vag(data[off:off + size])
        if not len(pcm):
            continue
        fname = '%03d.%s' % (k, 'ogg' if ogg else 'wav')
        if ogg:
            _encode_ogg(pcm, rate, os.path.join(folder, fname))
        else:
            with wave.open(os.path.join(folder, fname), 'wb') as w:
                w.setnchannels(1)
                w.setsampwidth(2)
                w.setframerate(rate)
                w.writeframes(pcm.tobytes())
        index.append({'id': k, 'file': fname, 'rate': rate, 'seconds': round(len(pcm) / rate, 3)})
        if progress:
            progress(k / len(found))
    with open(os.path.join(folder, '_index.json'), 'w') as f:
        json.dump(index, f, indent=1)
    return len(index)
