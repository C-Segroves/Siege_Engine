"""Extract an ISO 9660 disc image (Joliet names preferred when present) into a directory.

Usage: python tools/extract_iso.py <image.iso> <outdir>

Writes <outdir>/_tree.txt (path, size) as a record of the disc file tree.
ISO9660-only discs (no Joliet) keep their 8.3 upper-case names with the ';1' version stripped.
"""
import os, sys
import pycdlib


def extract(iso_path, out):
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    joliet = iso.has_joliet()
    kw = 'joliet_path' if joliet else 'iso_path'
    tree = []
    for root, dirs, files in iso.walk(**{kw: '/'}):
        for f in files:
            src = (root.rstrip('/') + '/' + f)
            name = f.split(';')[0]
            if not joliet and name.endswith('.'):
                name = name[:-1]
            rel = (root.strip('/') + '/' + name).strip('/')
            dst = os.path.join(out, *rel.split('/'))
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if not os.path.exists(dst):
                with open(dst, 'wb') as fp:
                    iso.get_file_from_iso_fp(fp, **{kw: src})
            tree.append((rel, os.path.getsize(dst)))
    iso.close()
    tree.sort()
    with open(os.path.join(out, '_tree.txt'), 'w') as fp:
        for rel, size in tree:
            fp.write('%10d  %s\n' % (size, rel))
    return tree


if __name__ == '__main__':
    t = extract(sys.argv[1], sys.argv[2])
    print(len(t), 'files', sum(s for _, s in t), 'bytes')
