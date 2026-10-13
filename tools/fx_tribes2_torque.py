"""Tribes 2 (Torque V12) effect datablocks -> engine effect layers (docs/formats/weapon_fx.md section 7).

Decodes ParticleEmitterData / ParticleData, ExplosionData (explosion shapes, emitters, sub-explosions, debris,
shockwaves), SplashData and ShieldImpactData of the user's scripts into the pack effect library built by
tools/fx_tribes2.py. Every value is read from the scripts, textures and shapes at import time.

Torque rendering rules this module relies on (public Torque Game Engine 1.x source, the V12 descendant):
  * a particle with useInvAlpha = false is drawn additively (SRC_ALPHA, ONE), otherwise alpha-blended;
  * a particle's colour and size are keyed at times[] over its life (default keys 0 and 1); size = quad width;
  * acceleration = -velocity * dragCoefficient + (0, 0, -9.81) * gravityCoefficient;
  * an explosion's emitter[] emit for the emitter's lifetimeMS (or the explosion's life) every
    ejectionPeriodMS; particleEmitter emits particleDensity particles at once within particleRadius;
  * explosion shapes are camera-facing animated meshes whose texture is an IFL (image file list; one unit =
    1/30 s); sizes[] / times[] scale the shape over the explosion's life.
"""
import os
import re

import siege_paths as P

SCRIPTS = P.work('tribes2', 'extracted', 'scripts', 'scripts')
TEXTURES = P.work('tribes2', 'extracted', 'textures', 'textures')
SKINS = P.work('tribes2', 'extracted', 'skins', 'textures', 'skins')
SHAPES = P.work('tribes2', 'extracted', 'shapes', 'shapes')
AUDIO = P.work('tribes2', 'extracted', 'audio', 'audio')

TORQUE_GRAVITY = 9.81            # particle gravity of the Torque particle engine (not the missions' 20 m/s2)
IFL_FPS = 30.0                   # one IFL duration unit = one 1/30 s frame
DEFAULT_EXPLOSION_MS = 1000      # ExplosionData lifetimeMS default
MAX_PARTICLES = 250              # largest original burst (particleDensity); continuous emitters are capped to it


def is_true(value):
    return str(value).strip().lower() in ('true', '1')


def numbers(text):
    """All numbers of a TorqueScript value, including "a/b @ \" \" @ c" concatenations."""
    out = []
    for part in str(text).split('@'):
        for tok in part.strip().strip('"').split():
            try:
                out.append(float(tok.split('/')[0]) / float(tok.split('/')[1]) if '/' in tok else float(tok))
            except ValueError:
                pass
    return out


def rgba(text, alpha=1.0):
    v = numbers(text)
    if len(v) < 3:
        return None
    return [round(x, 3) for x in (v + [alpha])[:4]]


def indexed(fields, key):
    """Values of key[0], key[1], ... (also key[00]) in index order."""
    found = []
    for k, v in fields.items():
        m = re.match(r'%s\[(\d+)\]$' % re.escape(key), k, re.I)
        if m:
            found.append((int(m.group(1)), v))
    return [v for _, v in sorted(found)]


class Datablocks:
    """The scripts' datablocks with inheritance resolved (tools/catalog_tribes2.py parser)."""

    def __init__(self):
        import catalog_tribes2 as C
        self._catalog = C
        self._db = C.datablocks(SCRIPTS)

    def get(self, name):
        if not name or str(name).lower() not in self._db:
            return None
        d = self._db[str(name).lower()]
        f = dict(self._catalog.resolved(self._db, d['name']))
        f['_class'], f['_name'], f['_file'] = d['class'], d['name'], d['file']
        return f

    def evidence(self, f):
        return 'scripts/%s %s(%s)' % (f['_file'], f['_class'], f['_name'])


class TextureFiles:
    """Case-insensitive lookup of textureName paths (textures.vl2) and IFL frames (skins.vl2)."""

    def __init__(self):
        self.textures = self._scan(TEXTURES, relative=True)
        self.skins = self._scan(SKINS, relative=False)

    @staticmethod
    def _scan(root, relative):
        found = {}
        for dp, _, files in os.walk(root):
            for fn in files:
                stem, ext = os.path.splitext(fn)
                if ext.lower() not in ('.png', '.ifl'):
                    continue
                key = os.path.relpath(os.path.join(dp, stem), root) if relative else stem
                found.setdefault((key.replace('\\', '/').lower(), ext.lower()), os.path.join(dp, fn))
        return found

    def texture(self, name):
        return self.textures.get((str(name).replace('\\', '/').lower(), '.png'))

    def skin(self, name):
        return self.skins.get((os.path.splitext(str(name).replace('\\', '/').split('/')[-1])[0].lower(), '.png'))

    def ifl(self, name):
        return self.skins.get((os.path.splitext(str(name).replace('\\', '/').split('/')[-1])[0].lower(), '.ifl'))


def read_ifl(path):
    """[(frame image name, duration units)] of an image file list."""
    frames = []
    with open(path, encoding='latin1') as f:
        for line in f:
            parts = line.split()
            if parts:
                frames.append((parts[0], int(float(parts[1])) if len(parts) > 1 else 1))
    return frames


class ShapeFile:
    """What the effect export needs from a DTS: string table, materials, object bounds, sequence lengths
    (tools/torque_dts.py reads every shape the scripts reference, v18-v23)."""

    def __init__(self, name):
        self.name = os.path.splitext(str(name))[0].lower()
        path = os.path.join(SHAPES, self.name + '.dts')
        self.data = open(path, 'rb').read() if os.path.exists(path) else b''
        self.shape = self._read()

    def _read(self):
        import torque_dts as T
        return T.read_shape(self.data) if self.data else None

    @property
    def exists(self):
        return bool(self.data)

    def strings(self):
        return [s.decode('latin1') for s in re.findall(rb'[A-Za-z_\\][ -~]{3,}', self.data)]

    def ifl_names(self):
        return [s.split('\\')[-1] for s in self.strings() if s.lower().endswith('.ifl')]

    def header_extent(self):
        """Largest horizontal extent of the shape bounds."""
        if not self.shape:
            return 0.0
        b = self.shape['bounds']
        return max(b[3] - b[0], b[5] - b[2])

    def objects(self, pattern):
        """[(object name, mesh)] of the most detailed mesh of every object whose name matches."""
        if not self.shape:
            return []
        s = self.shape
        out = []
        for o in s['objects']:
            name = s['names'][o['name']]
            if re.search(pattern, name, re.I) and o['num_meshes'] > 0:
                out.append((name, s['meshes'][o['start_mesh']]))
        return out

    def sequence_seconds(self, pattern):
        if not self.shape:
            return None
        for q in self.shape['sequences']:
            if re.fullmatch(pattern, self.shape['names'][q['name']], re.I):
                return q['duration']
        return None

    def material(self, index):
        mats = self.shape['materials'] if self.shape else []
        return mats[index] if 0 <= index < len(mats) else None


def mesh_extent(mesh, frame=None):
    """Largest axis extent of a mesh (all frames, or one vertex-animation frame)."""
    if frame is None:
        b = mesh['bounds']
        return max(b[3] - b[0], b[4] - b[1], b[5] - b[2])
    n = mesh['verts_per_frame'] or len(mesh['verts']) // 3
    v = mesh['verts'][3 * n * frame:3 * n * (frame + 1)]
    if not v:
        return mesh_extent(mesh)
    return max(max(v[a::3]) - min(v[a::3]) for a in range(3))


def mesh_materials(mesh):
    return sorted({p[2] & 0x0FFFFFFF for p in mesh['prims'] if not p[2] & 0x10000000})
