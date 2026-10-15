"""Siege Engine disc importer: turns the user's original Dynamix discs (.iso) into content packs.

Command-line contract (game/engine/importer.gd):

  siege-importer identify [--game <pack>] <iso|cue|bin>
      -> one JSON line {"game", "pack", "name", "disc", "discs", "needs": [...], "audio_tracks": n, "also": [packs]}
         ("also" only on a disc holding several games: Starsiege + Tribes; --game picks one of them)
         or {"error": "..."}   (fast: reads only the disc's directory records)
  siege-importer import [--game <pack>] --out <packs_dir> <iso|cue|bin> [...]
      -> JSON lines {"stage", "progress": 0..1, "message"} then {"done": true, "pack": "<id>"}
         or {"error": "<human readable message>"}
  siege-importer games
      -> JSON list of the supported games
  siege-importer identify-release --pack <pack dir> <iso|cue|bin>
      -> {"done": true, "pack", "release"} or {"error"}: records the disc's release (version, build, exe hash) in an
         already imported pack's pack.json without converting anything (tools/disc_version.py)
  siege-importer run <tool> [args...]
      developer aid: runs tools/<tool>.py with SIEGE_WORK / SIEGE_PACKS from the environment

Disc images: .iso (data track only; CD-audio tracks ripped into a sibling folder named like the .iso are picked
up), or BIN/CUE (.cue, or a .bin next to its .cue) with data + audio tracks - see tools/siege_cd.py. Audio tracks
become <pack>/audio/cd/track_NN.ogg + tracks.json (the last import step).

Options for import: --work <dir> (scratch folder, kept afterwards; default a new folder in %TEMP% that is deleted
when the import ends), --keep-work (keep the default scratch folder too; for debugging).

Everything an exporter prints goes to a log file (%TEMP%/siege-import-<pack>.log, named in error messages);
stdout carries only the JSON protocol and stderr only a short failure summary, so a host that reads just
stdout can never block on a full stderr pipe.

The import runs in a scratch work folder (disc files, unpacked archives) and a staging copy of the pack;
the finished pack replaces <packs_dir>/<pack> only when every step succeeded.

Runs from source (python tools/siege_import.py ...) or frozen (tools/build_importer.ps1 -> siege-importer.exe).
"""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import traceback

IMPORTER_VERSION = '1.0.0'
HERE = os.path.dirname(os.path.abspath(__file__))
FROZEN = bool(getattr(sys, 'frozen', False))
RES = getattr(sys, '_MEIPASS', HERE)          # bundled data (pack_meta/) when frozen
if HERE not in sys.path:
    sys.path.insert(0, HERE)


# ---------------------------------------------------------------------------------------------- protocol
class Protocol:
    """JSON lines on the real stdout (kept even while exporter output is redirected to the log)."""

    def __init__(self):
        self.lock = threading.Lock()
        self.out = sys.stdout
        self.err = sys.stderr

    def emit(self, obj):
        with self.lock:
            try:
                self.out.write(json.dumps(obj) + '\n')
                self.out.flush()
            except (OSError, ValueError):
                pass   # host went away; keep going so the work folder is cleaned up

    def detail(self, text):
        with self.lock:
            try:
                self.err.write(text.rstrip() + '\n')
                self.err.flush()
            except (OSError, ValueError):
                pass


PROTO = Protocol()


class ImportFailed(Exception):
    """An expected failure with a message meant for the user."""


# ---------------------------------------------------------------------------------------------- identify
def identify_disc(path, want=None):
    """-> (game module, info dict) or raises ImportFailed. A disc that holds several games (Starsiege + Tribes)
    lists the other packs in info["also"]; want (a pack id) picks one of them, else the first is returned."""
    import siege_iso
    import siege_games
    if path.lower().endswith('.zip'):
        return _identify_zip(path)
    try:
        disc = siege_iso.Disc(path)
    except siege_iso.DiscError as e:
        raise ImportFailed(str(e))
    try:
        found = [(g, g.identify(disc)) for g in siege_games.GAMES]
        found = all_found = [(g, n) for g, n in found if n]
        if want:
            if not any(g.GAME['pack'] == want for g, _ in found):
                raise ImportFailed('%s does not hold the pack "%s".' % (os.path.basename(path), want))
            found = [(g, n) for g, n in found if g.GAME['pack'] == want]
        for g, n in found[:1]:
            if n:
                info = {'game': g.GAME['game'], 'pack': g.GAME['pack'], 'name': g.GAME['name'], 'disc': n,
                        'discs': g.GAME.get('discs', 1), 'needs': list(g.GAME.get('needs', {}).get(n, [])),
                        'label': disc.label, 'audio_tracks': len(disc.audio)}
                if not g.GAME.get('supported', True):
                    info['supported'] = False
                if len(all_found) > 1:
                    info['also'] = [o.GAME['pack'] for o, _ in all_found]
                return g, info
    finally:
        disc.close()
    raise ImportFailed('%s is not a disc this importer recognises (volume label "%s"). Supported: %s.' % (
        os.path.basename(path), disc.label, ', '.join(g.GAME['name'] for g in siege_games.GAMES)))


