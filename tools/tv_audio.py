"""Tribes: Vengeance audio: UE2 Sound objects of Content/Sounds/*.pkg -> WAV, plus the mission speech files (OGG).

  audio/sfx/<package>/<sound>.wav       every Sound export (the object holds a complete RIFF/WAVE file, PCM 16-bit; the
                                        engine's Sfx.stream("tribes_v:<package>/<sound>") plays it)
  audio/sounds.json                     {"sounds": {"<package>/<name>": {"seconds": f}}, "weapons": {Weapon: {Event: [stems]}}}
                                        weapons are mapped by the sound naming convention <Weapon>_<Event><n> / <Weapon>Proj_<Event><n>
  audio/voice/<tag>.ogg                 the speech lines the campaign scripts speak (ActionSpeak SpeechTag = file name under
                                        Content/System/Localisation/Maps/VO/SP-NN*/), copied as they are (Ogg Vorbis)
Cutscene sound packages (TV_cs*) and the multiplayer quick-chat packages are skipped unless include_all is set.
Sound object layout (verified): tagged property stream (a 'wav' array marker), the RIFF file, then the trailing string
"Sound Forge x.y": the RIFF length field gives the exact end.
"""
import json
import os
import re
import shutil
import struct

import ue2_package as U

SKIP = re.compile(r'^(tv_cs\d|quickchat)', re.I)
WEAPON_RE = re.compile(r'^([A-Za-z]+?)(Proj)?_([A-Za-z]+?)(\d*)$')


def riff_bytes(raw):
    """The RIFF/WAVE file inside a Sound export's bytes (None when absent)."""
    i = raw.find(b'RIFF')
    if i < 0 or raw[i + 8:i + 12] != b'WAVE':
        return None
    n = struct.unpack_from('<I', raw, i + 4)[0] + 8
    return bytes(raw[i:i + n])


def wav_seconds(wav):
    try:
        rate, = struct.unpack_from('<I', wav, 24)
        width = struct.unpack_from('<H', wav, 32)[0] or 1
        size = struct.unpack_from('<I', wav, 40)[0]
        return round(size / float(rate * width), 2) if rate else 0.0
    except struct.error:
        return 0.0


def _safe(s):
    return ''.join(c if c.isalnum() or c in '-_' else '_' for c in s)


def export_sounds(game_root, pack_dir, include_all=False, log=print):
    """Writes every sound; returns the index dictionary (also saved as audio/sounds.json)."""
    out_dir = os.path.join(pack_dir, 'audio', 'sfx')
    sounds, weapons = {}, {}
    sdir = os.path.join(game_root, 'Content', 'Sounds')
    for dirpath, _d, files in os.walk(sdir):
        for f in sorted(files):
            stem, ext = os.path.splitext(f)
            if ext.lower() != '.pkg' or (SKIP.match(stem) and not include_all):
                continue
            pkg = U.load(os.path.join(dirpath, f))
            pk = _safe(stem).lower()
            for e in pkg.find('Sound'):
                wav = riff_bytes(pkg.raw(e))
                if wav is None:
                    continue
                name = _safe(e['name'])
                key = '%s/%s' % (pk, name)
                if key in sounds:
                    key = '%s/%s_%d' % (pk, name, e['offset'])
                os.makedirs(os.path.join(out_dir, pk), exist_ok=True)
                with open(os.path.join(out_dir, key + '.wav'), 'wb') as fh:
                    fh.write(wav)
                sounds[key] = {'seconds': wav_seconds(wav)}
                if pk == 'tv_weapons':
                    m = WEAPON_RE.match(name)
                    if m:
                        who = m.group(1) + ('Proj' if m.group(2) else '')
                        weapons.setdefault(who, {}).setdefault(m.group(3), []).append(key)
    index = {'pack': 'tribes_v', 'sounds': sounds, 'weapons': weapons}
    os.makedirs(os.path.join(pack_dir, 'audio'), exist_ok=True)
    with open(os.path.join(pack_dir, 'audio', 'sounds.json'), 'w', encoding='utf-8') as fh:
        json.dump(index, fh, indent=0)
    log('audio: %d sounds, %d weapon/projectile groups' % (len(sounds), len(weapons)))
    return index


def find_voice_files(game_root):
    """{speech tag lower-case: path} of the .ogg speech lines under Localisation/Maps/VO."""
    out = {}
    base = os.path.join(game_root, 'Content', 'System', 'Localisation', 'Maps', 'VO')
    for dirpath, _d, files in os.walk(base):
        for f in files:
            if f.lower().endswith('.ogg'):
                out.setdefault(os.path.splitext(f)[0].lower(), os.path.join(dirpath, f))
    return out


def copy_voice(voice_files, tags, pack_dir):
    """Copies the speech files of `tags` into audio/voice/<tag>.ogg; returns the tags that exist."""
    have = []
    dst = os.path.join(pack_dir, 'audio', 'voice')
    for tag in tags:
        src = voice_files.get(str(tag).lower())
        if src is None:
            continue
        os.makedirs(dst, exist_ok=True)
        target = os.path.join(dst, _safe(tag) + '.ogg')
        if not os.path.isfile(target):
            shutil.copyfile(src, target)
        have.append(tag)
    return have


def sound_import_name(pkg, ref):
    """'package/name' stem of a Sound object reference (import), or '' when it is not a sound package object."""
    if ref >= 0:
        return ''
    imp = pkg.imports[-ref - 1]
    outer = imp['package']
    if outer >= 0 or -outer - 1 >= len(pkg.imports):
        return ''
    return '%s/%s' % (_safe(pkg.imports[-outer - 1]['name']).lower(), _safe(imp['name']))


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 3:
        sys.exit('usage: tv_audio.py <game root (app/Tribes Vengeance)> <pack folder>')
    export_sounds(sys.argv[1], sys.argv[2])
