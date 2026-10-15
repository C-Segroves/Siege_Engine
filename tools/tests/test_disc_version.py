"""disc_version: the release evidence is read from synthetic executables (no game data) the way the real ones
store it, and the game's tested-versions table is well formed.

    python -m pytest tools/tests/test_disc_version.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import disc_version  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TABLE = os.path.join(REPO, 'game', 'engine', 'tested_versions.json')


def _with_version_info(prefix, value):
    """prefix + a VERSIONINFO String entry: key, padding to a 32-bit file offset, value (UTF-16LE)."""
    head = prefix + b'\x00' * 6 + 'FileVersion\0'.encode('utf-16-le')
    head += b'\x00' * ((4 - len(head) % 4) % 4)
    return head + (value + '\0').encode('utf-16-le') + b'\x00\x00'


def test_darkstar_tag_names_the_version():
    exe = b'MZ junk \x00V 001.000r\x00es3a\x00'
    assert disc_version.make_exe_evidence(exe)['version'] == '1.000r'


def test_patched_darkstar_tag():
    assert disc_version.make_exe_evidence(b'\x00V 001.004r\x00')['version'] == '1.004r'


def test_console_build_date():
    exe = b'Version: %d.%d\nDate: %s\nTime: %s\n\x00Dec 15 1998\x0015:50:16\x00'
    assert disc_version.make_exe_evidence(exe)['build_date'] == 'Dec 15 1998 15:50:16'


def test_dynamix_release_string():
    ev = disc_version.make_exe_evidence(b'\x00Release 1.3.2 Nov 18 1994 11:05:23\x00')
    assert ev == {'version': '1.3.2', 'build_date': 'Nov 18 1994 11:05:23'}


def test_pe_file_version_build():
    exe = _with_version_info(b'MZ' + b'\x00' * 9, '0, 21570, 0, 0')
    assert disc_version.make_exe_evidence(exe)['build'] == '21570'


def test_no_evidence():
    assert disc_version.make_exe_evidence(b'MZ nothing here') == {}


def test_text_version_from_the_top_lines():
    assert disc_version.make_text_version('EarthSiege II version 1.0\nCopyright\n') == '1.0'
    assert disc_version.make_text_version('\n' * 10 + 'Version 9.9') == ''


def test_tested_table_is_well_formed():
    with open(TABLE, encoding='utf-8') as f:
        table = json.load(f)
    games = [e['game'] for e in table['releases']]
    assert set(games) == {'es1', 'bd', 'es2', 'starsiege', 'tribes', 'tribes2'}   # several releases per game
    for e in table['releases']:
        assert len(e['exe_sha256']) == 64 and len(e['disc_sha256']) == 64
        assert e['version'] and e['result']
