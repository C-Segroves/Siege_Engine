"""Copies the license texts of everything the frozen disc importer bundles into <out>/licenses/.

    python tools/collect_licenses.py <out folder>        (run by tools/build_importer.ps1)

The texts come from the installed packages (their dist-info license files) and the Python installation
(LICENSE.txt), so they always match the build. For the bundled ffmpeg (<out folder>/ffmpeg/ffmpeg.exe, the LGPL
build of tools/ffmpeg/build_ffmpeg.sh) build_importer.ps1 copies its BUILD.txt and license texts; this script
records `ffmpeg -L` / `ffmpeg -version` and fails unless it is that LGPL build and the only ffmpeg in the bundle.
THIRD_PARTY_NOTICES.md and the project's own LICENSE are copied alongside.
"""
import importlib.metadata as metadata
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GPL_FLAGS = ('--enable-gpl', '--enable-version3', '--enable-nonfree')
LICENSE_WORDS =('LICEN', 'COPYING', 'NOTICE', 'AUTHORS')
# distribution name -> required (False: optional, the build works without it)
DISTRIBUTIONS = {
    'pycdlib': True,
    'numpy': True,
    'Pillow': True,
    'PyOPL': False,
    'pyinstaller': True,      # bootloader (GPL-2.0-or-later with the bootloader exception)
    'altgraph': False,        # PyInstaller runtime helpers
    'pefile': False,
    'pywin32-ctypes': False,
}


def is_license_file(path):
    name = os.path.basename(str(path)).upper()
    return any(word in name for word in LICENSE_WORDS)


def copy_distribution(name, out_dir):
    """-> number of license files copied for distribution `name` (0 when it is not installed)."""
    try:
        dist = metadata.distribution(name)
    except metadata.PackageNotFoundError:
        return 0
    copied = 0
    target = os.path.join(out_dir, '%s-%s' % (name, dist.version))
    for f in dist.files or []:
        if not is_license_file(f) or '.dist-info' not in str(f):
            continue
        os.makedirs(target, exist_ok=True)
        shutil.copyfile(f.locate(), os.path.join(target, os.path.basename(str(f))))
        copied += 1
    return copied


def write_ffmpeg_licenses(importer_dir, out_dir):
    """Checks the bundled ffmpeg (<importer>/ffmpeg/ffmpeg.exe, tools/ffmpeg/build_ffmpeg.sh) is the LGPL build
    and records what it says about itself next to the BUILD.txt and license texts build_importer.ps1 copied."""
    exe = os.path.join(importer_dir, 'ffmpeg', 'ffmpeg.exe')
    if not os.path.isfile(exe):
        sys.exit('%s is missing (tools/build_importer.ps1 -Ffmpeg <dir>)' % exe)
    stray = [os.path.join(d, f) for d, _dirs, files in os.walk(importer_dir) for f in files
             if f.lower().startswith('ffmpeg') and f.lower().endswith('.exe') and os.path.join(d, f) != exe]
    if stray:
        sys.exit('other ffmpeg binaries are bundled (GPL builds must not ship): %s' % ', '.join(stray))
    target = os.path.join(out_dir, 'ffmpeg')
    os.makedirs(target, exist_ok=True)
    texts = {}
    for args, name in ((['-hide_banner', '-L'], 'ffmpeg-L.txt'), (['-hide_banner', '-version'], 'ffmpeg-version.txt')):
        texts[name] = subprocess.run([exe] + args, capture_output=True, text=True, check=True).stdout
        with open(os.path.join(target, name), 'w', encoding='utf-8') as fh:
            fh.write(texts[name])
    config = texts['ffmpeg-version.txt']
    if 'Lesser General Public License' not in texts['ffmpeg-L.txt'] or any(
            flag in config for flag in GPL_FLAGS):
        sys.exit('the bundled ffmpeg is not the LGPL build of tools/ffmpeg/build_ffmpeg.sh')
    for required in ('BUILD.txt', 'FFmpeg-COPYING.LGPLv2.1.txt'):
        if not os.path.exists(os.path.join(target, required)):
            sys.exit('%s missing from %s (tools/build_importer.ps1 copies it from the ffmpeg build)'
                     % (required, target))


def main(argv):
    if len(argv) != 2:
        sys.exit('usage: python tools/collect_licenses.py <out folder>')
    out_dir = os.path.join(argv[1], 'licenses')
    os.makedirs(out_dir, exist_ok=True)
    missing = []
    for name, required in DISTRIBUTIONS.items():
        if copy_distribution(name, out_dir) == 0 and required:
            missing.append(name)
    python_license = os.path.join(sys.base_prefix, 'LICENSE.txt')
    if os.path.exists(python_license):
        shutil.copyfile(python_license, os.path.join(out_dir, 'Python-%d.%d-LICENSE.txt' % sys.version_info[:2]))
    else:
        missing.append('Python LICENSE.txt')
    write_ffmpeg_licenses(argv[1], out_dir)
    shutil.copyfile(os.path.join(ROOT, 'THIRD_PARTY_NOTICES.md'), os.path.join(argv[1], 'THIRD_PARTY_NOTICES.md'))
    shutil.copyfile(os.path.join(ROOT, 'LICENSE'), os.path.join(out_dir, 'SiegeEngine-LICENSE.txt'))
    if missing:
        sys.exit('license texts not found for: %s' % ', '.join(missing))
    print('licenses written to %s' % out_dir)


if __name__ == '__main__':
    main(sys.argv)
