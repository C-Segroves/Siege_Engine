#!/usr/bin/env python3
"""Imports every recognised disc image in a folder with the Siege Engine importer (tools/siege_import.py).

    import_discs.py --importer tools/siege_import.py --iso-dir DIR --out DIR
                    [--python PYTHON] [--packs "es1 bd" | --packs all] [--soundtracks DIR]

Each .iso / .cue (or a .bin without a .cue) below --iso-dir is identified; discs of one game are grouped (so
multi-disc games import together) and every wanted game is imported into --out/<pack>. Discs of other games
are skipped. --soundtracks imports ripped soundtrack folders into --out/_soundtracks.
Prints the importer's progress; exits 1 when any import failed (the other packs are still imported).
Used by deploy/siege-update.sh.
"""
import argparse
import json
import os
import subprocess
import sys

DISC_EXTENSIONS = ('.iso', '.cue', '.bin')
ALL = 'all'


def find_discs(root):
    """Disc images below root, sorted; a .bin is left out when a .cue of the same name exists."""
    found = []
    for folder, _dirs, files in os.walk(root, followlinks=True):
        lower = {f.lower() for f in files}
        for f in files:
            stem, ext = os.path.splitext(f.lower())
            if ext not in DISC_EXTENSIONS:
                continue
            if ext == '.bin' and stem + '.cue' in lower:
                continue
            found.append(os.path.join(folder, f))
    return sorted(found)


def make_command(args, *cli):
    return [args.python, args.importer] + list(cli)


def identify(args, disc):
    """-> the importer's identify answer (a dict; {"error": ...} when the disc is not recognised)."""
    run = subprocess.run(make_command(args, 'identify', disc), capture_output=True, text=True)
    for line in run.stdout.splitlines():
        try:
            answer = json.loads(line)
        except ValueError:
            continue
        if isinstance(answer, dict):
            return answer
    return {'error': 'no answer from the importer (%s)' % run.stderr.strip()[-200:]}


def group_by_pack(args, discs, wanted):
    """-> {pack: [disc paths]} for the recognised, supported discs of the wanted games."""
    groups = {}
    for disc in discs:
        info = identify(args, disc)
        name = os.path.basename(disc)
        if 'error' in info:
            print('skip %s: %s' % (name, info['error']), flush=True)
        elif info.get('supported') is False:
            print('skip %s: %s is not supported by the importer yet' % (name, info.get('name')), flush=True)
        elif wanted != ALL and info['pack'] not in wanted:
            print('skip %s: %s is not in IMPORT_PACKS' % (name, info['pack']), flush=True)
        else:
            print('found %s: %s disc %s' % (name, info['name'], info.get('disc')), flush=True)
            groups.setdefault(info['pack'], []).append(disc)
    return groups


def run_importer(args, cli, title):
    """Runs one importer command, echoing its progress lines. -> True when it reported success."""
    print('==== %s' % title, flush=True)
    proc = subprocess.Popen(make_command(args, *cli), stdout=subprocess.PIPE, text=True)
    ok = False
    last_message = None
    for line in proc.stdout:
        line = line.strip()
        try:
            msg = json.loads(line)
        except ValueError:
            print(line, flush=True)
            continue
        if msg.get('error'):
            print('ERROR: %s' % msg['error'], flush=True)
        elif msg.get('done'):
            ok = True
        elif msg.get('message') and msg['message'] != last_message:   # the importer repeats a step's message as a heartbeat
            last_message = msg['message']
            print('  [%3d%%] %s' % (round(100 * float(msg.get('progress', 0))), last_message), flush=True)
    return proc.wait() == 0 and ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--importer', required=True)
    ap.add_argument('--iso-dir', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--python', default=sys.executable)
    ap.add_argument('--packs', default=ALL, help='"all" or pack ids separated by spaces or commas')
    ap.add_argument('--soundtracks', default='')
    args = ap.parse_args()
    wanted = ALL if args.packs.strip() in ('', ALL) else set(args.packs.replace(',', ' ').split())
    failed = []
    groups = group_by_pack(args, find_discs(args.iso_dir), wanted)
    for pack, discs in sorted(groups.items()):
        if not run_importer(args, ['import', '--out', args.out] + discs, 'import %s (%d disc(s))' % (pack, len(discs))):
            failed.append(pack)
    if args.soundtracks and os.path.isdir(args.soundtracks):
        if not run_importer(args, ['soundtracks', '--out', args.out, args.soundtracks], 'soundtracks'):
            failed.append('_soundtracks')
    print('imported: %s; failed: %s' % (', '.join(p for p in sorted(groups) if p not in failed) or 'none',
                                         ', '.join(failed) or 'none'), flush=True)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
