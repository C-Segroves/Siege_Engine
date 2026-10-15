"""Per-game import modules for tools/siege_import.py.

Each module defines
  GAME = {"game", "pack", "name", "discs", "required_discs"?, "needs"?, "pack_json"?, "supported"?,
          "main_exe": {"disc": <path on disc 1>} or {"work": <path in the work folder>}, "version_file"?}
          (main_exe / version_file identify the release: tools/disc_version.py)
  identify(disc) -> disc number (1, 2, ...) or 0      disc: siege_iso.Disc (directory lookups only)
  steps(ctx)     -> [Step(stage, message, weight_seconds, fn(ctx))]
Steps read from ctx.work (= siege_paths.WORK) and write the pack into ctx.out (= siege_paths.pack(<pack>)).
A step must never read another pack: every pack is imported on its own.
"""


class Step:
    """One import stage; weight = rough duration in seconds (drives the progress bar)."""

    def __init__(self, stage, message, weight, fn):
        self.stage, self.message, self.weight, self.fn = stage, message, float(weight), fn


def relocate(module, root=None):
    """Point a tool that still builds its paths from the repository root (module.ROOT) at the import's work
    folder (sources) and staging packs folder (gamedata/...). Rewrites the module's path globals in place."""
    import os
    import siege_paths as P
    root = os.path.normcase(os.path.normpath(root or getattr(module, 'ROOT')))
    for k, v in list(vars(module).items()):
        if not isinstance(v, str) or k.startswith('__'):
            continue
        n = os.path.normcase(os.path.normpath(v))
        if n != root and not n.startswith(root + os.sep):
            continue
        rel = os.path.relpath(os.path.normpath(v), os.path.normpath(root))
        parts = [] if rel == '.' else rel.split(os.sep)
        if parts and parts[0] == 'gamedata':
            setattr(module, k, os.path.join(P.PACKS, *parts[1:]))
        else:
            setattr(module, k, os.path.join(P.WORK, *parts))
    return module


def call_main(module, *argv):
    """module.main() with sys.argv set like a command-line run."""
    import sys
    old = sys.argv
    sys.argv = [module.__name__ + '.py'] + [str(a) for a in argv]
    try:
        r = module.main()
    except SystemExit as e:
        r = e.code
    finally:
        sys.argv = old
        sys.stdout.flush()
    if r not in (None, 0):
        raise RuntimeError('%s exited with %s' % (module.__name__, r))


from . import es1, bd, es2, tribes, starsiege, tribes2, tribes_aa, tribes_vengeance  # noqa: E402

# order matters only for discs that could match several signatures (most specific first)
GAMES = [es1, bd, es2, tribes, starsiege, tribes2, tribes_aa, tribes_vengeance]
