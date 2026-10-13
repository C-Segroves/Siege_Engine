"""Earthsiege 2 VOL archives -> es2/extracted/<VOL>/<DIR>/<FILE>.

ES2 uses exactly the Earthsiege 1 `VOLN` layout (see docs/RE_NOTES.md): every entry on the
disc is type 0x02 (stored), so tools/vol.py reads them unchanged. Header flags differ
(SIM*.VOL = 01000000, ZONES = 01010000, shell = 00010000) but are not needed for reading.

Usage: python tools/es2_vol.py [--list]
"""
import glob, os, sys
sys.path.insert(0, os.path.dirname(__file__))
import vol

import siege_paths as P  # noqa: E402
SRC = P.work('es2', 'original', 'VOL')
OUT = P.work('es2', 'extracted')


def main():
    total = 0
    for path in sorted(glob.glob(os.path.join(SRC, '*.VOL'))):
        if '--list' in sys.argv:
            d, flags, dirs, ents = vol.read_vol(path)
            print(os.path.basename(path), flags.hex(), len(ents), [x.rstrip('\\') for x in dirs])
            continue
        n = vol.extract(path, OUT)
        print(os.path.basename(path), n)
        total += n
    print('total', total)


if __name__ == '__main__':
    main()