def _identify_zip(path):
    """A zip holding a game installer (Tribes: Vengeance) -> (game module, info) like identify_disc."""
    import zipfile
    import siege_games
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
    except (OSError, zipfile.BadZipFile) as e:
        raise ImportFailed('Could not read %s: %s' % (os.path.basename(path), e))
    for g in siege_games.GAMES:
        if hasattr(g, 'identify_zip') and g.identify_zip(names):
            info = {'game': g.GAME['game'], 'pack': g.GAME['pack'], 'name': g.GAME['name'], 'disc': 1,
                    'discs': 1, 'needs': [], 'label': '', 'audio_tracks': 0}
            if not g.GAME.get('supported', True):
                info['supported'] = False
            return g, info
    raise ImportFailed('%s is not an archive this importer recognises.' % os.path.basename(path))


def _take_option(args, name):
    """-> (value of `name <value>` or None, the other args)."""
    args = list(args)
    if name in args:
        i = args.index(name)
        value = args[i + 1] if i + 1 < len(args) else None
        del args[i:i + 2]
        return value, args
    return None, args


def cmd_identify(args):
    want, args = _take_option(args, '--game')
    if len(args) != 1:
        PROTO.emit({'error': 'usage: identify [--game <pack>] <iso|cue|bin>'})
        return 2
    try:
        _g, info = identify_disc(args[0], want)
    except ImportFailed as e:
        PROTO.emit({'error': str(e)})
        return 1
    except Exception as e:  # noqa: BLE001
        PROTO.emit({'error': 'Could not read %s: %s' % (os.path.basename(args[0]), e)})
        PROTO.detail(traceback.format_exc())
        return 1
    PROTO.emit(info)
    return 0


def cmd_games(_args):
    import siege_games
    PROTO.emit([{'game': g.GAME['game'], 'pack': g.GAME['pack'], 'name': g.GAME['name'],
                 'discs': g.GAME.get('discs', 1), 'supported': g.GAME.get('supported', True)}
                for g in siege_games.GAMES])
    return 0


# ---------------------------------------------------------------------------------------------- import context
class Context:
    """What a game module gets: the discs, the work folder, the staging pack folder, and helpers."""

    def __init__(self, game, discs, work, staging_packs, log_path):
        self.game = game                    # game module
        self.pack = game.GAME['pack']
        self.discs = discs                  # {disc number: siege_iso.Disc}
        self.work = work                    # = siege_paths.WORK
        self.packs = staging_packs          # = siege_paths.PACKS (staging; moved to --out at the end)
        self.out = os.path.join(staging_packs, self.pack)
        self.log_path = log_path
        self.notes = []                     # user-visible remarks collected during the import
        self._range = (0.0, 1.0)
        self._stage = ''

    # ---- paths
    def work_path(self, *p):
        return os.path.join(self.work, *p)

    def pack_path(self, *p):
        return os.path.join(self.out, *p)

    def disc(self, n=1):
        return self.discs.get(n)

    # ---- user-visible output
    def message(self, text, fraction=None):
        """Progress message; fraction is 0..1 within the current step."""
        a, b = self._range
        p = a + (b - a) * min(max(fraction, 0.0), 1.0) if fraction is not None else a
        PROTO.emit({'stage': self._stage, 'progress': round(p, 4), 'message': text})

    def note(self, text):
        self.notes.append(text)
        print('NOTE:', text)
        self.message(text)

    # ---- helpers
    def extract(self, disc_no, rel, dst, label=None):
        """Copy a file/dir from a disc into the work folder with byte-based progress."""
        d = self.discs[disc_no]
        total = max(1, d.size(rel))
        done = [0, time.time()]

        def prog(n):
            done[0] += n
            if time.time() - done[1] > 1.0:
                done[1] = time.time()
                self.message('%s (%d of %d MB)' % (label or 'Copying files from the disc', done[0] >> 20, total >> 20),
                             done[0] / total)
        return d.extract(rel, dst, prog)

    def run_tool(self, module, *argv):
        """Run tools/<module>.py as if from the command line (in-process; works frozen too)."""
        import runpy
        print('\n$ %s %s' % (module, ' '.join(str(a) for a in argv)), flush=True)
        old = sys.argv
        sys.argv = [module + '.py'] + [str(a) for a in argv]
        try:
            runpy.run_module(module, run_name='__main__', alter_sys=False)
        except SystemExit as e:
            if e.code not in (None, 0):
                raise ImportFailed('%s stopped: %s' % (module, e.code))
        finally:
            sys.argv = old
            sys.stdout.flush()


