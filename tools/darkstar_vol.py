"""Darkstar (Starsiege / Starsiege: Tribes) VOL archive reader.

Layout (after open-siege/siege-studio darkstar_resource.cpp, MIT; verified on the Tribes disc):

  "PVOL" u32 footerOffset
  data blocks, each: "VBLK" u24 storedSize u8 0x80, payload[storedSize], pad to 4
  at footerOffset:
    "vols" u32 namesSize, names (NUL-terminated, in index order), pad to 2
    "voli" u32 indexSize, indexSize/17 x {u32 id, u32 nameOffset, u32 blockOffset,
                                         u32 size, u8 compression}
  blockOffset points at the VBLK header; payload starts 8 bytes later.
  compression: 0 none, 1 RLE, 2 LZ, 3 LZH (Tribes 1.x shipping vols are all 0).

Older "VOL " (Starsiege) and " VOL" variants are recognised but only PVOL is exercised.

Usage:
  python tools/darkstar_vol.py list <file.vol>
  python tools/darkstar_vol.py extract <file.vol|dir> <outdir>   (dir: every *.vol under it)
"""
import glob, os, struct, sys
from collections import Counter


def read_vol(path):
    d = open(path, 'rb').read()
    tag = d[:4]
    if tag not in (b'PVOL', b' VOL'):
        raise ValueError('%s: unsupported VOL tag %r' % (path, tag))
    foot = struct.unpack_from('<I', d, 4)[0]
    p = foot
    if tag == b' VOL':
        # normal footer: 'vols' u32 ?, 4 ?, u32 ?, 4 ?, u32 namesSize
        p += 20
        nsize = struct.unpack_from('<I', d, p)[0]
        p += 4
    else:
        assert d[p:p + 4] == b'vols', (path, d[p:p + 4])
        nsize = struct.unpack_from('<I', d, p + 4)[0]
        p += 8
    names_raw = d[p:p + nsize]
    p += nsize
    if nsize % 2:
        p += 1
    assert d[p:p + 4] == b'voli', (path, p, d[p:p + 4])
    isize = struct.unpack_from('<I', d, p + 4)[0]
    p += 8
    entries = []
    for k in range(isize // 17):
        fid, noff, off, size, comp = struct.unpack_from('<IIIIB', d, p + 17 * k)
        name = names_raw[noff:names_raw.index(b'\0', noff)].decode('latin1') if noff < len(names_raw) else None
        entries.append({'id': fid, 'name': name, 'offset': off, 'size': size, 'comp': comp})
    # nameOffset may be zero in some writers: fall back to sequential names
    if any(e['name'] is None for e in entries) or len({e['name'] for e in entries}) < len(entries):
        seq = names_raw.split(b'\0')
        for e, n in zip(entries, seq):
            e['name'] = n.decode('latin1')
    return d, entries


def file_data(d, e):
    off = e['offset']
    assert d[off:off + 4] == b'VBLK', ('bad block', e)
    stored = struct.unpack_from('<I', d, off + 4)[0] & 0xFFFFFF
    raw = d[off + 8:off + 8 + stored]
    if e['comp'] == 0:
        return raw[:e['size']]
    raise NotImplementedError('compression %d (%s)' % (e['comp'], e['name']))


def extract(path, outdir):
    d, ents = read_vol(path)
    base = os.path.join(outdir, os.path.splitext(os.path.basename(path))[0])
    os.makedirs(base, exist_ok=True)
    n = 0
    for e in ents:
        if not e['name']:
            continue
        try:
            data = file_data(d, e)
        except NotImplementedError as ex:
            print('  skip', ex)
            continue
        dst = os.path.join(base, *e['name'].replace('\\', '/').split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(data)
        n += 1
    return n, len(ents)


def main(argv):
    if argv[0] == 'list':
        d, ents = read_vol(argv[1])
        print(len(ents), 'entries', Counter(e['comp'] for e in ents))
        for e in ents:
            print('%8d %d %s' % (e['size'], e['comp'], e['name']))
    elif argv[0] == 'extract':
        src, out = argv[1], argv[2]
        files = sorted(glob.glob(os.path.join(src, '**', '*.vol'), recursive=True)) if os.path.isdir(src) else [src]
        for f in files:
            n, total = extract(f, out)
            print('%-24s %4d/%d' % (os.path.basename(f), n, total))


if __name__ == '__main__':
    main(sys.argv[1:])
