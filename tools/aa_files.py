"""Reader for Tribes: Aerial Assault's TRIBES/FILES.DAT (magic "SFDC"), straight from the ISO via pycdlib.

Layout (little endian, see docs/formats/aerial_assault.md): 10 header u32 (magic, version, sector size, ?, data base,
?, record bytes, record count, ...), then `count` 16-byte records (name_off, dir_off, start_sector, size), then the NUL
string table. Names and dirs are offsets into that table; data is at data_base + start_sector * sector.

    python tools/aa_files.py <iso> list [substring]
    python tools/aa_files.py <iso> extract <name-or-path> <out-file>
"""
import struct
import sys

MAGIC = b'SFDC'
HEADER = 40
REC = 16
SEP = chr(92)


class FilesDat:
    def __init__(self, fp, base=0):
        """fp: seekable binary file; base: byte offset of FILES.DAT inside it."""
        self.fp, self.base = fp, base
        head = self._read(0, HEADER)
        if head[:4] != MAGIC:
            raise ValueError('not an SFDC archive')
        w = struct.unpack('<10I', head)
        self.sector, self.data_base, rec_bytes, self.count = w[2], w[4], w[6], w[7]
        blob = self._read(HEADER, rec_bytes)
        strings_at = HEADER + rec_bytes
        strings_len = self.data_base - strings_at
        self._strings = self._read(strings_at, max(strings_len, 0))
        self.entries = []
        for i in range(self.count):
            name_off, dir_off, sector, size = struct.unpack_from('<4I', blob, i * REC)
            name = self._cstr(name_off)
            self.entries.append(((self._cstr(dir_off) + SEP + name) if dir_off else name, sector, size))

    def _read(self, off, n):
        self.fp.seek(self.base + off)
        return self.fp.read(n)

    def _cstr(self, off):
        end = self._strings.find(b'\0', off)
        return self._strings[off:end if end >= 0 else None].decode('latin-1')

    def list(self, sub=''):
        sub = sub.upper()
        return [(n, s, z) for n, s, z in self.entries if sub in n.upper()]

    def find(self, name):
        """Exact path (case-insensitive, either slash) or, failing that, a unique path suffix."""
        want = name.upper().replace('/', SEP)
        hits = [e for e in self.entries if e[0].upper() == want]
        if not hits:
            hits = [e for e in self.entries if e[0].upper().endswith(SEP + want.lstrip(SEP))]
        if not hits:
            raise KeyError(name)
        return hits[0]

    def read(self, name):
        _n, sector, size = self.find(name)
        return self._read(self.data_base + sector * self.sector, size)

    def extract(self, name, dst):
        with open(dst, 'wb') as f:
            f.write(self.read(name))


class IsoFilesDat(FilesDat):
    """FILES.DAT read in place from an ISO (needs pycdlib only to locate the extent)."""

    def __init__(self, iso_path, inner='/TRIBES/FILES.DAT;1'):
        import pycdlib
        iso = pycdlib.PyCdlib()
        iso.open(iso_path)
        try:
            rec = iso.get_record(iso_path=inner)
            start = rec.extent_location() * 2048
        finally:
            iso.close()
        self.iso_path = iso_path
        self._file = open(iso_path, 'rb')
        super().__init__(self._file, start)

    def close(self):
        self._file.close()


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    fd = IsoFilesDat(argv[0])
    if argv[1] == 'list':
        for n, s, z in fd.list(argv[2] if len(argv) > 2 else ''):
            print('%9d  %s' % (z, n))
    elif argv[1] == 'extract':
        fd.extract(argv[2], argv[3])
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
