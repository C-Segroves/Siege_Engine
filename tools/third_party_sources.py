"""The release's GPL / LGPL source obligations: the third-party-sources zip and the note that points to it.

    python tools/third_party_sources.py bundle --version <v> --ffmpeg-build <dir> --out <zip> [--url <release url>]
    python tools/third_party_sources.py notice --version <v> --out <file> [--url <release url>]

bundle: writes third-party-sources-<v>.zip, the Corresponding Source of every copyleft component a release ships:
  ffmpeg/          the pinned FFmpeg, libogg, libvorbis, libtheora archives (from <ffmpeg-build>/src, checked
                   against tools/ffmpeg/sources.lock), BUILD.txt (exact configure line) and the build scripts
  python/          the PyPI source distributions (sdists) of PyOPL (GPL-3.0-only) and pycdlib (LGPL-2.1-only),
                   at the versions installed in this Python, checked against the SHA-256 PyPI publishes
  siege-engine/    `git archive` of this repository at HEAD: the importer's own code and the build scripts
                   (tools/build_importer.ps1, tools/package_release.ps1, .github/workflows/release.yml)
  SOURCES.md       what each file is and how to rebuild the binaries from it
<ffmpeg-build> is the out dir of tools/ffmpeg/build_ffmpeg.sh. Downloaded sdists are cached in <ffmpeg-build>/../pypi.

notice: writes SOURCE-CODE.txt, the note shipped inside the release zip saying where that source is.

    python tools/third_party_sources.py zip --src <folder> --out <zip>

zip: zips a folder with standard '/' entry names (tools/package_release.ps1 uses it for the app zip).
"""
import argparse
import hashlib
import importlib.metadata as metadata
import json
import os
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FFMPEG_DIR = os.path.join(ROOT, 'tools', 'ffmpeg')
LOCK = os.path.join(FFMPEG_DIR, 'sources.lock')
# copyleft Python packages frozen into siege-importer.exe -> license (their sdists go into the bundle)
SDISTS = {'PyOPL': 'GPL-3.0-only (includes the DOSBox OPL emulator dbopl.cpp, GPL-2.0-or-later)',
          'pycdlib': 'LGPL-2.1-only'}
