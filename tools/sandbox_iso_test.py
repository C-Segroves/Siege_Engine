"""Sandbox test per disc image: a fresh player who owns only that one game.

For every disc image in --iso-dir the importer recognises, in <sandbox>/<image name>/:
  import  tools/siege_import.py import --out packs/ <image>   (the in-game import queue's command; a fresh, empty
          packs folder) -> time, errors, warnings, size, the detected release (pack.json "release")
  check   Godot headless on game/tests/single_pack_check.tscn with a fresh user store (store/, its settings.json
          pointing "data_dir" at packs/) -> library, campaign, arena battle with a bot, Tribes infantry / vehicle /
          training, Options, shape viewer, the cross-pack features; script errors in the log
  shots   the same check windowed, saving screenshots (library, Options, first battle) into shots/
  clean   deletes packs/ (the converted game data; big) - the reports, logs and screenshots stay
  table   writes each passed release's result into game/engine/tested_versions.json and refreshes the tables in
          docs/TESTED_VERSIONS.md and README.md (between their tested-table markers); not in the default stages
Then writes <sandbox>/report.md and report.json.

    python tools/sandbox_iso_test.py --sandbox <dir> --iso-dir <iso-dir> --godot <Godot console exe>
                                     [--only es1,tribes] [--stages import,check,shots,clean] [--jobs 3]
(--iso-dir and --godot default to the environment variables SIEGE_ISO_DIR and GODOT.)

Never touches the project's gamedata/ or the player's user:// files (UserStore test store, Assets "data_dir").
"""
import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
IMPORTER = os.path.join(HERE, 'siege_import.py')
CHECK_SCENE = 'res://tests/single_pack_check.tscn'
GODOT_ENV = 'GODOT'                 # the Godot 4 console executable
ISO_DIR_ENV = 'SIEGE_ISO_DIR'       # the folder of disc images
STAGES = ['import', 'check', 'shots', 'clean']
TABLE_FILE = os.path.join(REPO, 'game', 'engine', 'tested_versions.json')
DOC_FILE = os.path.join(REPO, 'docs', 'TESTED_VERSIONS.md')
README_FILE = os.path.join(REPO, 'README.md')
TABLE_START = '<!-- tested-table:start -->'
TABLE_END = '<!-- tested-table:end -->'
README_HASH_CHARS = 16
IMAGE_SUFFIXES = ('.iso', '.cue')
CHECK_TIMEOUT_S = 900
IMPORT_TIMEOUT_S = 3 * 3600
WARNING_LINE = re.compile(r'\b(warning|warn)\b', re.IGNORECASE)
SCRIPT_ERROR_LINE = re.compile(r'SCRIPT ERROR|Parse Error|Invalid call|Invalid access|Cannot call method|'
                               r'Attempt to call|Nonexistent function|Out of bounds')
ENGINE_ERROR_LINE = re.compile(r'^\s*ERROR:')


# ---------------------------------------------------------------------------------------------- discs
def find_discs(iso_dir, only):
    """[(image path, identify info)] for the images the importer recognises (others are skipped)."""
    out = []
    for name in sorted(os.listdir(iso_dir)):
        path = os.path.join(iso_dir, name)
        if not name.lower().endswith(IMAGE_SUFFIXES) or not os.path.isfile(path):
            continue
        info = run_identify(path)
        if 'error' in info:
            continue
        for pack in info.get('also', [info['pack']]):      # a combined disc: one entry per pack
            if only and pack not in only:
                continue
            out.append((path, info if pack == info['pack'] else run_identify(path, pack)))
    return out


def split_duplicate_images(discs):
    """-> (discs, {duplicate image: the image it is identical to}); byte-identical images (a bad rip of disc 2 that
    is a copy of disc 1) are tested once. Only images of equal size are hashed."""
    import disc_version
    sizes = [os.path.getsize(p) for p, _ in discs]
    seen, kept, dupes = {}, [], {}
    for (path, info), size in zip(discs, sizes):
        key = (info['pack'], size, disc_version.make_file_sha256(path) if sizes.count(size) > 1 else path)
        if key in seen:
            dupes[path] = seen[key]
            continue
        seen[key] = path
        kept.append((path, info))
    return kept, dupes


def run_identify(path, pack=None):
    r = subprocess.run([sys.executable, IMPORTER, 'identify'] + (['--game', pack] if pack else []) + [path], capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.strip().startswith('{')]
    return json.loads(lines[-1]) if lines else {'error': r.stderr.strip() or 'no answer'}