# ---------------------------------------------------------------------------------------------- output redirection
class Redirect:
    """Send fd 1/2 (prints and child processes such as ffmpeg) to the log; keep the protocol on the real stdout."""

    def __init__(self, log_path):
        self.log_path = log_path

    def __enter__(self):
        sys.stdout.flush()
        sys.stderr.flush()
        self.saved = (sys.stdout, sys.stderr)
        self.fd_out, self.fd_err = os.dup(1), os.dup(2)
        PROTO.out = os.fdopen(os.dup(1), 'w', encoding='utf-8', errors='replace')
        PROTO.err = os.fdopen(os.dup(2), 'w', encoding='utf-8', errors='replace')
        self.log = open(self.log_path, 'a', encoding='utf-8', errors='replace', buffering=1)
        os.dup2(self.log.fileno(), 1)
        os.dup2(self.log.fileno(), 2)
        sys.stdout = sys.stderr = self.log
        return self

    def __exit__(self, *a):
        try:
            self.log.flush()
        except Exception:
            pass
        os.dup2(self.fd_out, 1)
        os.dup2(self.fd_err, 2)
        os.close(self.fd_out)
        os.close(self.fd_err)
        sys.stdout, sys.stderr = self.saved
        self.log.close()
        return False


class Heartbeat(threading.Thread):
    """Moves the progress bar inside long steps (asymptotic towards the step's end)."""

    def __init__(self):
        super().__init__(daemon=True)
        self.state = None
        self.stop_flag = threading.Event()

    def set(self, stage, a, b, expected, message):
        self.state = (stage, a, b, max(expected, 1.0), message, time.time())

    def run(self):
        import math
        while not self.stop_flag.wait(2.0):
            s = self.state
            if not s:
                continue
            stage, a, b, exp_s, msg, t0 = s
            k = 1.0 - math.exp(-(time.time() - t0) / exp_s)
            PROTO.emit({'stage': stage, 'progress': round(a + (b - a) * 0.97 * k, 4), 'message': msg})


# ---------------------------------------------------------------------------------------------- CD audio
NO_CD_AUDIO = 'no CD audio found - music will be missing (see USER_TODO.md)'


