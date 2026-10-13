"""InstallShield 5 cabinet extractor (data1.hdr + data1.cab), pure Python.

Starsiege (1999) ships all game files inside `setup/data1.cab`; this replaces the external `unshield`
tool. Layout follows the documented unshield format (libunshield, MIT), version 5 only, single volume:

  common header (both files): "ISc(" u32 version (0x01005201 -> major 5), u32 volume_info,
                              u32 cab_descriptor_offset, u32 cab_descriptor_size
  cab descriptor (in .hdr at cab_descriptor_offset, offsets relative to it):
      +0x0c file_table_offset, +0x14 file_table_size, +0x1c directory_count, +0x28 file_count
  file table: (directory_count + file_count) x u32 offsets relative to cab_desc + file_table_offset;
      directories: offset -> NUL-terminated name
      files (v5):  u32 name_offset, u32 directory_index, u16 flags, u32 expanded_size,
                   u32 compressed_size, 0x14 bytes, u32 data_offset, md5[16]
      flags: 1 split, 2 obfuscated, 4 compressed, 8 invalid
  file data (in .cab at data_offset): compressed = sequence of {u16 n, n bytes raw deflate}
      until compressed_size bytes consumed; each chunk inflates independently.

Usage: python tools/installshield_cab.py list <data1.hdr>
       python tools/installshield_cab.py extract <data1.hdr> <outdir>
"""
import os, struct, sys, zlib


def read_index(hdr_path):
    d = open(hdr_path, 'rb').read()
    sig, ver, volinfo, cdo, cds = struct.unpack_from('<4sIIII', d, 0)
    assert sig == b'ISc(', sig
    major = (ver >> 12) & 0xF if (ver >> 24) == 1 else (ver >> 24)
    assert major == 5, 'only InstallShield 5 cabinets are supported (got %d)' % major
    fto, = struct.unpack_from('<I', d, cdo + 0x0c)
    ndir, = struct.unpack_from('<I', d, cdo + 0x1c)
    nfile, = struct.unpack_from('<I', d, cdo + 0x28)
    base = cdo + fto
    table = struct.unpack_from('<%dI' % (ndir + nfile), d, base)

    def cstr(o):
        return d[o:d.index(b'\0', o)].decode('latin1')

    dirs = [cstr(base + table[i]) for i in range(ndir)]
    files = []
    for i in range(nfile):
        p = base + table[ndir + i]
        noff, didx, flags, size, csize = struct.unpack_from('<IIHII', d, p)
        doff, = struct.unpack_from('<I', d, p + 18 + 0x14)
        files.append({'name': cstr(base + noff), 'dir': dirs[didx] if didx < ndir else '',
                      'flags': flags, 'size': size, 'csize': csize, 'offset': doff})
    return files


def file_data(cab, f):
    if f['flags'] & 8:
        return None
    raw = cab[f['offset']:f['offset'] + f['csize']]
    if not f['flags'] & 4:
        return raw[:f['size']]
    out, p = [], 0
    while p < len(raw):
        n, = struct.unpack_from('<H', raw, p)
        p += 2
        o = zlib.decompressobj(-15)
        out.append(o.decompress(raw[p:p + n] + b'\0'))
        p += n
    data = b''.join(out)
    assert len(data) == f['size'], (f['name'], len(data), f['size'])
    return data


def extract(hdr_path, outdir):
    files = read_index(hdr_path)
    cab = open(os.path.splitext(hdr_path)[0] + '.cab', 'rb').read()
    tree = []
    for f in files:
        data = file_data(cab, f)
        if data is None:
            continue
        rel = '/'.join(x for x in (f['dir'].replace('\\', '/').strip('/'), f['name']) if x)
        dst = os.path.join(outdir, *rel.split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as fp:
            fp.write(data)
        tree.append((rel, len(data)))
    tree.sort()
    with open(os.path.join(outdir, '_tree.txt'), 'w') as fp:
        for rel, size in tree:
            fp.write('%10d  %s\n' % (size, rel))
    return tree


if __name__ == '__main__':
    if sys.argv[1] == 'list':
        for f in read_index(sys.argv[2]):
            print('%10d %10d %x %s\\%s' % (f['size'], f['csize'], f['flags'], f['dir'], f['name']))
    else:
        t = extract(sys.argv[2], sys.argv[3])
        print(len(t), 'files', sum(s for _, s in t), 'bytes')
