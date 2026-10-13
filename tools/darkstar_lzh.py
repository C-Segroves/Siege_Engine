"""Darkstar VOL compression type 3 ("LZH") decoder.

Starsiege (1999) stores `scripts.vol` entries with compression 3. The algorithm is the classic
LZHUF (Okumura/Yoshizaki 1988: LZSS with a 4096-byte ring buffer pre-filled with spaces, lookahead 60,
threshold 2, adaptive Huffman for literals/lengths, static table + 6 raw bits for positions).
The VOL entry payload is the bit stream itself (no 4-byte length header: the uncompressed size comes
from the VOL index). Verified on every entry of Starsiege scripts.vol (output is plain TorqueScript text).

Use: from darkstar_lzh import decode; decode(payload, size) -> bytes
     python tools/darkstar_lzh.py <file.vol> <outdir>   (extract a VOL, decoding comp 0 and 3)
"""
import os, struct, sys

N, F, THRESHOLD = 4096, 60, 2
N_CHAR = 256 - THRESHOLD + F
T = N_CHAR * 2 - 1
R = T - 1
MAX_FREQ = 0x8000

D_CODE, D_LEN = [], []
for code_lo, code_hi, reps, ln in ((0, 0, 32, 3), (1, 3, 16, 4), (4, 11, 8, 5), (12, 23, 4, 6),
                                    (24, 47, 2, 7), (48, 63, 1, 8)):
    for c in range(code_lo, code_hi + 1):
        D_CODE += [c] * reps
        D_LEN += [ln] * reps
assert len(D_CODE) == 256


def decode(src, size, with_pos=False):
    freq = [0] * (T + 1)
    prnt = [0] * (T + N_CHAR)
    son = [0] * T
    for i in range(N_CHAR):
        freq[i] = 1
        son[i] = i + T
        prnt[i + T] = i
    i, j = 0, N_CHAR
    while j <= R:
        freq[j] = freq[i] + freq[i + 1]
        son[j] = i
        prnt[i] = prnt[i + 1] = j
        i += 2
        j += 1
    freq[T] = 0xFFFF
    prnt[R] = 0

    pos = 0
    bitbuf = 0
    bitcnt = 0
    nsrc = len(src)

    def getbit():
        nonlocal pos, bitbuf, bitcnt
        if bitcnt == 0:
            bitbuf = src[pos] if pos < nsrc else 0
            pos += 1
            bitcnt = 8
        bitcnt -= 1
        return (bitbuf >> bitcnt) & 1

    def getbyte():
        v = 0
        for _ in range(8):
            v = (v << 1) | getbit()
        return v

    def reconst():
        j = 0
        for i in range(T):
            if son[i] >= T:
                freq[j] = (freq[i] + 1) // 2
                son[j] = son[i]
                j += 1
        i, j = 0, N_CHAR
        while j < T:
            f = freq[i] + freq[i + 1]
            freq[j] = f
            k = j - 1
            while f < freq[k]:
                k -= 1
            k += 1
            freq[k + 1:j + 1] = freq[k:j]
            freq[k] = f
            son[k + 1:j + 1] = son[k:j]
            son[k] = i
            i += 2
            j += 1
        for i in range(T):
            k = son[i]
            if k >= T:
                prnt[k] = i
            else:
                prnt[k] = prnt[k + 1] = i

    def update(c):
        if freq[R] == MAX_FREQ:
            reconst()
        c = prnt[c + T]
        while True:
            freq[c] += 1
            k = freq[c]
            l = c + 1
            if k > freq[l]:
                l += 1
                while k > freq[l]:
                    l += 1
                l -= 1
                freq[c] = freq[l]
                freq[l] = k
                i = son[c]
                prnt[i] = l
                if i < T:
                    prnt[i + 1] = l
                j = son[l]
                son[l] = i
                prnt[j] = c
                if j < T:
                    prnt[j + 1] = c
                son[c] = j
                c = l
            c = prnt[c]
            if c == 0:
                break

    buf = bytearray(b' ' * N)
    r = N - F
    out = bytearray()
    while len(out) < size:
        c = son[R]
        while c < T:
            c = son[c + getbit()]
        c -= T
        update(c)
        if c < 256:
            out.append(c)
            buf[r] = c
            r = (r + 1) & (N - 1)
        else:
            i = getbyte()
            cc = D_CODE[i] << 6
            for _ in range(D_LEN[i] - 2):
                i = (i << 1) | getbit()
            p = cc | (i & 0x3F)
            i = (r - p - 1) & (N - 1)
            for k in range(c - 255 + THRESHOLD):
                b = buf[(i + k) & (N - 1)]
                out.append(b)
                buf[r] = b
                r = (r + 1) & (N - 1)
    if with_pos:   # bytes of src consumed (terrain blocks chain several streams)
        return bytes(out[:size]), pos
    return bytes(out[:size])


def entry_data(d, e):
    """The bytes of VOL entry `e` (darkstar_vol.read_vol) of volume bytes `d`; None for an unknown compression."""
    off = e['offset']
    stored = struct.unpack_from('<I', d, off + 4)[0] & 0xFFFFFF
    raw = d[off + 8:off + 8 + stored]
    if e['comp'] == 0:
        return raw[:e['size']]
    if e['comp'] == 3:
        return decode(raw, e['size'])
    return None


def extract(path, outdir):
    import darkstar_vol as V
    d, ents = V.read_vol(path)
    base = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0])
    n = 0
    for e in ents:
        data = entry_data(d, e)
        if data is None:
            print('  skip comp', e['comp'], e['name'])
            continue
        dst = os.path.join(base, *e['name'].replace('\\', '/').split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'wb').write(data)
        n += 1
    return n, len(ents)


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    print(extract(sys.argv[1], sys.argv[2]))
