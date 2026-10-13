"""Earth Siege video converter: Dynamix FLIC (.DFL + .RAW) and Deluxe Paint .ANM.

DFL = Autodesk FLC (magic 0xAF12) with Dynamix extensions (see docs/formats/audio_video.md):
  chunk 20  DTA_LZ  : Dynamix LZ-style delta (decoder reversed from PLAYFLIC.EXE @0x3e19)
  chunk 21  SOUND   : u32 kind, u32 soundId, char name[13]   (kind 0 = digital .raw)
  chunk 22  FADE    : u32 dir(6=in,7=out), u32 mode(8=immediate,9=over N frames), u32 n, u32 rgb444
  chunk 24  SYNC    : u32 mode(13=clock,14=sound), u32 enable, u32 soundId, u32 adjustMs
Audio .RAW = unsigned 8-bit mono PCM at 11025 Hz.  ESCD.EXE launches PLAYFLIC with -S83
(83 ms/frame), which overrides the 71 ms in the FLC header; frame k>=1 is shown when the audio
reaches adjustMs + k*83 ms.

Usage:
  python tools/video.py dfl <file.DFL> <outdir> [--png] [--no-ogv]
  python tools/video.py anm <file.ANM> <outdir>
  python tools/video.py all <outdir> [--png]       (intro, end, ANMs)
"""
import os
import struct
import subprocess
import sys
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
ROOT = P.WORK        # source tree (original/, extracted/); see tools/siege_paths.py
RATE = 11025
DEFAULT_MS_PER_FRAME = 83  # ESCD.EXE: "playflic.exe flic\\intro3.dfl -S83"


# ---------------------------------------------------------------- chunk decoders

def dta_lz(buf, data, pitch):
    """Chunk type 20.  buf: flat bytearray (whole screen), decoded in place."""
    n = struct.unpack_from('<I', data, 0)[0]
    p = 4
    d = 0
    cnt = (n + 1) & 0xffff
    size = len(buf)

    def copy(src, length):
        nonlocal d
        if length <= 0:
            return
        off = src - d
        if off >= 0 or -off >= length:
            # non-overlapping (or source ahead of dest: reads original data)
            buf[d:d + length] = bytes(buf[src:src + length])
        elif off <= -2:
            # LZ-style replication; word copies read already-written bytes
            for i in range(length):
                buf[d + i] = buf[src + i]
        else:
            # off == -1 with rep movsw (word granular) + trailing movsb
            i = 0
            while i + 1 < length:
                a, b = buf[src + i], buf[src + i + 1]
                buf[d + i] = a
                buf[d + i + 1] = b
                i += 2
            if i < length:
                buf[d + i] = buf[src + i]
        d += length

    while True:
        cnt = (cnt - 1) & 0xffff
        if cnt == 0:
            break
        b0 = data[p]
        op = b0 & 7
        if op == 0:      # skip
            d += struct.unpack_from('<H', data, p)[0] >> 3
            p += 2
        elif op == 1:    # literal run
            ln = struct.unpack_from('<H', data, p)[0] >> 3
            buf[d:d + ln] = data[p + 2:p + 2 + ln]
            d += ln
            p += 2 + ln
        elif op == 2:    # short back/forward ref: off = s8>>3, len = u8
            off = struct.unpack_from('<b', data, p)[0] >> 3
            copy(d + off, data[p + 1])
            p += 2
        elif op == 3:    # off = s8 (byte1), len = byte0>>3
            off = struct.unpack_from('<b', data, p + 1)[0]
            copy(d + off, b0 >> 3)
            p += 2
        elif op == 4:    # from row above (+ s8>>3)
            off = (struct.unpack_from('<b', data, p)[0] >> 3) - pitch
            copy(d + off, data[p + 1])
            p += 2
        elif op == 5:    # from row below (previous frame content)
            off = (struct.unpack_from('<b', data, p)[0] >> 3) + pitch
            copy(d + off, data[p + 1])
            p += 2
        elif op == 6:    # long ref: off = s16>>3, len = u16
            off = struct.unpack_from('<h', data, p)[0] >> 3
            copy(d + off, struct.unpack_from('<H', data, p + 2)[0])
            p += 4
        else:            # op 7: len = u16>>3, off = s16
            ln = struct.unpack_from('<H', data, p)[0] >> 3
            off = struct.unpack_from('<h', data, p + 2)[0]
            copy(d + off, ln)
            p += 4
        if d > size:
            raise ValueError('DTA_LZ overrun')


