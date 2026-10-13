"""Earthsiege 2 radio: wingman chatter and training-command tables + their voice clips -> pack "es2".

    python tools/export_es2_radio.py

Sources (docs/formats/es2.md section 11 "Radio"):
  es2/extracted/SIMVOL0/STR/PILOT{0,1,2,4}.STR   wingman lines, Dynamix STR (tools/audio.read_str);
                                                 extra = [message, variant, ...] as in Earthsiege 1
  es2/extracted/SIMVOL0/STR/COMMAND{0..4}.STR    COMMAND0 base-under-attack lines, COMMAND1..4 training
                                                 lessons 1..4; the variants of a message are its successive lines
  es2/extracted/SIMVOICE/SIMVOICE/P<n>_<mm><vvv>.WAV   wingman voices (SIMVOICE.VOL; plain 8-bit PCM WAV)
  es2/original/SIMVOICE/TM<lesson>_00<message+1>.WAV   training voices (loose on the disc; DBSIM 0x4368fb)

Output (same row layout as the Earthsiege 1 tables written by tools/audio.py, plus "voice" = the Sfx sound
stem inside the pack, "" when the clip is missing):
  audio/tables/pilot<n>_voice.json     n = 0, 1, 2, 4
  audio/tables/command<n>_voice.json   n = 0..4
  audio/voice/sim/p<n>_<mm><vvv>.wav, audio/voice/training/tm<lesson>_<nnnn>.wav (PCM rewritten)
"""
import json
import os
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
from audio import read_str  # noqa: E402

PACK = 'es2'
PILOT_TABLES = (0, 1, 2, 4)
COMMAND_TABLES = (0, 1, 2, 3, 4)
STR_DIR = P.work('es2', 'extracted', 'SIMVOL0', 'STR')
PILOT_VOICE_DIR = P.work('es2', 'extracted', 'SIMVOICE', 'SIMVOICE')
TRAINING_VOICE_DIR = P.work('es2', 'original', 'SIMVOICE')
OUT_TABLES = P.pack(PACK, 'audio', 'tables')
OUT_VOICE = P.pack(PACK, 'audio', 'voice')


def find_file(folder, name):
    """Case-insensitive lookup of `name` in `folder` (disc copies keep their own case); None if absent."""
    if not os.path.isdir(folder):
        return None
    wanted = name.lower()
    for f in os.listdir(folder):
        if f.lower() == wanted:
            return os.path.join(folder, f)
    return None


def copy_voice(src, sub):
    """Rewrites a voice WAV into audio/voice/<sub>/ (lower-case stem); returns its Sfx stem "<sub>/<stem>".
    Only the PCM samples are kept: many disc clips end in a stray marker chunk with a bogus size, and odd
    data chunks lack their pad byte (Godot's WAV loader then seeks past the end); an odd last sample is dropped."""
    stem = os.path.splitext(os.path.basename(src))[0].lower()
    dst_dir = os.path.join(OUT_VOICE, sub)
    os.makedirs(dst_dir, exist_ok=True)
    with wave.open(src, 'rb') as w:
        params, frames = w.getparams(), w.readframes(w.getnframes())
    if len(frames) % 2:
        frames = frames[:-params.sampwidth * params.nchannels]   # an even data chunk needs no pad byte
    with wave.open(os.path.join(dst_dir, stem + '.wav'), 'wb') as out:
        out.setparams(params)
        out.writeframes(frames)
    return '%s/%s' % (sub, stem)


def make_row(text, extra, file_name, src, sub):
    voice = copy_voice(src, sub) if src else ''
    return dict(text=text, message=extra[0], variant=extra[1], file=file_name, extra=extra,
                exists=bool(src), voice=voice)


def pilot_rows(pilot):
    """PILOT<n>.STR: one row per (message, variant); the clip is P<n>_<mm><vvv>.WAV (PILOT0 has none)."""
    rows = []
    for text, extra in read_str(os.path.join(STR_DIR, 'PILOT%d.STR' % pilot)):
        name = 'P%d_%02d%03d.WAV' % (pilot, extra[0], extra[1])
        rows.append(make_row(text, extra, name, find_file(PILOT_VOICE_DIR, name), 'sim'))
    return rows


def command_rows(lesson):
    """COMMAND<n>.STR: message m (all its variants) is spoken by TM<n>_00<m+1>.WAV; COMMAND0 has no clips."""
    rows = []
    for text, extra in read_str(os.path.join(STR_DIR, 'COMMAND%d.STR' % lesson)):
        name = 'TM%d_%04d.WAV' % (lesson, extra[0] + 1) if lesson > 0 else ''
        src = find_file(TRAINING_VOICE_DIR, name) if name and extra[1] == 0 else None
        rows.append(make_row(text, extra, name, src, 'training'))
    return rows


def write_table(name, rows):
    os.makedirs(OUT_TABLES, exist_ok=True)
    with open(os.path.join(OUT_TABLES, name), 'w') as f:
        json.dump(rows, f, indent=1)


def main():
    if not os.path.isdir(STR_DIR):
        print('export_es2_radio: %s not found (unpack the VOLs first)' % STR_DIR)
        return 1
    clips = 0
    for n in PILOT_TABLES:
        rows = pilot_rows(n)
        clips += sum(1 for r in rows if r['exists'])
        write_table('pilot%d_voice.json' % n, rows)
    for n in COMMAND_TABLES:
        rows = command_rows(n)
        clips += sum(1 for r in rows if r['exists'])
        write_table('command%d_voice.json' % n, rows)
    print('export_es2_radio: %d pilot + %d command tables, %d voice clips' % (
        len(PILOT_TABLES), len(COMMAND_TABLES), clips))
    return 0


if __name__ == '__main__':
    sys.exit(main())
