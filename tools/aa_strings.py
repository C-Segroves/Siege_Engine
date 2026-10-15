"""Aerial Assault string tables (.BIN): u32 count, count x u32 offsets (relative to the end of the offset list),
then NUL-terminated UTF-16LE strings. Used for CAMPAIGN, MISSIONNAMES, OBJECTIVES, COMMUNIQUE and per-mission STRINGS.

Briefing-style strings carry in-band format codes (U+FFFF, U+FFAA, U+AAFF); clean() drops them.
"""
import struct

MARKS = '￿ﾪ꫿'
MISSIONS_DIR = 'DATA/MISSIONS/'


def parse_table(data):
    """Raw strings of a table (NULs stripped, format codes kept)."""
    if len(data) < 4:
        return []
    count = struct.unpack_from('<I', data)[0]
    if 4 + 4 * count > len(data):
        raise ValueError('string table count %d exceeds the data' % count)
    offs = struct.unpack_from('<%dI' % count, data, 4)
    base = 4 + 4 * count
    out = []
    for i, o in enumerate(offs):
        end = offs[i + 1] if i + 1 < count else len(data) - base
        out.append(data[base + o:base + end].decode('utf-16le', 'replace').rstrip('\0'))
    return out


def clean(text):
    return ''.join(c for c in text if c not in MARKS).replace('\r', '').strip()


def read_table(files, name):
    """files: aa_files.FilesDat. name: e.g. 'CAMPAIGN'. Returns cleaned strings (index preserved)."""
    return [clean(s) for s in parse_table(files.read(MISSIONS_DIR + name + '.BIN'))]


def is_briefing(raw):
    return raw.startswith('￿￿')
