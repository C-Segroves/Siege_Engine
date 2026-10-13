"""Identifies which release of a game a disc holds, from the disc's own data (docs/TESTED_VERSIONS.md).

The importer records the result in pack.json "release" (tools/siege_import.py write_pack_meta) and the game compares
its hashes with game/engine/tested_versions.json (engine/release_check.gd).

Evidence, read from the game's main executable (GAME['main_exe']) and an optional version text (GAME['version_file']):
  - Darkstar version tag "V 001.000r" (Starsiege; a 1.003 / 1.004 patched exe carries "V 001.003r" ...)
  - Win32 VERSIONINFO "FileVersion" (Tribes 2: "0, 21570, 0, 0" = build 21570; the last patch is build 25034)
  - Dynamix "Release 1.3.2 Nov 18 1994 11:05:23" (Battledrome SIM.EXE, code\\version.cpp)
  - Darkstar console "Version: %d.%d / Date: %s / Time: %s" build date (Starsiege, Tribes)
  - "version 1.0" lines in the disc's VERSION.TXT / readme
plus the SHA-256 of the executable and of the disc image, the volume label and the disc's mastering date.

    python tools/disc_version.py <iso> [...]      prints the release record of each disc (developer aid)
"""
import hashlib
import json
import os
import re
import sys

DARKSTAR_TAG = re.compile(rb'V (\d{3})\.(\d{3})([a-z]?)\x00')
DYNAMIX_RELEASE = re.compile(rb'Release (\d+(?:\.\d+)+) ([A-Z][a-z]{2} [ \d]\d \d{4}) (\d\d:\d\d:\d\d)')
CONSOLE_BUILD_DATE = re.compile(rb'Date: %s\s*Time: %s\s*\x00+([A-Z][a-z]{2} [ \d]\d \d{4})\x00+(\d\d:\d\d:\d\d)')
PE_FILE_VERSION = 'FileVersion\0'.encode('utf-16-le')
TEXT_VERSION = re.compile(r'\bversion\s+(\d+(?:\.\d+)+)', re.IGNORECASE)
TEXT_HEAD_LINES = 5              # a version line sits at the top of VERSION.TXT / Readme.txt
HASH_CHUNK = 1 << 22


def make_file_sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(HASH_CHUNK), b''):
            h.update(chunk)
    return h.hexdigest()


def make_pe_file_version(exe):
    """'0.21570.0.0' from a Win32 VERSIONINFO block, '' when the exe has none."""
    i = exe.find(PE_FILE_VERSION)
    if i < 0:
        return ''
    i += len(PE_FILE_VERSION)
    i += (4 - i % 4) % 4                           # the value starts on a 32-bit boundary
    end = exe.find(b'\0\0', i)
    while end > 0 and (end - i) % 2:
        end = exe.find(b'\0\0', end + 1)
    text = exe[i:end].decode('utf-16-le', 'replace')
    return '.'.join(p.strip() for p in text.split(','))


def make_exe_evidence(exe):
    """Version and build strings found in an executable -> {version?, build?, build_date?}."""
    out = {}
    tag = DARKSTAR_TAG.search(exe)
    if tag:
        out['version'] = '%d.%s%s' % (int(tag.group(1)), tag.group(2).decode(), tag.group(3).decode())
    release = DYNAMIX_RELEASE.search(exe)
    if release:
        out.setdefault('version', release.group(1).decode())
        out['build_date'] = '%s %s' % (release.group(2).decode(), release.group(3).decode())
    stamp = CONSOLE_BUILD_DATE.search(exe)
    if stamp:
        out.setdefault('build_date', '%s %s' % (stamp.group(1).decode(), stamp.group(2).decode()))
    pe = make_pe_file_version(exe)
    if pe:
        parts = pe.split('.')
        out['build'] = parts[1] if parts[0] == '0' and len(parts) > 1 else pe
    return out


def make_text_version(text):
    """'1.0' from the first lines of a version text / readme, '' when none."""
    head = '\n'.join(text.splitlines()[:TEXT_HEAD_LINES])
    m = TEXT_VERSION.search(head)
    return m.group(1) if m else ''


def make_release(game, disc, exe_path, version_text=''):
    """The pack.json "release" record: disc = siege_iso.Disc of disc 1, exe_path = the main executable on disk.
    "version" is absent when neither the exe nor the disc names one (Earthsiege's DOS exe, Tribes): the game then
    names the release from game/engine/tested_versions.json by the exe hash."""
    with open(exe_path, 'rb') as f:
        exe = f.read()
    rec = {'exe': os.path.basename(exe_path), 'exe_sha256': hashlib.sha256(exe).hexdigest(), 'exe_size': len(exe)}
    rec.update(make_exe_evidence(exe))
    text_version = make_text_version(version_text)
    if text_version:
        rec['text_version'] = text_version
        rec.setdefault('version', text_version)
    rec['label'] = disc.label
    rec['mastered'] = disc.mastered()
    rec['disc_file'] = os.path.basename(disc.path)
    rec['disc_sha256'] = make_file_sha256(disc.path)
    rec['game'] = game['game']
    return rec


# ---------------------------------------------------------------------------------------------- developer aid
def _release_of(path):
    import shutil
    import tempfile
    import siege_import
    game, info = siege_import.identify_disc(path)
    exe_spec = game.GAME.get('main_exe', {})
    if 'disc' not in exe_spec:
        return {'game': info['game'], 'note': 'main exe is inside an install archive; import the disc to see it'}
    import siege_iso
    tmp = tempfile.mkdtemp(prefix='siege-version-')
    try:
        with siege_iso.Disc(path) as disc:
            exe_path = os.path.join(tmp, os.path.basename(exe_spec['disc']))
            disc.extract(exe_spec['disc'], exe_path)
            return make_release(game.GAME, disc, exe_path, read_disc_text(disc, game.GAME.get('version_file', '')))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def read_disc_text(disc, rel):
    """Text of a small file on the disc ('' when rel is empty or missing)."""
    import tempfile
    if not rel or not disc.exists(rel):
        return ''
    fd, tmp = tempfile.mkstemp(prefix='siege-version-')
    os.close(fd)
    try:
        disc.extract(rel, tmp)
        with open(tmp, encoding='latin1') as f:
            return f.read()
    finally:
        os.remove(tmp)


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    for p in sys.argv[1:]:
        print(json.dumps(_release_of(p), indent=1))