def color_chunk(pal, data, shift):
    npk = struct.unpack_from('<H', data, 0)[0]
    p = 2
    idx = 0
    for _ in range(npk):
        idx += data[p]
        c = data[p + 1] or 256
        p += 2
        for i in range(c):
            r, g, b = data[p:p + 3]
            pal[(idx + i) & 255] = (r << shift, g << shift, b << shift)
            p += 3
        idx += c


def brun(buf, data, w, h):
    p = 0
    for y in range(h):
        p += 1  # packet count (ignored)
        x = 0
        o = y * w
        while x < w:
            c = struct.unpack_from('<b', data, p)[0]
            p += 1
            if c >= 0:
                buf[o + x:o + x + c] = bytes([data[p]]) * c
                p += 1
                x += c
            else:
                c = -c
                buf[o + x:o + x + c] = data[p:p + c]
                p += c
                x += c


def delta_fli(buf, data, w):
    y0, nl = struct.unpack_from('<HH', data, 0)
    p = 4
    for y in range(y0, y0 + nl):
        npk = data[p]
        p += 1
        x = 0
        for _ in range(npk):
            x += data[p]
            c = struct.unpack_from('<b', data, p + 1)[0]
            p += 2
            o = y * w + x
            if c >= 0:
                buf[o:o + c] = data[p:p + c]
                p += c
                x += c
            else:
                c = -c
                buf[o:o + c] = bytes([data[p]]) * c
                p += 1
                x += c


def delta_flc(buf, data, w):
    nl = struct.unpack_from('<H', data, 0)[0]
    p = 2
    y = 0
    done = 0
    while done < nl:
        op = struct.unpack_from('<H', data, p)[0]
        p += 2
        if op & 0xc000 == 0xc000:
            y += 0x10000 - op
            continue
        if op & 0xc000 == 0x8000:
            buf[y * w + w - 1] = op & 0xff
            continue
        x = 0
        for _ in range(op):
            x += data[p]
            c = struct.unpack_from('<b', data, p + 1)[0]
            p += 2
            o = y * w + x
            if c >= 0:
                buf[o:o + 2 * c] = data[p:p + 2 * c]
                p += 2 * c
                x += 2 * c
            else:
                c = -c
                buf[o:o + 2 * c] = bytes(data[p:p + 2]) * c
                p += 2
                x += 2 * c
        y += 1
        done += 1


# ---------------------------------------------------------------- DFL player

