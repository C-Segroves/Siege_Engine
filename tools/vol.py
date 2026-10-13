"""Earth Siege (Dynamix, 1994) VOLN archive reader."""
import struct, sys, os
from collections import Counter

def read_vol(path):
    d = open(path, 'rb').read()
    assert d[:4] == b'VOLN', path
    flags = d[4:8]
    ndirs = d[9]
    dlen = struct.unpack_from('<H', d, 10)[0]
    dirs = [s.decode('latin1') for s in d[12:12+dlen].split(b'\0')[:ndirs]]
    p = 12 + dlen
    count, isize = struct.unpack_from('<HI', d, p)
    p += 6
    entries = []
    for i in range(count):
        name = d[p:p+13].split(b'\0')[0].decode('latin1')
        di = d[p+13]
        off = struct.unpack_from('<I', d, p+14)[0]
        entries.append((name, dirs[di] if di < len(dirs) else '?%d' % di, off))
        p += 18
    return d, flags, dirs, entries

if __name__ == '__main__':
    for path in sys.argv[1:]:
        d, flags, dirs, ents = read_vol(path)
        print('==', path, flags.hex(), dirs, len(ents))
        offs = sorted(e[2] for e in ents) + [len(d)]
        types = Counter()
        for name, dn, off in ents:
            t = d[off]; size = struct.unpack_from('<I', d, off+1)[0]
            nxt = offs[offs.index(off)+1]
            types[(t, nxt-off-size)] += 1
        print('  (type, block-size) :', dict(types))

def extract(path, outdir):
    d, flags, dirs, ents = read_vol(path)
    base = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0].upper())
    for name, dn, off in ents:
        size = struct.unpack_from('<I', d, off+1)[0]
        sub = os.path.join(base, dn.rstrip(chr(92)).upper())
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, name.upper()), 'wb') as f:
            f.write(d[off+9:off+9+size])
    return len(ents)
