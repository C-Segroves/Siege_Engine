"""aa_files: a synthetic SFDC blob lists, reads and extracts by name.

    python -m pytest tools/tests/test_aa_files.py
"""
import io
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import aa_files  # noqa: E402


def _blob():
    strings = b'\0DATA\0A.TXT\0B.BIN\0'      # offsets: DATA=1, A.TXT=6, B.BIN=12
    recs = [(6, 1, 0, 5), (12, 1, 1, 3)]
    rec_bytes = len(recs) * 16
    data_base = 2048
    head = struct.pack('<10I', 0x43444653, 1, 2048, 0, data_base, 0, rec_bytes, len(recs), 0, 0)
    body = head + b''.join(struct.pack('<4I', *r) for r in recs) + strings
    body = body.ljust(data_base, b'\0') + b'hello'.ljust(2048, b'\0') + b'xyz'
    return body


def test_list_read_and_find():
    fd = aa_files.FilesDat(io.BytesIO(_blob()))
    assert [e[0] for e in fd.list()] == ['DATA\A.TXT', 'DATA\B.BIN']
    assert fd.read('data/a.txt') == b'hello'
    assert fd.read('B.BIN') == b'xyz'
    assert [e[0] for e in fd.list('bin')] == ['DATA\B.BIN']


def test_extract_and_bad_magic(tmp_path):
    fd = aa_files.FilesDat(io.BytesIO(_blob()))
    fd.extract('A.TXT', str(tmp_path / 'a'))
    assert (tmp_path / 'a').read_bytes() == b'hello'
    try:
        aa_files.FilesDat(io.BytesIO(b'\0' * 64))
        assert False
    except ValueError:
        pass


def test_string_table():
    import aa_strings
    a, b = 'Hi\0'.encode('utf-16le'), '￿￿Yo ﾪ\0'.encode('utf-16le')
    blob = struct.pack('<I2I', 2, 0, len(a)) + a + b
    assert aa_strings.parse_table(blob)[0] == 'Hi'
    assert [aa_strings.clean(s) for s in aa_strings.parse_table(blob)] == ['Hi', 'Yo']
    assert aa_strings.is_briefing(aa_strings.parse_table(blob)[1])
