"""wav_pcm: IMA ADPCM decodes to the reference samples, PCM copies unchanged, and every exported pack sound is PCM.

    python -m pytest tools/tests/test_wav_pcm.py
"""
import glob
import os
import struct
import sys
import wave

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import siege_paths as P  # noqa: E402
import wav_pcm  # noqa: E402


def _ima_block(predictor, index, nibbles):
    """One mono IMA ADPCM block: header + nibbles packed low nibble first."""
    body = bytes((nibbles[i] | (nibbles[i + 1] << 4)) for i in range(0, len(nibbles), 2))
    return struct.pack('<hBB', predictor, index, 0) + body


def test_ima_block_decodes_by_the_standard_steps():
    # step 7 at index 0: nibble 4 adds 7 + 0 = 7 (diff = step>>3 + step); index 0 + 2 -> step 9
    block = _ima_block(100, 0, [4, 0, 0, 0, 0, 0, 0, 0])
    samples = wav_pcm.decode_ima_adpcm(block, 1, len(block))
    assert samples[0] == 100
    assert samples[1] == 100 + (7 >> 3) + 7
    assert len(samples) == 1 + 8


def test_pcm_is_copied_unchanged(tmp_path):
    src, dst = str(tmp_path / 'a.wav'), str(tmp_path / 'b.wav')
    with wave.open(src, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(struct.pack('<4h', 0, 100, -100, 5))
    assert wav_pcm.copy_as_pcm(src, dst) == wav_pcm.WAVE_FORMAT_PCM
    assert open(src, 'rb').read() == open(dst, 'rb').read()


def test_every_exported_sound_is_pcm():
    bad = []
    for path in glob.glob(os.path.join(P.pack('*'), 'audio', '**', '*.wav'), recursive=True):
        fmt = wav_pcm.read_chunks(open(path, 'rb').read())[b'fmt ']
        if struct.unpack_from('<H', fmt, 0)[0] != wav_pcm.WAVE_FORMAT_PCM:
            bad.append(path)
    assert not bad, bad