def cd_audio_step(ctx):
    """Last step of every import: the disc's CD-audio tracks -> <pack>/audio/cd/track_NN.ogg + tracks.json.
    Game modules may define cd_audio_uses(ctx, numbers) -> {track: {"use", "name"?, ...}}; GAME['cd_audio']
    marks games whose discs are expected to carry CD audio (only those get the missing-music message)."""
    from siege_games import Step
    with_audio = sorted(((n, d) for n, d in ctx.discs.items() if d.audio), key=lambda nd: (-len(nd[1].audio), nd[0]))
    n_tracks = len(with_audio[0][1].audio) if with_audio else 0

    def run(ctx):
        if not with_audio:
            if ctx.game.GAME.get('cd_audio'):
                ctx.note(NO_CD_AUDIO)
            return
        disc_no, disc = with_audio[0]
        for n, d in with_audio[1:]:
            print('disc %d also has %d audio tracks - using disc %d' % (n, len(d.audio), disc_no))
        from video import ffmpeg_exe
        ff = ffmpeg_exe()
        if not ff:
            ctx.note('ffmpeg is missing - CD audio skipped')
            return
        uses = {}
        fn = getattr(ctx.game, 'cd_audio_uses', None)
        if fn:
            try:
                uses = fn(ctx, [t.number for t in disc.audio]) or {}
            except Exception as e:  # noqa: BLE001 - descriptions are optional
                print('cd_audio_uses failed: %s' % e)
        out_dir = ctx.pack_path('audio', 'cd')
        rows = []
        for i, t in enumerate(disc.audio):
            ctx.message('Converting CD audio track %d (%d of %d)' % (t.number, i + 1, len(disc.audio)), i / len(disc.audio))
            name = 'track_%02d.ogg' % t.number
            print('track %d: %r -> %s' % (t.number, t, name), flush=True)
            secs = t.encode_ogg(ff, os.path.join(out_dir, name), quality=6)
            row = {'track': t.number, 'file': name, 'seconds': secs, 'use': None}
            row.update(uses.get(t.number, {}))
            rows.append(row)
        with open(os.path.join(out_dir, 'tracks.json'), 'w') as f:
            json.dump(rows, f, indent=1)
        src = 'BIN/CUE image' if disc.audio_source == 'cue' else os.path.basename(disc.audio_source or '')
        ctx.notes.append('Converted %d CD audio tracks (%s)' % (len(rows), src))
        ctx.message(ctx.notes[-1], 1.0)

    return Step('cdaudio', 'Converting CD audio tracks...' if n_tracks else 'Looking for CD audio...',
                max(0.2, 5.0 * n_tracks), run)


# ---------------------------------------------------------------------------------------------- import
def _pid_alive(pid):
    if pid <= 0:
        return False
    if os.name == 'nt':
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return code.value == 259                                       # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _clean_stale_work_dirs():
    """Remove scratch folders of imports that were cancelled (process killed)."""
    tmp = tempfile.gettempdir()
    for d in os.listdir(tmp):
        if not d.startswith('siege-import-'):
            continue
        p = os.path.join(tmp, d)
        try:
            pid = int(open(os.path.join(p, 'importer.pid')).read().strip())
        except (OSError, ValueError):
            pid = -1
        if os.path.isdir(p) and not _pid_alive(pid):
            shutil.rmtree(p, ignore_errors=True)


def _install_pack(staged, dest):
    """Replace dest with staged (rename when possible, else copy)."""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    old = None
    if os.path.exists(dest):
        old = dest + '.old-%d' % os.getpid()
        try:
            os.rename(dest, old)
        except OSError:
            old = None
            shutil.rmtree(dest, ignore_errors=True)       # files in use: overwrite what we can
    try:
        shutil.move(staged, dest)
    except OSError:
        shutil.copytree(staged, dest, dirs_exist_ok=True)
    if old:
        shutil.rmtree(old, ignore_errors=True)


def _explain(e):
    """Exception -> sentence for the user."""
    import errno
    if isinstance(e, ImportFailed):
        return str(e)
    if isinstance(e, MemoryError):
        return 'Ran out of memory'
    if isinstance(e, OSError):
        if e.errno == errno.ENOSPC or getattr(e, 'winerror', None) in (39, 112):
            return 'Not enough free disk space'
        if e.errno in (errno.EACCES, errno.EPERM):
            return 'Permission denied writing %s' % (e.filename or 'a file')
        if e.errno == errno.ENOENT:
            return 'A file the converter needs is missing (%s) - is this the right disc, and is the image complete?' % (
                os.path.basename(str(e.filename)) if e.filename else e)
    if isinstance(e, (AssertionError, KeyError, IndexError, ValueError)):
        return 'Unexpected data on the disc (%s: %s) - this version of the disc may not be supported' % (
            type(e).__name__, str(e)[:200])
    return '%s: %s' % (type(e).__name__, str(e)[:300])


def _parse_import_args(args):
    """-> (out, work_arg, keep, isos, want) or None when the command line is incomplete.
    --game <pack> picks one pack of a disc that holds several games (Starsiege + Tribes)."""
    out, work_arg, keep, isos, want = None, None, False, [], None
    it = iter(args)
    for a in it:
        if a == '--game':
            want = next(it, None)
        elif a == '--out':
            out = next(it, None)
        elif a == '--work':
            work_arg = next(it, None)
        elif a == '--keep-work':
            keep = True
        else:
            isos.append(a)
    if not out or not isos:
        return None
    return os.path.abspath(out), work_arg, keep, _unique_discs(isos), want