class Dfl:
    def __init__(self, path):
        self.path = path
        self.d = open(path, 'rb').read()
        d = self.d
        (self.size, self.magic, self.nframes, self.w, self.h, self.depth,
         self.flags, self.speed) = struct.unpack_from('<IHHHHHHI', d, 0)
        if self.magic not in (0xAF12, 0xAF11):
            raise ValueError('not a FLIC file')
        self.oframe1 = struct.unpack_from('<I', d, 0x50)[0] or 0x80

    def frames(self):
        """Yield (index, rgb ndarray HxWx3 uint8, events list) per frame."""
        d = self.d
        w, h = self.w, self.h
        buf = bytearray(w * h)
        pal = [(0, 0, 0)] * 256       # target palette (8-bit)
        cur = [(0, 0, 0)] * 256       # displayed palette
        fade = None                   # dict(n, c, dir, color)
        pos = self.oframe1
        for fi in range(self.nframes):
            csz, ctype = struct.unpack_from('<IH', d, pos)
            events = []
            # per-frame fade step happens before the frame is decoded (PLAYFLIC 0x362c)
            if fade and fade['c'] > 0:
                cur = self._fade_step(pal, fade)
            if ctype == 0xF1FA:
                nsub = struct.unpack_from('<H', d, pos + 6)[0]
                sp = pos + 16
                for _ in range(nsub):
                    ssz, st = struct.unpack_from('<IH', d, sp)
                    body = d[sp + 6:sp + ssz]
                    if st == 4 or st == 11:
                        color_chunk(pal, body, 0 if st == 4 else 2)
                        if not (fade and fade['c'] > 0):
                            cur = list(pal)
                    elif st == 7:
                        delta_flc(buf, body, w)
                    elif st == 12:
                        delta_fli(buf, body, w)
                    elif st == 13:
                        buf[:] = bytes(w * h)
                    elif st == 15:
                        brun(buf, body, w, h)
                    elif st == 16:
                        buf[:] = body[:w * h]
                    elif st == 20:
                        dta_lz(buf, body, w)
                    elif st == 21:
                        kind, sid = struct.unpack_from('<II', body, 0)
                        name = body[8:].split(b'\0')[0].decode('ascii', 'replace')
                        events.append(('sound', kind, sid, name))
                    elif st == 22:
                        fdir, mode, n, col = struct.unpack_from('<IIII', body, 0)
                        color = (((col >> 8) & 0xf) << 4, col & 0xf0, (col & 0xf) << 4)
                        n = n or 1
                        events.append(('fade', fdir, mode, n, col))
                        if mode == 8:
                            # blocking fade; ends at target (dir 6) or at the colour (dir 7)
                            cur = list(pal) if fdir == 6 else [color] * 256
                            fade = None
                        elif mode == 9:
                            fade = dict(n=n, c=n, dir=fdir, color=color)
                            cur = self._fade_step(pal, fade)
                            fade['c'] += 1
                    elif st == 24:
                        mode, en, sid, adj = struct.unpack_from('<IIIi', body, 0)
                        events.append(('sync', mode, en, sid, adj))
                    # 18 = PSTAMP (ignored)
                    sp += ssz
            pos += csz
            img = np.frombuffer(bytes(buf), np.uint8).reshape(h, w)
            lut = np.array(cur, np.uint8)
            yield fi, lut[img], events

    @staticmethod
    def _fade_step(pal, fade):
        fade['c'] -= 1
        n, c = fade['n'], fade['c']
        k = (n - c) if fade['dir'] == 7 else c
        out = []
        for r, g, b in pal:
            tr, tg, tb = fade['color']
            out.append(tuple(int(v + int((t - v) * k / n)) & 255
                             for v, t in ((r, tr), (g, tg), (b, tb))))
        return out


def bundled_ffmpeg():
    """ffmpeg/ffmpeg.exe next to the frozen importer: the LGPL build of tools/ffmpeg/build_ffmpeg.sh, the only
    ffmpeg a release ships (tools/build_importer.ps1). None outside a frozen build or when it is missing."""
    if not getattr(sys, 'frozen', False):
        return None
    exe = os.path.join(os.path.dirname(sys.executable), 'ffmpeg', 'ffmpeg.exe')
    return exe if os.path.isfile(exe) else None


def ffmpeg_exe():
    """The ffmpeg every converter runs: SIEGE_FFMPEG (an explicit path), else the importer's bundled build,
    else (developer checkouts) imageio-ffmpeg's binary (which honours IMAGEIO_FFMPEG_EXE), else ffmpeg on PATH."""
    explicit = os.environ.get('SIEGE_FFMPEG')
    if explicit and os.path.isfile(explicit):
        return explicit
    bundled = bundled_ffmpeg()
    if bundled:
        return bundled
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        from shutil import which
        return which('ffmpeg')


def write_wav(path, pcm_u8, rate=RATE):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(rate)
        w.writeframes(pcm_u8)


