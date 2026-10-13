"""Copies a WAV into a pack as plain PCM (the engine's WAV loader plays PCM only).

PCM files are copied byte for byte. IMA ADPCM (WAVE_FORMAT_IMA_ADPCM, 0x0011: Tribes 2 thrust.wav) is decoded to
16-bit PCM: each block starts with one header per channel (s16 predictor, u8 step index, u8 reserved), then 4-byte
words of eight 4-bit samples per channel, low nibble first (the Microsoft / IMA multimedia recommendation).
Any other codec fails loudly so a new one is noticed at import.
"""
import shutil
import struct
import wave

WAVE_FORMAT_PCM = 0x0001
WAVE_FORMAT_IMA_ADPCM = 0x0011

IMA_INDEX_TABLE = (-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8)
IMA_STEP_TABLE = (
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97,
    107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796,
    876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
    24623, 27086, 29794, 32767)
NIBBLES_PER_WORD = 8


def read_chunks(data):
    """{chunk id: bytes} of a RIFF WAVE file (the first of each id)."""
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise ValueError('not a RIFF WAVE file')
    chunks, at = {}, 12
    while at + 8 <= len(data):
        cid, size = data[at:at + 4], struct.unpack_from('<I', data, at + 4)[0]
        chunks.setdefault(cid, data[at + 8:at + 8 + size])
        at += 8 + size + (size & 1)
    return chunks


def copy_as_pcm(src, dst):
    """Copies the WAV `src` to `dst` as PCM; returns the source format tag."""
    with open(src, 'rb') as f:
        data = f.read()
    chunks = read_chunks(data)
    tag, channels, rate, _, block_align, bits = struct.unpack_from('<HHIIHH', chunks[b'fmt '], 0)
    if tag == WAVE_FORMAT_PCM:
        shutil.copyfile(src, dst)
    elif tag == WAVE_FORMAT_IMA_ADPCM:
        if bits != 4:
            raise ValueError('%s: IMA ADPCM with %d bits per sample' % (src, bits))
        samples = decode_ima_adpcm(chunks[b'data'], channels, block_align)
        if b'fact' in chunks:          # the last block is padded: the fact chunk holds the true length
            samples = samples[:struct.unpack_from('<I', chunks[b'fact'], 0)[0] * channels]
        _write_pcm16(dst, samples, channels, rate)
    else:
        raise ValueError('%s: unsupported WAV codec 0x%04x' % (src, tag))
    return tag


def decode_ima_adpcm(data, channels, block_align):
    """Interleaved signed 16-bit samples of IMA ADPCM `data` (whole blocks of `block_align` bytes)."""
    out = []
    for start in range(0, len(data) - 4 * channels + 1, block_align):
        out.extend(_decode_block(data[start:start + block_align], channels))
    return out


def _decode_block(block, channels):
    states = []
    for c in range(channels):
        predictor, index = struct.unpack_from('<hB', block, 4 * c)
        states.append([predictor, min(index, len(IMA_STEP_TABLE) - 1)])
    streams = [[s[0]] for s in states]
    at = 4 * channels
    while at + 4 * channels <= len(block):
        for c in range(channels):
            word = block[at:at + 4]
            for byte in word:
                for nibble in (byte & 0x0F, byte >> 4):
                    streams[c].append(_step(states[c], nibble))
            at += 4
    frames = min(len(s) for s in streams)
    return [streams[c][i] for i in range(frames) for c in range(channels)]


def _step(state, nibble):
    predictor, index = state
    step = IMA_STEP_TABLE[index]
    diff = step >> 3
    if nibble & 1:
        diff += step >> 2
    if nibble & 2:
        diff += step >> 1
    if nibble & 4:
        diff += step
    predictor = predictor - diff if nibble & 8 else predictor + diff
    predictor = max(-32768, min(32767, predictor))
    state[0] = predictor
    state[1] = max(0, min(len(IMA_STEP_TABLE) - 1, index + IMA_INDEX_TABLE[nibble]))
    return predictor


def _write_pcm16(path, samples, channels, rate):
    with wave.open(path, 'wb') as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(struct.pack('<%dh' % len(samples), *samples))