def _unique_discs(isos):
    """A .cue and its .bin files dropped together are one disc."""
    import siege_cd
    seen, uniq = set(), []
    for p in isos:
        k = siege_cd.canonical(p)
        if k not in seen:
            seen.add(k)
            uniq.append(p)
    return uniq


def _identify_all(isos, want=None):
    """-> (game module, {disc number: (path, info)}); raises ImportFailed for discs of different games.
    A second image of the same disc number is reported and skipped."""
    game, infos = None, {}
    for p in isos:
        g, info = identify_disc(p, want)
        if game is not None and g is not game:
            raise ImportFailed('These discs belong to different games (%s and %s): import them separately.' % (
                game.GAME['name'], g.GAME['name']))
        game = g
        if info['disc'] in infos:
            PROTO.emit({'stage': 'identify', 'progress': 0.0,
                        'message': '%s and %s are both disc %d of %s - using the first.' % (
                            os.path.basename(infos[info['disc']][0]), os.path.basename(p), info['disc'], g.GAME['name'])})
            continue
        infos[info['disc']] = (p, info)
    return game, infos


def _import_refusal(G, infos):
    """-> error message when the game cannot be imported from these discs, else None."""
    if not G.get('supported', True):
        return '%s was recognised, but importing it is not supported yet.' % G['name']
    missing = [n for n in G.get('required_discs', [1]) if n not in infos]
    if missing:
        return '%s: disc %s is required for the import.' % (G['name'], ' and '.join(map(str, missing)))
    return None


def _new_log(pack):
    log_path = os.path.join(tempfile.gettempdir(), 'siege-import-%s.log' % pack)
    try:
        open(log_path, 'w').close()
    except OSError:
        log_path = os.devnull
    return log_path


def _prepare_work(work_arg, pack):
    """Work folder (scratch; the caller's or a new temp folder) with an empty staging pack folder;
    points the exporters (siege_paths, SIEGE_WORK/SIEGE_PACKS) at them. -> (work, staging)."""
    if work_arg:
        work = os.path.abspath(work_arg)
        os.makedirs(work, exist_ok=True)
    else:
        work = tempfile.mkdtemp(prefix='siege-import-%s-' % pack)
    with open(os.path.join(work, 'importer.pid'), 'w') as f:
        f.write(str(os.getpid()))
    staging = os.path.join(work, 'packs')
    if os.path.exists(os.path.join(staging, pack)):
        shutil.rmtree(os.path.join(staging, pack))
    os.makedirs(os.path.join(staging, pack), exist_ok=True)
    os.environ['SIEGE_WORK'] = work
    os.environ['SIEGE_PACKS'] = staging
    import siege_paths
    siege_paths.WORK, siege_paths.PACKS = work, staging     # in case it was imported already
    return work, staging


def _run_steps(ctx, steps, hb):
    """Runs the import steps in order, reporting progress weighted by each step's weight."""
    total = sum(s.weight for s in steps) or 1.0
    done = 0.0
    for s in steps:
        a, b = done / total, (done + s.weight) / total
        ctx._range, ctx._stage = (a, b), s.stage
        PROTO.emit({'stage': s.stage, 'progress': round(a, 4), 'message': s.message})
        hb.set(s.stage, a, b, s.weight, s.message)
        t0 = time.time()
        print('\n==== %s: %s' % (s.stage, s.message), flush=True)
        try:
            s.fn(ctx)
        except Exception as e:
            print(traceback.format_exc(), flush=True)
            raise ImportFailed('%s failed: %s' % (s.message.rstrip('.').rstrip(), _explain(e)))
        finally:
            hb.state = None
        print('==== %s done in %.1fs' % (s.stage, time.time() - t0), flush=True)
        done += s.weight


