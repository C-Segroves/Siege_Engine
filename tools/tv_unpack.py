"""Tribes: Vengeance unpack: TribesVengeance.zip (deflate64 members holding an Inno Setup installer) -> game files.

  python tools/tv_unpack.py <TribesVengeance.zip> <scratch folder>

1. The three members (setup.exe, setup-1.bin, setup-2.bin) are inflated with the `inflate64` package (Python's
   zipfile cannot read deflate64) into <scratch>/installer.
2. innoextract (zlib-licensed, separate program) unpacks the installer into <scratch>/game. It is taken from the
   environment variable SIEGE_INNOEXTRACT, from PATH, or downloaded once (release zip, SHA-256 pinned below) into
   tools/innoextract/.
Both folders are scratch: the caller deletes them after the import.
"""
import hashlib
import os
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
INNO_URL = 'https://constexpr.org/innoextract/files/innoextract-1.9-windows.zip'
INNO_SHA256 = '6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065'   # pinned when first fetched
INNO_DIR = os.path.join(HERE, 'innoextract')


def find_innoextract(download=True):
    env = os.environ.get('SIEGE_INNOEXTRACT')
    if env and os.path.isfile(env):
        return env
    found = shutil.which('innoextract')
    if found:
        return found
    exe = os.path.join(INNO_DIR, 'innoextract.exe')
    if os.path.isfile(exe):
        return exe
    if not download:
        return None
    os.makedirs(INNO_DIR, exist_ok=True)
    zpath = os.path.join(INNO_DIR, 'innoextract.zip')
    urllib.request.urlretrieve(INNO_URL, zpath)
    with open(zpath, 'rb') as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    if digest != INNO_SHA256:
        os.remove(zpath)
        raise RuntimeError('innoextract download failed its SHA-256 check (%s)' % digest)
    with zipfile.ZipFile(zpath) as z:
        z.extractall(INNO_DIR)
    os.remove(zpath)
    return exe


def inflate_member(zf, info, dst, progress=None):
    """Streams one deflate64 (method 9) or stored/deflate zip member to dst."""
    if info.compress_type != 9:
        with zf.open(info) as s, open(dst, 'wb') as d:
            shutil.copyfileobj(s, d, 1 << 20)
        return
    import inflate64
    with open(zf.filename, 'rb') as raw:
        raw.seek(info.header_offset)
        h = raw.read(30)
        if h[:4] != b'PK\x03\x04':
            raise ValueError('bad local header for %s' % info.filename)
        n, m = struct.unpack('<HH', h[26:30])
        raw.seek(info.header_offset + 30 + n + m)
        left, inf, done = info.compress_size, inflate64.Inflater(), 0
        with open(dst, 'wb') as out:
            while left > 0:
                chunk = raw.read(min(1 << 20, left))
                if not chunk:
                    raise ValueError('truncated zip member ' + info.filename)
                left -= len(chunk)
                data = inf.inflate(chunk)
                out.write(data)
                done += len(data)
                if progress:
                    progress(done, info.file_size)
    if done != info.file_size:
        raise ValueError('%s: inflated %d bytes, expected %d' % (info.filename, done, info.file_size))


def unzip_installer(zip_path, dst, progress=None):
    os.makedirs(dst, exist_ok=True)
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            target = os.path.join(dst, os.path.basename(info.filename))
            if os.path.isfile(target) and os.path.getsize(target) == info.file_size:
                continue
            inflate_member(zf, info, target, progress)
    return os.path.join(dst, 'setup.exe')


def run_innoextract(setup_exe, dst, only=None):
    """only = a file name: extract just the files of that name (innoextract --include matches names, not paths)."""
    exe = find_innoextract()
    os.makedirs(dst, exist_ok=True)
    filt = ['--include', only] if only else []
    r = subprocess.run([exe, '--silent', '--exclude-temp'] + filt + ['-d', dst, setup_exe])
    if r.returncode:
        raise RuntimeError('innoextract failed (exit %d)' % r.returncode)
    return dst


def unpack(zip_path, scratch):
    setup = unzip_installer(zip_path, os.path.join(scratch, 'installer'))
    game = run_innoextract(setup, os.path.join(scratch, 'game'))
    return game


def unpack_file(zip_path, scratch, name):
    """Only the installed file called `name` (the release identification needs just the main exe): its path."""
    setup = unzip_installer(zip_path, os.path.join(scratch, 'installer'))
    root = run_innoextract(setup, os.path.join(scratch, 'one'), only=name)
    for dirpath, _dirs, files in os.walk(root):
        if name in files:
            return os.path.join(dirpath, name)
    raise FileNotFoundError('%s is not in the installer' % name)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(unpack(sys.argv[1], sys.argv[2]))
