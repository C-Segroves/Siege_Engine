"""Starsiege mission radio voices -> pack "starsiege" audio/voice/<stem>.wav.

    python tools/export_starsiege_voice.py

The campaign scripts speak through say(channel, who, text, "<NAME>.wav") / actorTalks(...) / playSound(..)
(docs/formats/starsiege.md "Radio"). Every "<name>.wav" the exported mission scripts (missions/*.cs) and the
shared mission library (scripts/missionStdLib.cs) name is looked up, case-insensitively, first in the unpacked
volumes (starsiege/extracted/<vol>/), then in EVERY volume of the installed game (starsiege/original/installed,
also the ones the importer does not unpack: campaign *.ted.vol, sm_*.vol squad voices, tr*.vol training, cinematic.vol),
and written (plain PCM WAV) to audio/voice/<lower-case stem>.wav, where Sfx.stream("starsiege:<stem>") finds it.

Clips found nowhere are listed in audio/voice/_missing.json with the reason. Checked (2026-10-10): the install
cabinet (disc 1 setup/data1.cab, 753 files) is the game's only data - the second disc image of the user's set is
byte-identical to the first, and no volume entry, loose file or movie holds them under another name or case. The
33 "<MISSION>_Debriefing.wav" success narrations and 93 mission-specific lines (e.g. HA1_1SQ01, CA0_NEX01) never
shipped: the retail data has no clip with a mission prefix (HA*, HB* ... CE*) except HE2_CAANON_CN1..4.
"""
import glob
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

PACK = 'starsiege'
EXTRACTED = P.work('starsiege', 'extracted')
INSTALLED = P.work('starsiege', 'original', 'installed')
SCRIPT_SOURCES = [(P.pack(PACK, 'missions'), None), (P.pack(PACK, 'scripts'), 'missionstdlib.cs')]
OUT = P.pack(PACK, 'audio', 'voice')
WAV_REF = re.compile(r'"([A-Za-z0-9_\-]+)\.wav"', re.I)
DEBRIEFING_SUFFIX = '_debriefing'
REASON_DEBRIEFING = 'mission success narration (successWavFile): not in the retail data'
REASON_ABSENT = 'not in any volume or file of the retail data'


def script_files():
    """The exported mission scripts and the shared mission library."""
    files = []
    for folder, only in SCRIPT_SOURCES:
        if not os.path.isdir(folder):
            continue
        for f in sorted(os.listdir(folder)):
            if f.lower().endswith('.cs') and (only is None or f.lower() == only):
                files.append(os.path.join(folder, f))
    return files


def referenced_stems(files):
    stems = set()
    for path in files:
        with open(path, encoding='latin-1') as f:
            stems.update(m.group(1).lower() for m in WAV_REF.finditer(f.read()))
    return stems


def unpacked_wavs():
    """Lower-case stem -> path of every WAV in the unpacked volumes (first volume in name order wins)."""
    found = {}
    if not os.path.isdir(EXTRACTED):
        return found
    for vol in sorted(os.listdir(EXTRACTED)):
        d = os.path.join(EXTRACTED, vol)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            stem, ext = os.path.splitext(f)
            if ext.lower() == '.wav':
                found.setdefault(stem.lower(), os.path.join(d, f))
    return found


def installed_volumes():
    """Every .vol of the installed game (root, campaign, multiplayer ...), in path order."""
    if not os.path.isdir(INSTALLED):
        return []
    return sorted(glob.glob(os.path.join(INSTALLED, '**', '*.vol'), recursive=True), key=str.lower)


def write_from_volumes(wanted):
    """Writes each wanted stem found in an installed volume to OUT; returns the stems written."""
    import darkstar_lzh
    import darkstar_vol
    written = set()
    for vol in installed_volumes():
        try:
            data, entries = darkstar_vol.read_vol(vol)
        except (ValueError, AssertionError) as e:
            print('  %s: %s' % (os.path.basename(vol), e))
            continue
        for e in entries:
            stem, ext = os.path.splitext(os.path.basename(e['name'].replace('\\', '/')))
            stem = stem.lower()
            if ext.lower() != '.wav' or stem not in wanted or stem in written:
                continue
            clip = darkstar_lzh.entry_data(data, e)
            if clip is not None:
                with open(os.path.join(OUT, stem + '.wav'), 'wb') as f:
                    f.write(clip)
                written.add(stem)
    return written


def make_missing_report(missing):
    return {stem: REASON_DEBRIEFING if stem.endswith(DEBRIEFING_SUFFIX) else REASON_ABSENT for stem in sorted(missing)}


def main():
    stems = referenced_stems(script_files())
    os.makedirs(OUT, exist_ok=True)
    wavs = unpacked_wavs()
    for stem in stems & wavs.keys():
        shutil.copyfile(wavs[stem], os.path.join(OUT, stem + '.wav'))
    missing = stems - wavs.keys()
    missing -= write_from_volumes(missing)
    with open(os.path.join(OUT, '_missing.json'), 'w', encoding='utf-8') as f:
        json.dump(make_missing_report(missing), f, indent=1)
    debriefings = sum(1 for s in missing if s.endswith(DEBRIEFING_SUFFIX))
    print('export_starsiege_voice: %d clips referenced, %d written, %d missing from the retail data '
          '(%d debriefing narrations, %d mission lines)' % (len(stems), len(stems) - len(missing), len(missing),
                                                           debriefings, len(missing) - debriefings))
    return 0


if __name__ == '__main__':
    sys.exit(main())
