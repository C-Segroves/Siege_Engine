"""aa_audio: PS-ADPCM decoding and bank splitting on synthetic data.

    python -m pytest tools/tests/test_aa_audio.py
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import aa_audio  # noqa: E402


def _block(shift, pred, flag, nibbles):
    body = bytes((nibbles[i] | (nibbles[i + 1] << 4)) for i in range(0, 28, 2))
    return bytes([shift | (pred << 4), flag]) + body


def test_decode_filter0_and_end_flag():
    data = _block(0, 0, 0, [1, 7, 8, 15] + [0] * 24) + _block(0, 0, 1, [0] * 28) + _block(0, 0, 0, [1] * 28)
    pcm = aa_audio.decode_vag(data)
    assert len(pcm) == 56                       # stops after the end-flag block
    assert list(pcm[:4]) == [4096, 7 << 12, -8 << 12, -4096]


def test_split_aligned_samples():
    snd = _block(0, 0, 0, [0] * 28) + _block(0, 0, 1, [0] * 28)
    data = b'inevaud' + bytes(aa_audio.HEADER - 7) + snd
    data = data.ljust(aa_audio.HEADER + aa_audio.ALIGN, b'\0') + snd
    assert aa_audio.split(data) == [(aa_audio.HEADER, 32), (aa_audio.HEADER + aa_audio.ALIGN, 32)]


def test_records_read_rate_size_offset():
    import struct
    head = bytearray(b'inevaud' + bytes(0x200))
    struct.pack_into('<I', head, 12, 2)
    struct.pack_into('<I', head, 0x18, 0x100)                        # two records, data base 0x100
    for k, (rate, size, off) in enumerate(((22050, 32, 0), (11025, 32, 32))):
        b = 0x58 + 0x48 * k
        struct.pack_into('<H', head, b - 2, rate)
        struct.pack_into('<II', head, b + 4, size, off)
    data = bytes(head)
    assert aa_audio.records(data) == [(22050, 0x100, 32), (11025, 0x120, 32)]
