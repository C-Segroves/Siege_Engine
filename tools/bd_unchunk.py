"""Unpack Metaltech: Battledrome's install archive (RESOURCE.000) like UNCHUNK.EXE does.

Container (reversed from UNCHUNK.EXE, LZEXE-0.91 packed Borland C++ 1991 program):
  repeated chunks:  char tag[4] ("OPN:" = open new output file, "CNT:" = continue the
                    previous file, appended in "a+b" mode), u32 chunkSize, payload[chunkSize]
  payload:          u8 method, u32 unpackedSize, compressed bytes
  methods:          0 = stored, 1 = RLE?, 2 = LZW-ish, 3 = LZHUF (Okumura/Yoshizaki 1988:
                    LZSS N=4096 F=60 THRESHOLD=2, adaptive Huffman for chars/lengths,
                    static table for the upper 6 position bits). Only method 3 is used.
  unpacked stream:  NUL-terminated relative file name (may contain '\\' sub dirs), then
                    the file data.

usage: python tools/bd_unchunk.py [RESOURCE.000] [outdir]
"""
import os, struct, sys, time

N, F, THRESHOLD = 4096, 60, 2
N_CHAR = 256 - THRESHOLD + F      # 314
T = N_CHAR * 2 - 1                # 627
R = T - 1                         # 626
MAX_FREQ = 0x8000

# position decoding tables (upper 6 bits), identical to LZHUF.C d_code/d_len and to the
# tables at DS:0x249 / DS:0x349 in UNCHUNK.EXE
def _build_tables():
    # d_code: 0x00 x32, 0x01..0x03 x16, 0x04..0x0B x8, 0x0C..0x17 x4, 0x18..0x2F x2, 0x30..0x3F x1
    dc, dl = [], []
    code = 0
    for reps, count, ln in ((32, 1, 3), (16, 3, 4), (8, 8, 5), (4, 12, 6), (2, 24, 7), (1, 16, 8)):
        for _ in range(count):
            dc += [code] * reps
            dl += [ln] * reps
            code += 1
    assert len(dc) == 256 and code == 64
    return dc, dl


D_CODE, D_LEN = _build_tables()


def lzhuf_decode(src, outsize):
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
    freq[T] = 0xffff
    prnt[R] = 0

    def reconst():
        j = 0
        for i in range(T):
            if son[i] >= T:
                freq[j] = (freq[i] + 1) >> 1
                son[j] = son[i]
                j += 1
        i = 0
        for j in range(N_CHAR, T):
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
        for i in range(T):
            k = son[i]
            if k >= T:
                prnt[k] = i
            else:
                prnt[k] = prnt[k + 1] = i

    # bit reader: MSB first; past the end reads zeros
    data = src + b'\0' * 8
    bitpos = 0
    text = bytearray(b' ' * (N - F) + b'\0' * F)
    r = N - F
    out = bytearray()
    nbytes = len(src) * 8
    while len(out) < outsize:
        # DecodeChar
        c = son[R]
        while c < T:
            c += (data[bitpos >> 3] >> (7 - (bitpos & 7))) & 1
            bitpos += 1
            c = son[c]
        c -= T
        # update(c)
        if freq[R] == MAX_FREQ:
            reconst()
        cc = prnt[c + T]
        while True:
            freq[cc] += 1
            k = freq[cc]
            l = cc + 1
            if k > freq[l]:
                l += 1
                while k > freq[l]:
                    l += 1
                l -= 1
                freq[cc] = freq[l]
                freq[l] = k
                i = son[cc]
                prnt[i] = l
                if i < T:
                    prnt[i + 1] = l
                j = son[l]
                son[l] = i
                prnt[j] = cc
                if j < T:
                    prnt[j + 1] = cc
                son[cc] = j
                cc = l
            cc = prnt[cc]
            if cc == 0:
                break
        if c < 256:
            out.append(c)
            text[r] = c
            r = (r + 1) & (N - 1)
        else:
            # DecodePosition
            p = bitpos >> 3
            sh = bitpos & 7
            w = ((data[p] << 16) | (data[p + 1] << 8) | data[p + 2]) << sh
            ib = (w >> 16) & 0xff
            bitpos += 8
            ln = D_LEN[ib] - 2
            if ln:
                w2 = ((w << 8) >> (24 - ln)) & ((1 << ln) - 1)
                ib = (ib << ln) | w2
                bitpos += ln
            pos = (D_CODE[(w >> 16) & 0xff] << 6) | (ib & 0x3f)
            i = (r - pos - 1) & (N - 1)
            ln = c - 255 + THRESHOLD
            for k in range(ln):
                ch = text[(i + k) & (N - 1)]
                out.append(ch)
                text[r] = ch
                r = (r + 1) & (N - 1)
        if bitpos > nbytes + 64:
            raise ValueError('compressed stream overrun')
    return bytes(out[:outsize])


def decode_payload(payload):
    method = payload[0]
    size = struct.unpack_from('<I', payload, 1)[0]
    body = payload[5:]
    if method == 0:
        return body[:size]
    if method == 3:
        return lzhuf_decode(body, size)
    raise NotImplementedError('compression method %d' % method)


def iter_chunks(blob):
    p = 0
    while p + 8 <= len(blob):
        tag = blob[p:p + 4]
        size = struct.unpack_from('<I', blob, p + 4)[0]
        yield p, tag, blob[p + 8:p + 8 + size]
        p += 8 + size


def unchunk(src, outdir, verbose=True):
    blob = open(src, 'rb').read()
    os.makedirs(outdir, exist_ok=True)
    cur = None
    files = []
    t0 = time.time()
    for off, tag, payload in iter_chunks(blob):
        data = decode_payload(payload)
        if tag == b'OPN:':
            z = data.index(b'\0')
            name = data[:z].decode('ascii')
            data = data[z + 1:]
            rel = name.replace('\\', '/')
            cur = os.path.join(outdir, rel)
            os.makedirs(os.path.dirname(cur) or outdir, exist_ok=True)
            open(cur, 'wb').write(data)
            files.append([name, len(data)])
            if verbose:
                print('Extracting: %-14s %8d' % (name, len(data)))
        elif tag == b'CNT:':
            z = data.index(b'\0')   # continuation chunks repeat the name
            open(cur, 'ab').write(data[z + 1:])
            files[-1][1] += len(data) - z - 1
            if verbose:
                print('Continuing extraction of: %s' % data[:z].decode('ascii'))
        else:
            raise ValueError('bad chunk tag %r at 0x%x' % (tag, off))
    if verbose:
        print('%d files, %d bytes, %.1fs' % (len(files), sum(s for _, s in files), time.time() - t0))
    return files


if __name__ == '__main__':
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import siege_paths as P
    src = sys.argv[1] if len(sys.argv) > 1 else P.work('bd', 'original', 'INSTALL', 'ENGLISH', 'RESOURCE.000')
    dst = sys.argv[2] if len(sys.argv) > 2 else P.work('bd', 'installed')
    unchunk(src, dst)
