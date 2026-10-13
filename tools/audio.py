"""Earth Siege audio converter.

Formats (see docs/formats/audio_video.md):
  *.SFX / *.RAW  headerless unsigned 8-bit mono PCM, 11025 Hz          -> .wav
  *.SNC          lip-sync: u16 nbytes, then nbytes/4 x {u16 tag, u16 ticks@60Hz} -> .json
  *.HMP          HMI MIDI (HMIMIDIP)                                    -> .mid (+ loop info)
  SOUNDS.STR     sim sound table (id -> file, loop, volume, flags)      -> sounds.json
  PILOTn.STR     sim pilot radio subtitles (-> SIMVOICE Pn_mmvvv.SFX)  -> pilotN.json

Usage:
  python tools/audio.py all <outdir>          convert everything
  python tools/audio.py wav <in> <out.wav>
  python tools/audio.py mid <in.hmp> <out.mid>
  python tools/audio.py snc <in.snc>          print decoded sync track
"""
import glob
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
import wav_pcm  # noqa: E402
ROOT = P.WORK        # source tree (original/, extracted/); see tools/siege_paths.py
RATE = 11025          # DBSIM default driver rate (dword @VA 0x959f0), GO.EXE & PLAYFLIC use 11025 too
SNC_TICK = 1.0 / 60   # SNC durations: 1/60 s (183.75 samples @11025)


# ------------------------------------------------------------------ PCM

def pcm_to_wav(src, dst, rate=RATE):
    data = open(src, 'rb').read()
    wav_pcm.write_pcm_wav(dst, data, 1, 1, rate)      # WAV 8-bit is unsigned, same as the game data
    return len(data) / rate


# ------------------------------------------------------------------ SNC

