"""One-step import: original Earthsiege disc image -> gamedata/es1 for the Godot remake.

    python tools/import_disc.py <iso dir>\\earth_siege.iso

Steps: copy the ISO file tree to original/, unpack every VOL archive into extracted/,
then run the asset converters into gamedata/es1/.
"""
import glob, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def extract_iso(iso_path, out_dir):
    import pycdlib
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    for root, _dirs, files in iso.walk(iso_path='/'):
        for f in files:
            p = root.rstrip('/') + '/' + f
            local = os.path.join(out_dir, p.lstrip('/').split(';')[0])
            os.makedirs(os.path.dirname(local), exist_ok=True)
            iso.get_file_from_iso(local, iso_path=p)
    iso.close()


def main():
    if len(sys.argv) > 1:
        print('extracting disc image ...')
        extract_iso(sys.argv[1], os.path.join(ROOT, 'original'))
    import vol
    print('unpacking VOL archives ...')
    for p in glob.glob(os.path.join(ROOT, 'original', 'VOL', '*.VOL')):
        vol.extract(p, os.path.join(ROOT, 'extracted'))
    print('converting assets ...')
    import export_es1
    export_es1.main()
    import subprocess, shutil
    print('exporting gameplay tables ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'units.py')])
    gp = os.path.join(ROOT, 'gamedata', 'es1', 'gameplay')
    os.makedirs(gp, exist_ok=True)
    for f in glob.glob(os.path.join(ROOT, 'extracted', 'gameplay', '*.json')):
        shutil.copy(f, gp)
    out = os.path.join(ROOT, 'gamedata', 'es1')
    print('exporting missions ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'export_missions.py'), os.path.join(out, 'missions')])
    print('converting audio ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'audio.py'), 'all', os.path.join(out, 'audio')])
    print('rendering music (OPL FM -> ogg) ...')
    try:
        import pyopl  # noqa: F401
    except ImportError:
        print('  skipped: pip install pyopl imageio-ffmpeg')
    else:
        subprocess.check_call([sys.executable, os.path.join(HERE, 'render_music.py'), 'all', 'es1',
                               os.path.join(out, 'audio', 'music')])
    print('converting video ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'video.py'), 'all', os.path.join(out, 'video')])
    print('exporting front-end shell ...')   # after video: uses the decoded ANM frames
    subprocess.check_call([sys.executable, os.path.join(HERE, 'export_shell.py'), os.path.join(out, 'shell')])
    print('exporting cockpit instruments ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'export_cockpit.py'), os.path.join(out, 'cockpit')])
    print('calibrating real-world units ...')
    subprocess.check_call([sys.executable, os.path.join(HERE, 'units_calib.py')])
    # Battledrome weapons / loadouts / weapon sounds (needs bd/installed and the gamedata/bd shapes from export_bd.py)
    if os.path.exists(os.path.join(ROOT, 'bd', 'installed', 'SIM.EXE')) and \
            os.path.isdir(os.path.join(ROOT, 'gamedata', 'bd', 'shapes')):
        print('exporting Battledrome weapons ...')
        subprocess.check_call([sys.executable, os.path.join(HERE, 'export_bd_weapons.py')])
    else:
        print('  Battledrome weapons skipped: run tools/bd_unchunk.py and tools/export_bd.py first')
    if os.path.isdir(os.path.join(ROOT, 'es2', 'extracted', 'SIMVOL0')):
        print('exporting Earthsiege 2 weapons ...')
        subprocess.check_call([sys.executable, os.path.join(HERE, 'export_es2_weapons.py')])


if __name__ == '__main__':
    main()