def _convert(game, infos, out, job):
    """Converts the discs into the staging pack and installs it into out. -> True on success.
    job: {work, staging, log_path, t_start, discs (filled with the open siege_iso.Disc objects)}."""
    import siege_iso
    G = game.GAME
    pack = G['pack']
    discs = job['discs']
    hb = Heartbeat()
    try:
        for n, (p, _info) in infos.items():
            discs[n] = siege_iso.Disc(p)
        ctx = Context(game, discs, job['work'], job['staging'], job['log_path'])
        seed_pack_meta(ctx)
        steps = game.steps(ctx) + [cd_audio_step(ctx)]
        hb.start()
        with Redirect(job['log_path']):
            print('Siege Engine importer %s, %s, discs %s' % (IMPORTER_VERSION, G['name'], {n: p for n, (p, _) in infos.items()}))
            print('work %s, staging %s, python %s, frozen %s' % (job['work'], job['staging'], sys.version.split()[0], FROZEN))
            _run_steps(ctx, steps, hb)
            ctx._range, ctx._stage = (1.0, 1.0), 'finish'
            write_pack_meta(ctx, infos, time.time() - job['t_start'])
        hb.state = None
        PROTO.emit({'stage': 'install', 'progress': 0.99, 'message': 'Installing the pack...'})
        for d in discs.values():
            d.close()
        discs.clear()
        _install_pack(os.path.join(job['staging'], pack), os.path.join(out, pack))
        return True
    except ImportFailed as e:
        PROTO.emit({'error': '%s (details: %s)' % (e, job['log_path'])})
        PROTO.detail(_log_tail(job['log_path']))
    except KeyboardInterrupt:
        PROTO.emit({'error': 'Cancelled'})
    except Exception as e:  # noqa: BLE001
        PROTO.emit({'error': 'Import failed: %s (details: %s)' % (_explain(e), job['log_path'])})
        PROTO.detail(traceback.format_exc())
    finally:
        hb.stop_flag.set()
    return False


def cmd_import(args):
    parsed = _parse_import_args(args)
    if parsed is None:
        PROTO.emit({'error': 'usage: import [--game <pack>] --out <packs_dir> <iso|cue|bin> [...]'})
        return 2
    out, work_arg, keep, isos, want = parsed
    t_start = time.time()
    try:
        _clean_stale_work_dirs()            # scratch folders of imports that were killed (cancelled)
    except OSError:
        pass
    PROTO.emit({'stage': 'identify', 'progress': 0.0, 'message': 'Reading the disc...'})
    try:
        game, infos = _identify_all(isos, want)
    except ImportFailed as e:
        PROTO.emit({'error': str(e)})
        return 1
    G = game.GAME
    refusal = _import_refusal(G, infos)
    if refusal:
        PROTO.emit({'error': refusal})
        return 1
    pack = G['pack']
    log_path = _new_log(pack)
    work, staging = _prepare_work(work_arg, pack)
    job = {'work': work, 'staging': staging, 'log_path': log_path, 't_start': t_start, 'discs': {}}
    try:
        ok = _convert(game, infos, out, job)
    finally:
        for d in job['discs'].values():
            d.close()
        if not keep and not work_arg:          # never delete a folder the caller chose
            shutil.rmtree(work, ignore_errors=True)
    if ok:
        PROTO.emit({'stage': 'done', 'progress': 1.0,
                    'message': 'Imported %s in %d s' % (G['name'], round(time.time() - t_start))})
        PROTO.emit({'done': True, 'pack': pack, 'seconds': round(time.time() - t_start, 1)})
        return 0
    return 1


def _log_tail(path, n=25):
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            return ''.join(f.readlines()[-n:])
    except OSError:
        return ''


# ---------------------------------------------------------------------------------------------- pack.json
def _count(path, ext='.json'):
    try:
        return len([f for f in os.listdir(path) if f.endswith(ext) and not f.startswith('_')])
    except OSError:
        return 0