# ---------------------------------------------------------------------------------------------- import
def run_import(box, image, info):
    """Imports one image into box/packs (emptied first) -> result dict."""
    packs = os.path.join(box, 'packs')
    shutil.rmtree(packs, ignore_errors=True)
    os.makedirs(packs)
    t0 = time.time()
    proc = subprocess.run([sys.executable, IMPORTER, 'import', '--game', info['pack'], '--out', packs, image],
                          capture_output=True, text=True, timeout=IMPORT_TIMEOUT_S)
    seconds = round(time.time() - t0, 1)
    events = [json.loads(l) for l in proc.stdout.splitlines() if l.strip().startswith('{')]
    errors = [e['error'] for e in events if 'error' in e]
    log = copy_import_log(box, info['pack'])
    result = {'seconds': seconds, 'exit_code': proc.returncode, 'errors': errors, 'ok': proc.returncode == 0,
              'warnings': count_warnings(log), 'bytes': tree_size(packs), 'stderr_tail': proc.stderr[-2000:]}
    meta = read_json(os.path.join(packs, info['pack'], 'pack.json'))
    if meta:
        result['notes'] = meta.get('importer', {}).get('notes', [])
        result['release'] = meta.get('release', {})
        result['provides'] = meta.get('provides', {})
    write_json(os.path.join(box, 'import.json'), result)
    return result


def copy_import_log(box, pack):
    src = os.path.join(tempfile.gettempdir(), 'siege-import-%s.log' % pack)
    dst = os.path.join(box, 'import.log')
    if os.path.exists(src):
        shutil.copy(src, dst)
    return dst


def count_warnings(log):
    try:
        with open(log, encoding='utf-8', errors='replace') as f:
            return sum(1 for l in f if WARNING_LINE.search(l))
    except OSError:
        return 0


def tree_size(path):
    total = 0
    for root, _dirs, files in os.walk(path):
        total += sum(os.path.getsize(os.path.join(root, f)) for f in files)
    return total


# ---------------------------------------------------------------------------------------------- Godot runs
def make_fresh_store(box):
    """A new, empty user store whose settings point the data folder at box/packs."""
    store = os.path.join(box, 'store')
    shutil.rmtree(store, ignore_errors=True)
    os.makedirs(store)
    write_json(os.path.join(store, 'settings.json'), {'data_dir': os.path.join(box, 'packs').replace('\\', '/')})
    return store


def run_check(box, info, godot, windowed):
    """single_pack_check in Godot -> its report dict (+ the log's script errors)."""
    box = os.path.abspath(box)
    kind = 'shots' if windowed else 'check'
    store = make_fresh_store(box)
    report_path = os.path.join(box, '%s_report.json' % kind)
    if os.path.exists(report_path):
        os.remove(report_path)
    log_path = os.path.join(box, '%s.log' % kind)
    cmd = [godot, '--audio-driver', 'Dummy', '--path', os.path.join(REPO, 'game')]
    if not windowed:
        cmd.insert(1, '--headless')
    cmd += [CHECK_SCENE, '--', '--test-store=' + store.replace('\\', '/'), '--expect-pack=' + info['pack'],
            '--report=' + report_path.replace('\\', '/')]
    if windowed:
        shots = os.path.join(box, 'shots')
        os.makedirs(shots, exist_ok=True)
        cmd.append('--shots=' + shots.replace('\\', '/'))
    t0 = time.time()
    with open(log_path, 'w', encoding='utf-8', errors='replace') as log:
        try:
            code = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=CHECK_TIMEOUT_S).returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    report = read_json(report_path) or {'ok': False, 'checks': [], 'error': 'no report written'}
    report['exit_code'] = code
    report['seconds'] = round(time.time() - t0, 1)
    report['log_errors'] = scan_log(log_path)
    write_json(report_path, report)
    return report