def read_snc(path):
    d = open(path, 'rb').read()
    n = struct.unpack_from('<H', d, 0)[0]
    vals = struct.unpack_from('<%dH' % (n // 2), d, 2)
    out = []
    t = 0
    for tag, ticks in zip(vals[0::2], vals[1::2]):
        out.append(dict(tag=tag, start=round(t * SNC_TICK, 4), dur=round(ticks * SNC_TICK, 4), ticks=ticks))
        t += ticks
    return out


# ------------------------------------------------------------------ STR tables

def read_str(path):
    """Generic Dynamix .STR: u32 dataSize, u16 count, count x {u16 len, char[len], u8 n, u8 extra[n]}."""
    d = open(path, 'rb').read()
    size, count = struct.unpack_from('<IH', d, 0)
    p = 6
    out = []
    for _ in range(count):
        ln = struct.unpack_from('<H', d, p)[0]
        s = d[p + 2:p + 2 + ln].split(b'\x00')[0].decode('latin-1')
        p += 2 + ln
        n = d[p]
        out.append((s, list(d[p + 1:p + 1 + n])))
        p += 1 + n
    if p != len(d):
        raise ValueError('%s: parsed %d of %d bytes' % (path, p, len(d)))
    return out


def sounds_table(path):
    rows = []
    for i, (name, ex) in enumerate(read_str(path)):
        if not name:
            continue
        rows.append(dict(id=i, file=name, kind='midi' if name.lower().endswith('.hmp') else 'digi',
                         loop=ex[0], volume=ex[1], flag2=ex[2], flag3=ex[3],
                         loop_desc='forever' if ex[0] == 255 else ('once' if ex[0] == 0 else '%d times' % ex[0])))
    return rows


def pilot_table(path, pilot):
    rows = []
    for text, ex in read_str(path):
        # ex = [message, variant, 0, 3, 6, 1, 20]  (only message/variant understood)
        msg, var = ex[0], ex[1]
        rows.append(dict(text=text, message=msg, variant=var,
                         file='P%d_%02d%03d.SFX' % (pilot, msg, var), extra=ex))
    return rows


# ------------------------------------------------------------------ HMP -> MIDI

def _hmp_vlq(d, p):
    v = s = 0
    while True:
        b = d[p]
        p += 1
        v |= (b & 0x7f) << s
        s += 7
        if b & 0x80:
            return v, p


def _midi_vlq(v):
    out = [v & 0x7f]
    v >>= 7
    while v:
        out.append(0x80 | (v & 0x7f))
        v >>= 7
    return bytes(reversed(out))


def read_hmp(path):
    d = open(path, 'rb').read()
    if not d.startswith(b'HMIMIDIP'):
        raise ValueError('not an HMP file')
    flen, = struct.unpack_from('<I', d, 0x20)
    ntr, division, tps, seconds = struct.unpack_from('<IIII', d, 0x30)
    p = 0x308
    tracks = []
    loop = {}
    for t in range(ntr):
        tn, ln, chan = struct.unpack_from('<III', d, p)
        q, end = p + 12, p + ln
        ev = []
        tick = 0
        status = 0
        while q < end:
            dt, q = _hmp_vlq(d, q)
            tick += dt
            c = d[q]
            if c == 0xff:
                mtype, mlen = d[q + 1], d[q + 2]
                ev.append((tick, bytes([0xff, mtype]) + _midi_vlq(mlen) + d[q + 3:q + 3 + mlen]))
                q += 3 + mlen
                if mtype == 0x2f:
                    break
                continue
            if c == 0xf0 or c == 0xf7:
                ln2, q2 = _hmp_vlq(d, q + 1)
                ev.append((tick, bytes([c]) + _midi_vlq(ln2) + d[q2:q2 + ln2]))
                q = q2 + ln2
                continue
            if c & 0x80:
                status = c
                q += 1
            hi = status & 0xf0
            n = 1 if hi in (0xc0, 0xd0) else 2
            args = d[q:q + n]
            q += n
            if hi == 0xb0 and 102 <= args[0] <= 119:
                # HMI-specific controllers: 110 = loop start (value = count, 255 = forever),
                # 111 = loop end, 108/109 = branch/control markers (dropped)
                if args[0] == 110:
                    loop.setdefault('start_tick', tick)
                    loop['count'] = args[1]
                    ev.append((tick, b'\xff\x06' + _midi_vlq(9) + b'loopStart'))
                elif args[0] == 111:
                    loop.setdefault('end_tick', tick)
                    ev.append((tick, b'\xff\x06' + _midi_vlq(7) + b'loopEnd'))
                continue
            ev.append((tick, bytes([status]) + bytes(a & 0x7f for a in args)))
        tracks.append(dict(number=tn, channel=chan, events=ev, length=tick))
        p += ln
    info = dict(division=division, ticks_per_second=tps, header_seconds=seconds, tracks=ntr,
                length_ticks=max(t['length'] for t in tracks))
    info['length_seconds'] = round(info['length_ticks'] / tps, 3)
    if loop:
        loop['start_seconds'] = round(loop.get('start_tick', 0) / tps, 4)
        loop['end_seconds'] = round(loop.get('end_tick', info['length_ticks']) / tps, 4)
        info['loop'] = loop
    return tracks, info


def hmp_to_mid(src, dst):
    tracks, info = read_hmp(src)
    division, tps = info['division'], info['ticks_per_second']
    usec_per_qn = int(round(division * 1_000_000 / tps))
    out = bytearray(b'MThd' + struct.pack('>IHHH', 6, 1, len(tracks), division))
    for i, tr in enumerate(tracks):
        evs = tr['events']
        body = bytearray()
        if i == 0:
            body += b'\x00\xff\x51\x03' + usec_per_qn.to_bytes(3, 'big')
        last = 0
        has_end = False
        for tick, e in evs:
            if e[:2] == b'\xff\x2f':
                has_end = True
            body += _midi_vlq(tick - last) + e
            last = tick
        if not has_end:
            body += b'\x00\xff\x2f\x00'
        out += b'MTrk' + struct.pack('>I', len(body)) + body
    open(dst, 'wb').write(out)
    return info


# ------------------------------------------------------------------ batch

PCM_SETS = [
    ('sfx/sim', 'extracted/SIMSOUND/**/*.SFX'),
    ('voice/sim', 'extracted/SIMVOICE/**/*.SFX'),
    ('voice/shell', 'extracted/SPEECH/**/*.RAW'),
    ('sfx/shell', 'extracted/SHELL0/RES32/*.SFX'),
    ('sfx/shell', 'extracted/SHELL0/RES32/*.RAW'),
    ('sfx/soundset', 'original/SSET/SOUNDSET.RAW'),
]
HMP_SETS = [
    ('music/sim', 'extracted/SIMSOUND/**/*.HMP'),
    ('music/shell', 'extracted/SHELL0/RES32/*.HMP'),
    ('music/soundset', 'original/SSET/SOUNDSET.HMP'),
]


def convert_all(out):
    manifest = dict(wav={}, midi={}, snc={})
    for sub, pat in PCM_SETS:
        od = os.path.join(out, sub)
        os.makedirs(od, exist_ok=True)
        for f in sorted(glob.glob(os.path.join(ROOT, pat), recursive=True)):
            base = os.path.splitext(os.path.basename(f))[0].lower()
            dst = os.path.join(od, base + '.wav')
            if os.path.exists(dst) and sub == 'sfx/shell' and f.upper().endswith('.RAW'):
                dst = os.path.join(od, base + '_raw.wav')
            secs = pcm_to_wav(f, dst)
            manifest['wav'][os.path.relpath(dst, out).replace('\\', '/')] = round(secs, 3)
    # lip sync
    od = os.path.join(out, 'voice/shell_sync')
    os.makedirs(od, exist_ok=True)
    for f in sorted(glob.glob(os.path.join(ROOT, 'extracted/SHELL0/SNC/*.SNC'))):
        base = os.path.splitext(os.path.basename(f))[0].lower()
        seq = read_snc(f)
        raw = os.path.join(ROOT, 'extracted/SPEECH/SNC', base.upper() + '.RAW')
        rec = dict(sync_ttm=base[:2].upper() + '_SYNC.TTM', speech=os.path.basename(raw) if os.path.exists(raw) else None,
                   audio_seconds=round(os.path.getsize(raw) / RATE, 3) if os.path.exists(raw) else None,
                   sync_seconds=round(sum(x['ticks'] for x in seq) * SNC_TICK, 3), frames=seq)
        json.dump(rec, open(os.path.join(od, base + '.json'), 'w'), indent=0)
        manifest['snc'][base] = rec['sync_seconds']
    for f in sorted(glob.glob(os.path.join(ROOT, 'extracted/SHELL0/SNC/*_FILES.DAT'))):
        names = open(f, 'rb').read().decode('latin-1').split()
        json.dump(names, open(os.path.join(od, os.path.basename(f).lower().replace('.dat', '.json')), 'w'), indent=0)
    # music
    for sub, pat in HMP_SETS:
        od = os.path.join(out, sub)
        os.makedirs(od, exist_ok=True)
        for f in sorted(glob.glob(os.path.join(ROOT, pat), recursive=True)):
            base = os.path.splitext(os.path.basename(f))[0].lower()
            info = hmp_to_mid(f, os.path.join(od, base + '.mid'))
            manifest['midi'][sub + '/' + base + '.mid'] = info
    # tables
    od = os.path.join(out, 'tables')
    os.makedirs(od, exist_ok=True)
    st = os.path.join(ROOT, 'extracted/SIMVOL0/STR/SOUNDS.STR')
    if os.path.exists(st):
        json.dump(sounds_table(st), open(os.path.join(od, 'sim_sounds.json'), 'w'), indent=1)
    for n in (1, 2, 4):
        p = os.path.join(ROOT, 'extracted/SIMVOL0/STR/PILOT%d.STR' % n)
        if os.path.exists(p):
            rows = pilot_table(p, n)
            for r in rows:
                r['exists'] = os.path.exists(os.path.join(ROOT, 'extracted/SIMVOICE/SIMVOICE', r['file']))
            json.dump(rows, open(os.path.join(od, 'pilot%d_voice.json' % n), 'w'), indent=1)
    json.dump(manifest, open(os.path.join(out, 'audio_manifest.json'), 'w'), indent=1)
    return manifest


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    c = argv[1]
    if c == 'all':
        m = convert_all(argv[2])
        print('wav:', len(m['wav']), 'midi:', len(m['midi']), 'snc:', len(m['snc']))
    elif c == 'wav':
        print(pcm_to_wav(argv[2], argv[3]), 's')
    elif c == 'mid':
        print(json.dumps(hmp_to_mid(argv[2], argv[3]), indent=1))
    elif c == 'snc':
        for x in read_snc(argv[2]):
            print(x)
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