def provides(pack_dir):
    """Content kinds the app can use from this pack (game/engine/packs.gd CONTENT_KINDS) -> count."""
    out = {}

    def load(*p):
        try:
            with open(os.path.join(pack_dir, *p), encoding='utf-8') as f:
                return json.load(f)
        except (OSError, ValueError):
            return None
    hercs = load('gameplay', 'hercs.json')
    if isinstance(hercs, dict):
        for h in hercs.values():
            side = h.get('side', 'herc') if isinstance(h, dict) else 'herc'
            if side in ('herc', 'cybrid'):
                k = 'hercs' if side == 'herc' else 'cybrids'
                out[k] = out.get(k, 0) + 1
    eng = load('gameplay', 'weapons_engine.json')
    if isinstance(eng, dict):
        for w in eng.get('weapons', []):
            cat = w.get('category', 'herc')
            if cat in ('herc', 'infantry', 'vehicle'):
                out[cat + '_weapons'] = out.get(cat + '_weapons', 0) + 1
    else:
        wj = load('gameplay', 'weapons.json')
        if isinstance(wj, dict) and wj.get('weapons'):
            out['herc_weapons'] = len(wj['weapons'])
    arenas = load('arenas', '_index.json')
    if isinstance(arenas, list) and arenas:
        out['arenas'] = len(arenas)
    maps = load('maps', '_index.json')          # engine map schema (docs/formats/map_schema.md)
    if isinstance(maps, list) and maps:
        out['arenas'] = out.get('arenas', 0) + len(maps)
    n = _count(os.path.join(pack_dir, 'worlds'), '')
    if n:
        out['worlds'] = n
    n = _count(os.path.join(pack_dir, 'missions', 'msn'))
    if n:
        out['missions'] = n
    camp = load('campaign', 'campaign.json')      # Aerial Assault (tools/aa_import.py)
    if isinstance(camp, dict) and camp.get('missions'):
        out['missions'] = len(camp['missions'])
    n = _count(os.path.join(pack_dir, 'shapes'))
    if n:
        out['shapes'] = n
    return out


def seed_pack_meta(ctx):
    """Starts the staging pack's pack.json with the game's GAME['pack_json'] keys: converters that run before
    write_pack_meta read them (fx_es1: default_palette, world_metres_per_unit)."""
    seed = ctx.game.GAME.get('pack_json')
    meta_path = ctx.pack_path('pack.json')
    if seed and not os.path.exists(meta_path):
        with open(meta_path, 'w') as f:
            json.dump(seed, f, indent=1)


def write_pack_meta(ctx, infos, seconds):
    meta_path = ctx.pack_path('pack.json')
    meta = {}
    if os.path.exists(meta_path):                       # some exporters write their own pack.json
        try:
            meta = json.load(open(meta_path))
        except ValueError:
            meta = {}
    meta.update(ctx.game.GAME.get('pack_json', {}))
    meta.setdefault('name', ctx.game.GAME['name'])
    meta['game'] = ctx.game.GAME['game']
    meta['provides'] = provides(ctx.out)
    meta['importer'] = {'version': IMPORTER_VERSION, 'imported': time.strftime('%Y-%m-%dT%H:%M:%S'),
                        'seconds': round(seconds, 1), 'notes': ctx.notes}
    meta['source_discs'] = [{'disc': n, 'label': info.get('label', ''), 'file': os.path.basename(p),
                             'path': os.path.abspath(p)}
                            for n, (p, info) in sorted(infos.items())]
    meta['release'] = make_release_record(ctx)
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=1)
    units = ctx.pack_path('units.json')
    tpl = os.path.join(RES, 'pack_meta', '%s_units.json' % ctx.pack)
    if not os.path.exists(units) and os.path.exists(tpl):
        shutil.copy(tpl, units)


def make_release_record(ctx):
    """pack.json "release": which version of the game the disc holds (tools/disc_version.py). Identification never
    fails an import: a problem is recorded as {"game", "error"}."""
    import disc_version
    G = ctx.game.GAME
    spec = G.get('main_exe', {})
    try:
        exe_path = locate_main_exe(ctx, spec)
        text = disc_version.read_disc_text(ctx.discs[1], G.get('version_file', ''))
        rec = disc_version.make_release(G, ctx.discs[1], exe_path, text)
    except Exception as e:  # noqa: BLE001 - identification is informative only
        print('release identification failed: %s' % traceback.format_exc())
        return {'game': G['game'], 'error': '%s: %s' % (type(e).__name__, e)}
    print('release: %s' % json.dumps(rec))
    return rec


def locate_main_exe(ctx, spec):
    """The main executable in the work folder: copied from the disc, or (inside an install archive) produced by
    running the game's import steps until it exists (during an import they have run already)."""
    if 'disc' in spec:
        exe_path = ctx.work_path('_release', os.path.basename(spec['disc']))
        ctx.discs[1].extract(spec['disc'], exe_path)
        return exe_path
    exe_path = ctx.work_path(*spec['work'].split('/'))
    for step in ctx.game.steps(ctx):
        if os.path.exists(exe_path):
            break
        print('==== %s (to reach the main executable)' % step.stage, flush=True)
        step.fn(ctx)
    return exe_path