def scan_log(log_path):
    """Script errors and engine errors in a Godot log (each line once)."""
    script, engine = [], []
    with open(log_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip()
            if SCRIPT_ERROR_LINE.search(line) and line not in script:
                script.append(line)
            elif ENGINE_ERROR_LINE.search(line) and line not in engine:
                engine.append(line)
    return {'script': script, 'engine': engine}


# ---------------------------------------------------------------------------------------------- report
def make_summary_rows(results):
    rows = []
    for name, r in sorted(results.items()):
        imp, chk = r.get('import', {}), r.get('check', {})
        checks = chk.get('checks', [])
        failed = [c['name'] for c in checks if not c.get('ok')]
        rows.append({
            'image': name, 'pack': r['info'].get('pack', ''), 'disc': r['info'].get('disc', 1),
            'import_ok': imp.get('ok'), 'import_s': imp.get('seconds'), 'import_mb': round(imp.get('bytes', 0) / 2**20),
            'import_errors': imp.get('errors', []), 'warnings': imp.get('warnings', 0),
            'version': make_release_text(imp.get('release', {})), 'identical_to': r['info'].get('identical_to', ''),
            'checks_passed': len(checks) - len(failed),
            'checks': len(checks), 'failed': failed,
            'script_errors': len(chk.get('log_errors', {}).get('script', [])),
        })
    return rows


def make_release_text(release):
    """'1.000r' / 'build 21570' / 'built Dec 15 1998 ...' from pack.json "release" ('' when none)."""
    parts = [release.get('version', '')]
    if release.get('build'):
        parts.append('build %s' % release['build'])
    if release.get('build_date') and not release.get('version'):
        parts.append('built %s' % release['build_date'])
    return ', '.join(p for p in parts if p)


def write_report(sandbox, results):
    write_json(os.path.join(sandbox, 'report.json'), results)
    lines = ['# Sandbox test per disc image', '',
             '| image | pack | import | MB | warnings | release | checks | failed | script errors |',
             '|---|---|---|---|---|---|---|---|---|']
    for row in make_summary_rows(results):
        if row['identical_to']:
            lines.append('| %s | - | byte-identical to %s: tested once | | | | | | |' % (row['image'], row['identical_to']))
            continue
        imp = ('ok %ss' % row['import_s']) if row['import_ok'] else ('FAILED: %s' % '; '.join(row['import_errors']))
        lines.append('| %s | %s | %s | %s | %s | %s | %s/%s | %s | %s |' % (
            row['image'], row['pack'], imp, row['import_mb'], row['warnings'], row['version'],
            row['checks_passed'], row['checks'], ', '.join(row['failed']) or '-', row['script_errors']))
    for name, r in sorted(results.items()):
        lines += ['', '## %s' % name, '']
        for c in r.get('check', {}).get('checks', []):
            lines.append('- %s **%s**: %s' % ('ok' if c.get('ok') else 'FAIL', c['name'], c.get('detail', '')))
        for e in r.get('check', {}).get('log_errors', {}).get('script', [])[:20]:
            lines.append('- script error: `%s`' % e)
    with open(os.path.join(sandbox, 'report.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')


# ---------------------------------------------------------------------------------------------- tested table
def make_result_text(result):
    """'passed: import + 25/25 sandbox checks (2026-10-12)' from one disc's result ('' when it did not run)."""
    checks = result.get('check', {}).get('checks', [])
    if not result.get('import', {}).get('ok') or not checks:
        return ''
    passed = sum(1 for c in checks if c.get('ok'))
    verdict = 'passed' if passed == len(checks) else 'FAILED'
    return '%s: import + %d/%d sandbox checks%s (%s)' % (verdict, passed, len(checks), make_scope_note(checks),
                                                          time.strftime('%Y-%m-%d'))


def make_scope_note(checks):
    """', training missions' (Tribes), ', no campaign' (a game without one) or '' (a campaign was flown)."""
    names = {c['name'] for c in checks}
    if 'training mission loads' in names:
        return ', training missions'
    return '' if 'first campaign mission builds' in names else ', no campaign'


def apply_results_to_table(results):
    """Sets "result" of each tested release whose executable a sandbox run imported; refreshes the markdown tables."""
    table = read_json(TABLE_FILE)
    by_exe = {r.get('import', {}).get('release', {}).get('exe_sha256'): r for r in results.values()}
    for entry in table['releases']:
        text = make_result_text(by_exe.get(entry['exe_sha256'], {}))
        if text:
            entry['result'] = text
    table['tested'] = time.strftime('%Y-%m-%d')
    with open(TABLE_FILE, 'w', encoding='utf-8', newline='\n') as f:
        f.write(make_table_json(table))
    replace_marked_table(DOC_FILE, make_doc_table(table['releases']))
    replace_marked_table(README_FILE, make_readme_table(table['releases']))


def make_table_json(table):
    """tested_versions.json text: one release object per line group, as written by hand."""
    rows = [' ' + json.dumps(e) for e in table['releases']]
    head = {k: v for k, v in table.items() if k != 'releases'}
    lines = ['{'] + [' %s: %s,' % (json.dumps(k), json.dumps(v)) for k, v in head.items()]
    return '\n'.join(lines + [' "releases": [', ',\n'.join(rows), ' ]', '}']) + '\n'


def make_doc_table(releases):
    rows = ['| Game | Version | Patch level | Main exe (SHA-256) | Disc image SHA-256 | Volume label / mastered | Result |',
            '|---|---|---|---|---|---|---|']
    for e in releases:
        rows.append('| %s | %s | %s | %s `%s` | `%s` | %s / %s | %s |' % (
            e['name'], e['version'], e['patch'], e['exe'], e['exe_sha256'], e['disc_sha256'], e['label'] or '(none)',
            e['mastered'], e['result']))
    return '\n'.join(rows)


def make_readme_table(releases):
    rows = ['| Game | Version | Patch level | Main exe SHA-256 (first %d) | Result |' % README_HASH_CHARS,
            '|---|---|---|---|---|']
    for e in releases:
        rows.append('| %s | %s | %s | %s `%s` | %s |' % (e['name'], e['version'], e['patch'], e['exe'],
                                                       e['exe_sha256'][:README_HASH_CHARS], e['result']))
    return '\n'.join(rows)


def replace_marked_table(path, table):
    with open(path, encoding='utf-8') as f:
        text = f.read()
    start, end = text.find(TABLE_START), text.find(TABLE_END)
    if start < 0 or end < start:
        print('%s has no %s ... %s markers: table not refreshed' % (path, TABLE_START, TABLE_END))
        return
    text = text[:start + len(TABLE_START)] + '\n' + table + '\n' + text[end:]
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_json(path, obj):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1)


# ---------------------------------------------------------------------------------------------- main
def run_disc(sandbox, image, info, args):
    name = os.path.splitext(os.path.basename(image))[0]
    if info.get('also'):
        name += '-' + info['pack']             # a combined disc: one sandbox per pack
    box = os.path.join(sandbox, name)
    os.makedirs(box, exist_ok=True)
    result = read_json(os.path.join(box, 'result.json')) or {}
    result['info'] = info
    if 'import' in args.stages:          # a disc that cannot be imported alone records the importer's refusal
        result['import'] = run_import(box, image, info)
    importable = result.get('import', {}).get('ok')
    if importable and 'check' in args.stages:
        result['check'] = run_check(box, info, args.godot, windowed=False)
    if importable and 'shots' in args.stages:
        result['shots'] = run_check(box, info, args.godot, windowed=True)
    if 'clean' in args.stages:
        shutil.rmtree(os.path.join(box, 'packs'), ignore_errors=True)
        shutil.rmtree(os.path.join(box, 'store'), ignore_errors=True)
    write_json(os.path.join(box, 'result.json'), result)
    return name, result


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--sandbox', required=True)
    ap.add_argument('--iso-dir', default=os.environ.get(ISO_DIR_ENV, ''))
    ap.add_argument('--only', default='', help='comma-separated packs (es1,bd,es2,starsiege,tribes,tribes2)')
    ap.add_argument('--stages', default=','.join(STAGES))
    ap.add_argument('--jobs', type=int, default=3)
    ap.add_argument('--godot', default=os.environ.get(GODOT_ENV, ''))
    args = ap.parse_args(argv)
    if not args.iso_dir or not os.path.isdir(args.iso_dir):
        ap.error('--iso-dir (or %s) must name the folder of your disc images' % ISO_DIR_ENV)
    if not args.godot or not os.path.isfile(args.godot):
        ap.error('--godot (or %s) must name the Godot 4 console executable' % GODOT_ENV)
    args.stages = [s for s in args.stages.split(',') if s]
    sandbox = os.path.abspath(args.sandbox)
    os.makedirs(sandbox, exist_ok=True)
    discs, dupes = split_duplicate_images(find_discs(args.iso_dir, [p for p in args.only.split(',') if p]))
    for dupe, twin in dupes.items():
        print('%s is byte-identical to %s: tested once' % (os.path.basename(dupe), os.path.basename(twin)))
    print('discs: %s' % ', '.join('%s (%s disc %s)' % (os.path.basename(p), i['pack'], i['disc']) for p, i in discs))
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for name, result in pool.map(lambda d: run_disc(sandbox, d[0], d[1], args), discs):
            results[name] = result
            print('%s: import %s, checks %s' % (name, result.get('import', {}).get('ok'),
                                                result.get('check', {}).get('ok')), flush=True)
    previous = read_json(os.path.join(sandbox, 'report.json')) or {}
    previous.update(results)
    for dupe, twin in dupes.items():
        previous[os.path.splitext(os.path.basename(dupe))[0]] = {
            'info': {'pack': '', 'identical_to': os.path.basename(twin)}}
    write_report(sandbox, previous)
    if 'table' in args.stages:
        apply_results_to_table(previous)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