def convert_dfl(path, outdir, png=False, ogv=True, ms_per_frame=DEFAULT_MS_PER_FRAME):
    os.makedirs(outdir, exist_ok=True)
    base = os.path.splitext(os.path.basename(path))[0].lower()
    flic = Dfl(path)
    ff = ffmpeg_exe() if ogv else None
    frame_dir = os.path.join(outdir, base + '_frames')
    if png or not ff:
        os.makedirs(frame_dir, exist_ok=True)
    proc = None
    raw_path = os.path.join(outdir, base + '_video.rgb')
    sound = None
    adjust_ms = 0
    from PIL import Image
    rgbf = open(raw_path, 'wb') if ff else None
    nfr = 0
    for fi, rgb, ev in flic.frames():
        for e in ev:
            if e[0] == 'sound' and e[1] == 0:
                sound = e[3]
            if e[0] == 'sync':
                adjust_ms = e[4]
        if rgbf:
            rgbf.write(rgb.tobytes())
        if png or not ff:
            Image.fromarray(rgb).save(os.path.join(frame_dir, '%04d.png' % fi))
        nfr += 1
    if rgbf:
        rgbf.close()
    wav_path = None
    audio_len = 0.0
    if sound:
        rp = os.path.join(os.path.dirname(path), sound)
        if not os.path.exists(rp):
            rp = os.path.join(os.path.dirname(path), sound.upper())
        if os.path.exists(rp):
            pcm = open(rp, 'rb').read()
            wav_path = os.path.join(outdir, base + '.wav')
            write_wav(wav_path, pcm)
            audio_len = len(pcm) / RATE
    info = dict(file=os.path.basename(path), frames=nfr, width=flic.w, height=flic.h,
                header_ms_per_frame=flic.speed, ms_per_frame=ms_per_frame,
                sound=sound, sync_adjust_ms=adjust_ms, audio_seconds=round(audio_len, 3),
                video_seconds=round(adjust_ms / 1000 + nfr * ms_per_frame / 1000, 3))
    if ff:
        out = os.path.join(outdir, base + '.ogv')
        fps = '%d/%d' % (1000, ms_per_frame)
        # frame 0 is held for adjustMs before the regular cadence starts
        hold = max(adjust_ms, 0) / 1000.0
        cmd = [ff, '-hide_banner', '-loglevel', 'error', '-y',
               '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '%dx%d' % (flic.w, flic.h),
               '-framerate', fps, '-i', raw_path]
        if wav_path:
            cmd += ['-i', wav_path]
        vf = 'tpad=start_mode=clone:start_duration=%.3f,tpad=stop_mode=clone:stop_duration=%.3f,' \
             'scale=640:400:flags=neighbor,fps=24' % (hold, max(0.0, audio_len - info['video_seconds']))
        cmd += ['-vf', vf, '-fps_mode', 'cfr', '-pix_fmt', 'yuv420p', '-c:v', 'libtheora', '-q:v', '8']
        if wav_path:
            cmd += ['-c:a', 'libvorbis', '-q:a', '5', '-ar', '22050']
        cmd += [out]
        subprocess.run(cmd, check=True)
        os.remove(raw_path)
        info['ogv'] = os.path.basename(out)   # next to this json (no machine-specific paths in packs)
    with open(os.path.join(outdir, base + '.json'), 'w') as f:
        import json
        json.dump(info, f, indent=1)
    return info


def convert_anm(path, outdir):
    """Deluxe Paint Animation (LPF ANM): decoded by ffmpeg's native 'anm' decoder."""
    ff = ffmpeg_exe()
    if not ff:
        raise RuntimeError('ffmpeg not available (pip install imageio-ffmpeg)')
    base = os.path.splitext(os.path.basename(path))[0].lower()
    d = os.path.join(outdir, base + '_frames')
    os.makedirs(d, exist_ok=True)
    subprocess.run([ff, '-hide_banner', '-loglevel', 'error', '-y', '-i', path,
                    os.path.join(d, '%03d.png')], check=True)
    return len(os.listdir(d))


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 1
    cmd = argv[1]
    png = '--png' in argv
    ogv = '--no-ogv' not in argv
    if cmd == 'dfl':
        print(convert_dfl(argv[2], argv[3], png=png, ogv=ogv))
    elif cmd == 'anm':
        print(convert_anm(argv[2], argv[3]), 'frames')
    elif cmd == 'all':
        out = argv[2]
        for f in ('INTRO3.DFL', 'END.DFL'):
            print(convert_dfl(os.path.join(ROOT, 'original', 'FLIC', f), os.path.join(out, 'flic'),
                              png=png, ogv=ogv))
        for f in ('ESIEGE2.ANM', 'ESIEGE3.ANM'):
            n = convert_anm(os.path.join(ROOT, 'extracted', 'SHELL0', 'ANM', f), os.path.join(out, 'anm'))
            print(f, n, 'frames')
    else:
        print(__doc__)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