# ---------------------------------------------------------------------------------------------- identify-release
def cmd_identify_release(args):
    """identify-release --pack <pack dir> <iso>: writes the disc's release record (make_release_record) into an
    already imported pack's pack.json, without converting anything (packs imported before releases were recorded).
    -> {"done": true, "pack", "release"} or {"error"}."""
    if len(args) != 3 or args[0] != '--pack':
        PROTO.emit({'error': 'usage: identify-release --pack <pack dir> <iso>'})
        return 2
    pack_dir, iso = os.path.abspath(args[1]), args[2]
    meta_path = os.path.join(pack_dir, 'pack.json')
    try:
        meta = json.load(open(meta_path, encoding='utf-8'))
        game, info = identify_disc(iso, meta.get('game', os.path.basename(pack_dir)))
        if meta.get('game', os.path.basename(pack_dir)) != game.GAME['game']:   # older pack.json: no "game"
            raise ImportFailed('%s is a %s disc, but %s holds %s.' % (
                os.path.basename(iso), game.GAME['name'], pack_dir, meta.get('name', meta.get('game'))))
        release = _make_release_in_scratch(game, iso, info)
    except ImportFailed as e:
        PROTO.emit({'error': str(e)})
        return 1
    except (OSError, ValueError) as e:
        PROTO.emit({'error': 'Could not read %s: %s' % (meta_path, e)})
        return 1
    if 'error' in release:
        PROTO.emit({'error': 'Could not identify the release: %s' % release['error']})
        return 1
    meta['release'] = release
    _apply_source_path(meta, info, iso)
    with open(meta_path, 'w') as f:
        json.dump(meta, f, indent=1)
    PROTO.emit({'done': True, 'pack': game.GAME['pack'], 'release': release})
    return 0


def _make_release_in_scratch(game, iso, info):
    """make_release_record for disc `iso` in a scratch work folder (deleted afterwards)."""
    import siege_iso
    pack = game.GAME['pack']
    work, staging = _prepare_work(None, pack)
    disc = siege_iso.Disc(iso)
    try:
        ctx = Context(game, {info['disc']: disc}, work, staging, os.devnull)
        PROTO.emit({'stage': 'identify', 'progress': 0.1, 'message': 'Reading the %s executable...' % game.GAME['name']})
        with Redirect(_new_log(pack + '-release')):
            return make_release_record(ctx)
    finally:
        disc.close()
        shutil.rmtree(work, ignore_errors=True)


def _apply_source_path(meta, info, iso):
    """Records where the disc image is (the versions page offers Identify for it later)."""
    discs = meta.setdefault('source_discs', [])
    row = next((d for d in discs if d.get('disc') == info['disc']), None)
    if row is None:
        row = {'disc': info['disc'], 'label': info.get('label', '')}
        discs.append(row)
    row['file'] = os.path.basename(iso)
    row['path'] = os.path.abspath(iso)


# ---------------------------------------------------------------------------------------------- main
def main(argv):
    if os.name == 'nt':
        try:   # never let a child process (ffmpeg) wait on our stdin
            fd = os.open(os.devnull, os.O_RDONLY)
            os.dup2(fd, 0)
        except OSError:
            pass
    if not argv or argv[0] in ('-h', '--help', 'help'):
        sys.stdout.write(__doc__)
        return 0
    if argv[0] in ('--version', 'version'):
        PROTO.emit({'version': IMPORTER_VERSION})
        return 0
    if argv[0] == 'run' and len(argv) > 1:      # developer aid: run one converter inside the (frozen) importer
        import runpy
        sys.argv = [argv[1] + '.py'] + argv[2:]
        runpy.run_module(argv[1], run_name='__main__', alter_sys=False)
        return 0
    if argv[0] == 'soundtracks':                # ripped soundtrack folders -> <packs>/_soundtracks
        import siege_soundtrack
        return siege_soundtrack.main(argv[1:])
    cmd = {'identify': cmd_identify, 'import': cmd_import, 'games': cmd_games,
           'identify-release': cmd_identify_release}.get(argv[0])
    if not cmd:
        PROTO.emit({'error': 'unknown command %r (identify, import, games, identify-release)' % argv[0]})
        return 2
    return cmd(argv[1:])


if __name__ == '__main__':
    if FROZEN:
        import multiprocessing
        multiprocessing.freeze_support()
    sys.exit(main(sys.argv[1:]))
