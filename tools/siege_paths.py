"""Where the disc-conversion pipeline reads original files and writes content packs.

Every exporter resolves its directories through this module, so the same code runs
  * in a developer checkout (defaults: the repository layout original/, extracted/, bd/installed,
    es2/..., tribes/..., gamedata/<pack>/), and
  * inside the importer (tools/siege_import.py, frozen to siege-importer.exe), which points
    SIEGE_WORK at a per-import scratch folder and SIEGE_PACKS at the app's packs folder.

The work directory mirrors the repository layout for source files:
  <work>/original, <work>/extracted                Earthsiege 1 disc tree / unpacked VOLs
  <work>/bd/original, <work>/bd/installed          Battledrome disc tree / unpacked RESOURCE.000
  <work>/es2/original, <work>/es2/extracted        Earthsiege 2
  <work>/tribes/original, <work>/tribes/extracted  Starsiege: Tribes
  (likewise starsiege/, tribes2/)
Packs are written to <packs>/<pack>/.

Environment:
  SIEGE_WORK   work directory (default: repository root)
  SIEGE_PACKS  packs directory (default: <repository>/gamedata)
Both are read when this module is first imported; set them before importing any exporter.
"""
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
WORK = os.path.abspath(os.environ.get('SIEGE_WORK') or ROOT)
PACKS = os.path.abspath(os.environ.get('SIEGE_PACKS') or os.path.join(ROOT, 'gamedata'))


def work(*parts):
    """Path of a source file/dir (disc tree or unpacked archives) for the current import."""
    return os.path.join(WORK, *parts)


def pack(name, *parts):
    """Path inside the output pack <packs>/<name>/."""
    return os.path.join(PACKS, name, *parts)