OFFER_YEARS = 3


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for block in iter(lambda: fh.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def read_lock(path=LOCK):
    """-> [(name, file, sha256, url)] from tools/ffmpeg/sources.lock."""
    rows = []
    with open(path, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith('#'):
                rows.append(tuple(line.split()[:4]))
    return rows


def pypi_sdist(name, version, cache):
    """Downloads <name>==<version>'s sdist from PyPI into cache (once) and checks PyPI's SHA-256 -> path."""
    with urllib.request.urlopen('https://pypi.org/pypi/%s/%s/json' % (name, version), timeout=60) as r:
        info = json.load(r)
    sdist = [u for u in info['urls'] if u['packagetype'] == 'sdist']
    if not sdist:
        raise SystemExit('PyPI has no source distribution of %s %s' % (name, version))
    entry = sdist[0]
    path = os.path.join(cache, entry['filename'])
    if not os.path.exists(path) or sha256(path) != entry['digests']['sha256']:
        os.makedirs(cache, exist_ok=True)
        urllib.request.urlretrieve(entry['url'], path)
    if sha256(path) != entry['digests']['sha256']:
        raise SystemExit('SHA-256 mismatch for %s' % entry['filename'])
    return path, entry['url']


def git_archive(dest):
    """`git archive HEAD` of this repository -> (zip path, commit) ; warns when the work tree has changes."""
    commit = subprocess.run(['git', '-C', ROOT, 'rev-parse', 'HEAD'], capture_output=True, text=True,
                            check=True).stdout.strip()
    dirty = subprocess.run(['git', '-C', ROOT, 'status', '--porcelain', '--untracked-files=no'],
                           capture_output=True, text=True, check=True).stdout.strip()
    if dirty:
        print('WARNING: the work tree has uncommitted changes; the source archive holds HEAD (%s) only. '
              'Build releases from a clean, tagged commit.' % commit[:12], file=sys.stderr)
    subprocess.run(['git', '-C', ROOT, 'archive', '--format=zip', '--prefix=siege-engine/', '-o', dest, 'HEAD'],
                   check=True)
    return dest, commit


def sources_md(version, ffmpeg_rows, sdists, commit, url):
    lines = [
        '# Third-party sources for Siege Engine %s' % version, '',
        'This archive is the Corresponding Source of the copyleft programs in `SiegeEngine-%s-win64.zip`, as '
        'required by the GNU GPL v3 (section 6) and the GNU LGPL v2.1 (section 6). '
        'The Siege Engine code itself is MIT licensed.' % version, '',
        '## Contents', '',
        '| file | what | license | sha256 | original location |', '|---|---|---|---|---|']
    for name, fname, digest, src in ffmpeg_rows:
        lic = 'LGPL-2.1-or-later' if name == 'ffmpeg' else 'BSD-3-Clause'
        lines.append('| `ffmpeg/%s` | %s source | %s | `%s` | %s |' % (fname, name, lic, digest, src))
    for name, (path, src, lic) in sdists.items():
        lines.append('| `python/%s` | %s source distribution (sdist) | %s | `%s` | %s |'
                     % (os.path.basename(path), name, lic, sha256(path), src))
    lines.append('| `siege-engine/siege-engine-src.zip` | this repository at commit `%s` (importer code, '
                 'build scripts) | MIT | | %s |' % (commit, url or 'the project repository'))
    lines += [
        '', '`ffmpeg/BUILD.txt` records the toolchain, every archive hash and the exact FFmpeg configure line. '
        '`ffmpeg/build_ffmpeg.sh` and `ffmpeg/sources.lock` are the scripts that produced `ffmpeg.exe`.', '',
        '## Rebuilding', '',
        '### ffmpeg.exe (`siege-importer/ffmpeg/ffmpeg.exe`)',
        'An LGPL-2.1-or-later FFmpeg (configured without `--enable-gpl`, `--enable-version3`, `--enable-nonfree`) with '
        'libogg, libvorbis and libtheora linked in statically. On Ubuntu (24.04 is what the release workflow uses), or '
        'in Docker:', '',
        '```sh',
        'mkdir -p build/src && cp ffmpeg/*.tar.xz build/src/      # use these archives instead of downloading',
        'bash ffmpeg/build_ffmpeg.sh --install-deps build         # as root (Docker/CI); without the flag install',
        '                                                         # mingw-w64, nasm, pkg-config, make yourself',
        '```', '',
        'Docker: `docker run --rm -v "$PWD:/w" -w /w ubuntu:24.04 bash ffmpeg/build_ffmpeg.sh --install-deps build`.',
        'The result is `build/ffmpeg/ffmpeg.exe`; replace `siege-importer/ffmpeg/ffmpeg.exe` with it (or with any '
        'other ffmpeg build: the importer runs it as a separate program, nothing is linked against it). Setting the '
        'environment variable `SIEGE_FFMPEG` to an ffmpeg.exe path also makes the importer use that program.', '',
        '### siege-importer.exe (PyOPL, pycdlib, the Siege Engine converters)',
        'Unpack `siege-engine/siege-engine-src.zip`, install Python 3 and `pip install -r tools/requirements.txt` '
        '(to use the sources here: `pip install python/<sdist>` for PyOPL / pycdlib, a C++ compiler is needed for PyOPL), '
        'then run `powershell -ExecutionPolicy Bypass -File tools\\build_importer.ps1 -Ffmpeg <dir of ffmpeg.exe>`. '
        'PyInstaller rebuilds `dist\\siege-importer\\` with your modified packages; copy it over the release\'s '
        '`siege-importer` folder. PyInstaller\'s bootloader is GPL-2.0-or-later with the bootloader exception, which '
        'allows distributing the frozen program without its source.', '',
        '## Written offer', '',
        offer_text(version, url).strip(), '']
    return '\n'.join(lines)


def offer_text(version, url):
    where = url or 'the release page this download came from'
    return (
        'Corresponding source\n'
        '====================\n'
        'Siege Engine %(v)s includes programs licensed under the GNU GPL v3 (PyOPL with the DOSBox OPL emulator,\n'
        'inside siege-importer.exe) and the GNU LGPL v2.1 (FFmpeg, siege-importer\\ffmpeg\\ffmpeg.exe; pycdlib).\n'
        'Their complete corresponding source code, with the scripts used to build them, is in\n'
        '"third-party-sources-%(v)s.zip", attached to the same release as this zip:\n'
        '    %(where)s\n'
        'The Siege Engine source (MIT) is the repository at the same release tag.\n\n'
        'The source is also available on request, for at least %(years)d years after the last release that included\n'
        'these binaries and to anyone who has a copy of them, for no more than the cost of physically performing the\n'
        'distribution: ask through the project repository\'s issue tracker. (GPLv3 section 6(b)/(d), LGPL v2.1\n'
        'section 6.)\n\n'
        'ffmpeg.exe is a separate program that the importer runs; nothing is linked against it, so it can be\n'
        'replaced by any other ffmpeg build (or set SIEGE_FFMPEG to an ffmpeg.exe path).\n'
        % {'v': version, 'where': where, 'years': OFFER_YEARS})


def bundle(args):
    build = os.path.abspath(args.ffmpeg_build)
    rows = read_lock()
    top = 'third-party-sources-%s/' % args.version
    sdists = {}
    for name, lic in SDISTS.items():
        try:
            version = metadata.version(name)
        except metadata.PackageNotFoundError:
            raise SystemExit('%s is not installed in this Python: install the version the importer is built with'
                             % name)
        path, src = pypi_sdist(name, version, os.path.join(os.path.dirname(build), 'pypi'))
        sdists[name] = (path, src, lic)
    with tempfile.TemporaryDirectory() as tmp:
        repo_zip, commit = git_archive(os.path.join(tmp, 'siege-engine-src.zip'))
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_STORED) as z:   # the archives are compressed already
            for name, fname, digest, _url in rows:
                path = os.path.join(build, 'src', fname)
                if not os.path.exists(path) or sha256(path) != digest:
                    raise SystemExit('%s missing or not matching sources.lock: run tools/ffmpeg/build_ffmpeg.sh'
                                     % path)
                z.write(path, top + 'ffmpeg/' + fname)
            build_txt = os.path.join(build, 'ffmpeg', 'BUILD.txt')
            if not os.path.exists(build_txt):
                raise SystemExit('%s missing: run tools/ffmpeg/build_ffmpeg.sh' % build_txt)
            z.write(build_txt, top + 'ffmpeg/BUILD.txt')
            for f in sorted(os.listdir(FFMPEG_DIR)):
                z.write(os.path.join(FFMPEG_DIR, f), top + 'ffmpeg/' + f)
            for path, _src, _lic in sdists.values():
                z.write(path, top + 'python/' + os.path.basename(path))
            z.write(repo_zip, top + 'siege-engine/siege-engine-src.zip')
            z.writestr(top + 'SOURCES.md', sources_md(args.version, rows, sdists, commit, args.url))
    print('third-party sources: %s (%.1f MB)' % (args.out, os.path.getsize(args.out) / 1e6))


def zip_folder(args):
    """Zips the contents of --src. Unlike Windows PowerShell 5's Compress-Archive, which stores entry names with
    backslashes (unzip on Linux / macOS then makes files named 'licenses\\x.txt'), names use '/' as the zip
    format requires."""
    src = os.path.abspath(args.src)
    if os.path.exists(args.out):
        os.remove(args.out)
    with zipfile.ZipFile(args.out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for folder, _dirs, files in os.walk(src):
            for f in sorted(files):
                path = os.path.join(folder, f)
                z.write(path, os.path.relpath(path, src).replace(os.sep, '/'))
    print('zip: %s (%.1f MB)' % (args.out, os.path.getsize(args.out) / 1e6))


def notice(args):
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='\r\n') as fh:
        fh.write(offer_text(args.version, args.url))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('bundle')
    b.add_argument('--ffmpeg-build', required=True)
    n = sub.add_parser('notice')
    for p in (b, n):
        p.add_argument('--version', required=True)
        p.add_argument('--out', required=True)
        p.add_argument('--url', default='')
    zp = sub.add_parser('zip')
    zp.add_argument('--src', required=True)
    zp.add_argument('--out', required=True)
    args = ap.parse_args(argv)
    {'bundle': bundle, 'notice': notice, 'zip': zip_folder}[args.cmd](args)


if __name__ == '__main__':
    main()
