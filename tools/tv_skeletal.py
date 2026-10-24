"""Tribes: Vengeance skeletal characters -> engine shapes with a skeleton and animations (docs/formats/tribes_vengeance.md).

A SkeletalMesh (ue2_skeletal) plus the MeshAnimation of its package become one shape JSON (the schema of tools/aa_soldier.py):
one node per bone, every triangle riding the bone most of its vertices are bound to (the armours are rigidly skinned: the
influences weigh 1.0; a vertex with several takes the heaviest), vertices in that bone's local frame, and `ds_sequences`
named as the engine's InfantryAnimation expects (root, run, back, side, jet, fall, land, death1) plus a few extra
character poses. Frame: shape x = Unreal y (right), y = Unreal x (forward), z = Unreal z (up); metres = units / 70.

  export_bodies(idx, game_root, pack_dir) -> [body records] written to gameplay/bodies.json
"""
import json
import math
import os

import numpy as np
from PIL import Image

import tv_statics
import ue2_package as U
import ue2_skeletal as S

P = np.array([[0, 1.0, 0], [1.0, 0, 0], [0, 0, 1.0]])         # Unreal (x fwd, y right, z up) <-> shape (x right, y fwd, z up)
MAX_TEXTURE = 512
METRES_PER_UU = 1.0 / 70.0
MOUNT_NODE = 'mount0'
HAND_BONE = 'bip01 r hand'
FEET = ('bip01 l foot', 'bip01 r foot')
ROOT_BONE = 'bip01'

# Which armour packages hold which bodies: package -> (size, animation key); characters are named below.
PACKAGES = {
    'lightarmour': 'LIGHT', 'lightarmourfem': 'LIGHT', 'mediumarmour': 'MEDIUM', 'heavyarmour': 'HEAVY',
    'civilianmale': 'CIVILIAN', 'glorax': 'CREATURE', 'juliajnr': 'CIVILIAN',
}
FACTIONS = (('phoenix', 'Phoenix'), ('bloodeagle', 'Blood Eagle'), ('imperial', 'Imperial'))
# Role -> candidate animation names, tried in order (lower case). Female bodies try the Female_ names first.
ROLES = {
    'root': ['alert_stand', 'neutral_stand', 'stand', 'stand_alert', 'stand_idle'],
    'run': ['alert_run_forward', 'neutral_run_forward', 'run_forward'],
    'back': ['alert_run_back', 'neutral_run_back', 'run_back'],
    'side': ['alert_run_left', 'neutral_run_left', 'run_left'],
    'jet': ['alert_thrust', 'neutral_thrust', 'thrust', 'ski_up'],
    'fall': ['alert_airborne', 'neutral_airborne', 'airborne', 'airborne_down'],
    'land': ['neutral_stop_forward', 'alert_stop_forward', 'stop_forward'],
    'death1': ['a_beckondie', 'a_corridordeath01', 'a_onfiretodeath'],
}
FEMALE_FIRST = {'root': ['female_alert_stand', 'female_neutral_stand', 'female_stand'],
                'run': ['female_alert_run_forward', 'female_neutral_run_forward', 'female_run_forward'],
                'back': ['female_alert_run_back', 'female_neutral_run_back', 'female_run_back'],
                'side': ['female_alert_run_left', 'female_neutral_run_left', 'female_run_left']}
EXTRAS = ('a_taunt1', 'a_taunt2', 'a_salute', 'a_cower', 'a_talkingheadcalm', 'a_beckon', 'a_panic', 'a_pointforward',
          'a_victorydance1', 'ai_searching', 'a_convercalm', 'flinch', 'a_wavforward', 'a_kneelidle')
GENERIC = {'phoenixlight', 'bloodeaglelight', 'imperiallight', 'phoenixlightfem', 'bloodeaglelightfem', 'imperiallightfem',
           'phoenixmedium', 'bloodeaglemedium', 'imperialmedium', 'phoenixmediumfem', 'bloodeaglemediumfem', 'imperialmediumfem',
           'phoenixheavy', 'bloodeagleheavy', 'imperialheavy'}      # offered as bodies of any armour of their size
LOOPED = ('root', 'run', 'back', 'side', 'jet', 'fall')
MOVES = ('run', 'back', 'side')


# ------------------------------------------------------------------------------------------------ maths
def quat_matrix(q, flip):
    x, y, z, w = (float(c) for c in q)
    if flip:
        w = -w
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    x, y, z, w = x / n, y / n, z / n, w / n
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def euler_turns(r):
    """Rotation matrix -> (rx, ry, rz) in 1/65536 turn for R = Rz(c) Ry(b) Rx(a) (ShapeInstance.tf_to_transform)."""
    sy = -r[2, 0]
    b = math.asin(max(-1.0, min(1.0, sy)))
    if abs(sy) < 0.99999:
        a, c = math.atan2(r[2, 1], r[2, 2]), math.atan2(r[1, 0], r[0, 0])
    else:
        a, c = 0.0, math.atan2(-r[0, 1], r[1, 1])
    return [float(v) * 65536.0 / (2 * math.pi) for v in (a, b, c)]


def shape_transform(rot_ue, pos_ue, mpu):
    """Local bone transform (Unreal frame) -> [rx, ry, rz, x, y, z] of the shape frame, metres."""
    r = P @ rot_ue @ P
    t = (P @ np.asarray(pos_ue, float)) * mpu
    return [round(v, 4) for v in euler_turns(r)] + [round(float(v), 5) for v in t]


def sample(track, frame, kind):
    times, arr = track['times'], track[kind]
    if len(arr) == 1 or len(times) < 2:
        return arr[0]
    i = int(np.searchsorted(times, frame, side='right')) - 1
    i = max(0, min(i, len(times) - 2, len(arr) - 2))
    s = (frame - times[i]) / max(times[i + 1] - times[i], 1e-6)
    s = min(max(s, 0.0), 1.0)
    return arr[i] * (1 - s) + arr[i + 1] * s


class Rig:
    def __init__(self, bones):
        self.bones = bones
        self.names = [b['name'].lower() for b in bones]
        self.index = {n: i for i, n in enumerate(self.names)}

    def rest_world(self):
        return self.world(lambda i: (np.array(self.bones[i]['quat']), np.array(self.bones[i]['pos'])))

    def world(self, local):
        """[(R, t)] bone world transforms (Unreal frame); local(i) -> (quat, position)."""
        out = []
        for i, b in enumerate(self.bones):
            q, pos = local(i)
            r = quat_matrix(q, i > 0)
            if i == 0 or b['parent'] < 0:
                out.append((r, np.asarray(pos, float)))
            else:
                rp, tp = out[b['parent']]
                out.append((rp @ r, tp + rp @ pos))
        return out

    def pose_world(self, seq, frame):
        def local(i):
            tr = seq['tracks'].get(self.names[i])
            if tr is None:
                return np.array(self.bones[i]['quat']), np.array(self.bones[i]['pos'])
            return sample(tr, frame, 'quats'), sample(tr, frame, 'pos')
        return self.world(local)


# ------------------------------------------------------------------------------------------------ geometry
def _bone_per_point(mesh):
    inf = mesh['influences']
    best = np.full(len(mesh['points']), -1, np.int64)
    weight = np.zeros(len(mesh['points']))
    for w, p, b in zip(inf['w'], inf['p'], inf['b']):
        if w > weight[p]:
            weight[p], best[p] = w, b
    return np.where(best < 0, 0, best)


def build_pieces(mesh, rig, mpu, texture_count):
    """Polys per bone in bone-local shape-frame metres, wound to face outward."""
    pts = mesh['points'].astype(float)
    wedges, tris = mesh['wedges'], mesh['tris']
    bone_of = _bone_per_point(mesh)
    rest = rig.rest_world()
    centre = (pts.min(0) + pts.max(0)) / 2
    corner = np.stack([wedges['i'][tris['w'][:, k]] for k in range(3)], axis=1)           # (m, 3) point indices
    # orientation: majority of triangles outward in the shape frame
    sp = (pts @ P) * mpu
    c = (centre @ P) * mpu
    a, b, d = sp[corner[:, 0]], sp[corner[:, 1]], sp[corner[:, 2]]
    cross = np.cross(b - a, d - a)
    out = ((a + b + d) / 3 - c)
    flip = float(np.sum(np.einsum('ij,ij->i', cross, out))) < 0
    pieces = {}
    for t in range(len(tris)):
        idx = corner[t]
        bones = bone_of[idx]
        bone = int(np.bincount(bones).argmax())
        rb, tb = rest[bone]
        local = [P @ (rb.T @ (pts[i] - tb)) * mpu for i in idx]
        uv = [(float(wedges['u'][tris['w'][t, k]]), float(wedges['v'][tris['w'][t, k]])) for k in range(3)]
        order = [0, 2, 1] if flip else [0, 1, 2]
        v = [local[k] for k in order]
        n = np.cross(v[1] - v[0], v[2] - v[0])
        ln = float(np.linalg.norm(n))
        if ln < 1e-12:
            continue
        n = n / ln
        mat = min(int(tris['m'][t]), max(0, texture_count - 1))
        pieces.setdefault(bone, []).append({
            'v': [[round(float(x), 5) for x in p] for p in v], 'n': [round(float(x), 4) for x in n], 't': 'tri',
            'm': {'kind': 'rgba', 'index': mat}, 'uv': [[round(uv[k][0], 4), round(uv[k][1], 4)] for k in order]})
    return pieces


def _safe(s):
    return ''.join(c if c.isalnum() or c in '-_' else '_' for c in s)


def mesh_materials(idx, pkg, mesh, pack_dir, log=print):
    """(texture names, per-material texture) of the mesh's material refs; textures saved under textures/tv."""
    names = []
    tex_dir = os.path.join(pack_dir, 'textures', 'tv')
    for ref in mesh['materials'] or [0]:
        rgba, tname = (None, '')
        if ref:
            try:
                rgba, tname = tv_statics.material_texture(idx, pkg, ref)
            except Exception as ex:                                  # noqa: BLE001 -- a bad shader must not drop the body
                log('  material %s: %s' % (ref, ex))
        tname = _safe(tname).lower() if rgba is not None else ''
        if rgba is not None:
            path = os.path.join(tex_dir, tname + '.png')
            if not os.path.isfile(path):
                os.makedirs(tex_dir, exist_ok=True)
                img = Image.fromarray(rgba)
                if max(img.size) > MAX_TEXTURE:
                    img = img.resize((min(img.width, MAX_TEXTURE), min(img.height, MAX_TEXTURE)), Image.LANCZOS)
                img.save(path)
        names.append(tname)
    return names


# ------------------------------------------------------------------------------------------------ animation
def find_sequence(seqs, names):
    for n in names:
        for k, v in seqs.items():
            if k.lower() == n:
                return k, v
    return None, None


def foot_travel(rig, seq, axis):
    """(travel per cycle in metres-free Unreal units along shape `axis`, footstep triggers) of a move cycle."""
    n = max(int(seq['frames']), 1)
    fwd = np.zeros((n, 2))
    for f in range(n):
        w = rig.pose_world(seq, float(f))
        base = (P @ w[0][1])[axis]
        for j, name in enumerate(FEET):
            if name in rig.index:
                fwd[f, j] = (P @ w[rig.index[name]][1])[axis] - base
    travel = float((fwd.max(0) - fwd.min(0)).sum())
    steps = sorted([round(int(np.argmax(fwd[:, j])) / n, 4), 1 + j] for j in range(2))
    return travel, steps


def sequence_json(rig, seq, name, cyclic, mpu, transforms, move_axis=None, direction=1.0):
    frames = max(int(seq['frames']), 1)
    span = float(frames if cyclic else max(frames - 1, 1))
    tracks = []
    for b, bone in enumerate(rig.bones):
        tr = seq['tracks'].get(rig.names[b])
        if tr is None:
            continue
        times = [float(t) for t in tr['times']]
        keys = []
        count = max(len(tr['quats']), len(tr['pos']))
        for i in range(count):
            q = tr['quats'][min(i, len(tr['quats']) - 1)]
            p = tr['pos'][min(i, len(tr['pos']) - 1)]
            t = times[min(i, len(times) - 1)] if times else 0.0
            transforms.append(shape_transform(quat_matrix(q, b > 0), p, mpu))
            keys.append([round(t / span, 5), len(transforms) - 1])
        if cyclic and keys and keys[-1][0] < 1.0:                 # close the loop on the first key
            keys.append([1.0, keys[0][1]])
        tracks.append({'node': b, 'keys': keys})
    out = {'name': name, 'cyclic': cyclic, 'flags': 0, 'duration': round(span / float(seq['rate'] or 25.0), 4), 'priority': 0,
           'tracks': tracks, 'ground': [0.0, 0.0, 0.0]}
    if move_axis is not None:
        travel, steps = foot_travel(rig, seq, move_axis)
        travel *= mpu
        out['ground'] = [-travel, 0.0, 0.0] if move_axis == 0 else [0.0, travel * direction, 0.0]
        out['triggers'] = steps
    return out


def pick_animation(pkg, mesh):
    """The package's MeshAnimation that covers most of the mesh's bones (at least 60%), parsed."""
    need = {b['name'].lower() for b in mesh['bones']}
    best, best_score = None, 0.6
    for e in pkg.find('MeshAnimation'):
        try:
            anim = S.parse_animation(pkg, e)
        except Exception:                                          # noqa: BLE001
            continue
        score = len(need & {n.lower() for n, _p in anim['bones']}) / float(len(need))
        if score >= best_score:
            best, best_score = anim, score
    return best


def shape_json(idx, pkg, export, mesh, anim, pack_dir, mpu, female, name, log=print, death=None):
    rig = Rig(mesh['bones'])
    tex = mesh_materials(idx, pkg, mesh, pack_dir, log)
    pieces = build_pieces(mesh, rig, mpu, len(tex))
    rest = rig.rest_world()
    transforms, nodes = [], []
    for i, b in enumerate(mesh['bones']):
        local = (quat_matrix(b['quat'], i > 0), np.array(b['pos']))
        transforms.append(shape_transform(local[0], local[1], mpu))
        nodes.append({'parent': b['parent'] if i else -1, 'default': i, 'name': b['name']})
    hand = rig.index.get(HAND_BONE, rig.index.get(ROOT_BONE, 0))
    transforms.append([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
    nodes.append({'parent': hand, 'default': len(transforms) - 1, 'name': MOUNT_NODE})
    seqs = []
    if anim is not None:
        for role, wanted in ROLES.items():
            names = (FEMALE_FIRST.get(role, []) if female else []) + wanted
            key, seq = find_sequence(anim['seqs'], names)
            if seq is None or not seq['tracks'] or seq['frames'] < 2:
                continue
            if role == 'jet' and key.lower() == 'ski_up' and find_sequence(anim['seqs'], ROLES['fall'])[1] is None:
                continue
            axis = {'run': 1, 'back': 1, 'side': 0}.get(role)
            seqs.append(sequence_json(rig, seq, role, role in LOOPED, mpu, transforms, axis, -1.0 if role == 'back' else 1.0))
        if death is not None and not any(q['name'] == 'death1' for q in seqs):         # borrowed from the light armour's A_BeckonDie
            seqs.append(sequence_json(rig, death, 'death1', False, mpu, transforms))
        for ex in EXTRAS:
            key, seq = find_sequence(anim['seqs'], [ex])
            if seq is not None and seq['tracks'] and seq['frames'] > 1:
                seqs.append(sequence_json(rig, seq, ex, True, mpu, transforms))
    pts = (mesh['points'].astype(float) @ P) * mpu
    lo, hi = pts.min(0), pts.max(0)
    polys_count = 0
    js_pieces = []
    for b, polys in sorted(pieces.items()):
        polys_count += len(polys)
        js_pieces.append({'node': b, 'id': 1000 + b, 'name': '%s_%s' % (name, _safe(mesh['bones'][b]['name'])), 'cell': -1,
                          'state': 0, 'polys': polys})
    centre = ((lo + hi) / 2).tolist()
    radius = float(np.linalg.norm(hi - lo) / 2) or 1.0
    return {'name': name, 'texset': None, 'source': 'unreal_skeletal_mesh', 'units': 'metres',
            'lods': [{'radius': round(radius, 3), 'center': [round(c, 3) for c in centre], 'size': 128.0, 'name': 'Detail128',
                      'pieces': js_pieces, 'cells': []}],
            'nodes': nodes, 'transforms': transforms, 'ds_sequences': seqs,
            'bounds': {'header': [lo.tolist(), hi.tolist()]},
            'materials': [{'name': n, 'flags': 0, 'texture': 'textures/tv/%s.png' % n if n else '', 'w': 0, 'h': 0} for n in tex]}


# ------------------------------------------------------------------------------------------------ bodies
def classify(package, mesh_name):
    """(size, faction label, female, label) of an armour or character mesh."""
    low = mesh_name.lower()
    size = PACKAGES.get(package.lower(), 'LIGHT')
    faction = ''
    for key, label in FACTIONS:
        if key in low:
            faction = label
    female = 'fem' in low or low in ('julia', 'princessvictoria', 'olivia', 'imperiallightjulia', 'juliachild', 'imperialmediumvictoria')
    return size, faction, female


def export_bodies(idx, game_root, pack_dir, log=print, only=None):
    """Exports the armour and character bodies; returns the body records (also written to gameplay/bodies.json)."""
    out_dir = os.path.join(pack_dir, 'shapes')
    os.makedirs(out_dir, exist_ok=True)
    bodies = []
    art = os.path.join(game_root, 'Content', 'Art')
    death = _borrowed_death(art)
    for stem, size_key in PACKAGES.items():
        path = tv_statics_find(art, stem)
        if path is None:
            continue
        pkg = U.load(path)
        pkg.stem = stem
        for e in pkg.find('SkeletalMesh'):
            if only and e['name'].lower() not in only:
                continue
            try:
                mesh = S.parse_skeletal_mesh(pkg, e)
                anim = pick_animation(pkg, mesh)
                size, faction, female = classify(stem, e['name'])
                sid = _safe('tv_' + e['name']).lower()
                if any(b['id'] == sid for b in bodies):
                    continue
                js = shape_json(idx, pkg, e, mesh, anim, pack_dir, METRES_PER_UU, female, sid, log, death)
                with open(os.path.join(out_dir, sid + '.json'), 'w', encoding='utf-8') as f:
                    json.dump(js, f, separators=(',', ':'))
                bodies.append({'id': sid, 'mesh': e['name'], 'package': stem, 'size': size, 'faction': faction, 'female': female,
                               'animated': bool(js['ds_sequences']), 'offer': e['name'].lower() in GENERIC, 'sequences': [s['name'] for s in js['ds_sequences']],
                               'height_m': round(float(js['bounds']['header'][1][2] - js['bounds']['header'][0][2]), 3)})
                log('body %-26s %-8s bones %2d sequences %2d' % (e['name'], size, len(mesh['bones']), len(js['ds_sequences'])))
            except S.MeshError as ex:
                log('body %s skipped: %s' % (e['name'], ex))
    os.makedirs(os.path.join(pack_dir, 'gameplay'), exist_ok=True)
    path = os.path.join(pack_dir, 'gameplay', 'bodies.json')
    if only and os.path.isfile(path):                  # a partial run replaces its own bodies in the existing list
        with open(path, encoding='utf-8') as f:
            kept = [b for b in json.load(f)['bodies'] if b['id'] not in {n['id'] for n in bodies}]
        bodies = kept + bodies
    with open(path, 'w', encoding='utf-8') as f:
        json.dump({'pack': 'tribes_v', 'bodies': bodies, 'hand_node': MOUNT_NODE}, f, indent=1)
    return bodies


def tv_statics_find(folder, stem):
    for f in os.listdir(folder):
        if f.lower() == stem + '.pkg':
            return os.path.join(folder, f)
    return None


def _borrowed_death(art):
    """The light armour's A_BeckonDie sequence (tracks by bone name): the other bodies have no death animation of their own."""
    path = tv_statics_find(art, 'lightarmour')
    if path is None:
        return None
    pkg = U.load(path)
    for e in pkg.find('MeshAnimation'):
        anim = S.parse_animation(pkg, e, wanted={'a_beckondie'})
        seq = anim['seqs'].get('A_BeckonDie')
        if seq is not None and seq['tracks']:
            return seq
    return None


# ------------------------------------------------------------------------------------------------ NPC classes
NAMED = {'olivia': 'tv_olivia', 'daniel': 'tv_phoenixmediumdaniel', 'julia': 'tv_imperiallightjulia', 'victoria': 'tv_princessvictoria',
         'mercury': 'tv_mercury', 'jericho': 'tv_phoenixheavyjericho', 'esther': 'tv_phoenixmediumesther', 'seti': 'tv_bloodeaglemediumseti',
         'albrecht': 'tv_imperiallightalbrecht', 'gaius': 'tv_gaius', 'tiberius': 'tv_tiberius'}
# classes that are not called AI<type><faction> (ColiseumCaptain: Mesh BloodEagleMediumSeti, healthModifier 4)
NAMED_CLASSES = {'coliseumcaptain': 'tv_bloodeaglemediumseti'}
LIGHT_TYPES = ('grunt1', 'ninja', 'scout', 'sniper1', 'pilot')
HEAVY_TYPES = ('grunt3', 'grenadier2', 'spammer', 'rocket', 'boss', 'protector')


def npc_body(cls):
    """Body shape id ('tv_...') for an AI character class name (AIGrunt2Phoenix, AICustomOlivia, AIGlorax1st ...), '' if unknown."""
    low = cls.lower()
    if low in NAMED_CLASSES:
        return NAMED_CLASSES[low]
    if low in ('aisquad', 'aitalkinghead', 'aispawnpoint') or not low.startswith('ai') or low.startswith('ai_'):
        return ''
    low = low[2:]
    if low.startswith('glorax'):
        return 'tv_glorax'
    if low.startswith('custom'):
        return NAMED.get(low[6:].rstrip('0123456789'), '')
    if low.startswith('civilian'):
        for key, body in (('imperial', 'tv_civilianmaleimperial'), ('phoenix', 'tv_civilianmalephoenix'), ('beagle', 'tv_civilianmalebeagle')):
            if key in low:
                return body
        return 'tv_civilianmaleprisoner'
    faction = 'bloodeagle' if 'beagle' in low else 'imperial' if 'imperial' in low else 'phoenix'
    size = 'light' if low.startswith(LIGHT_TYPES) else 'heavy' if low.startswith(HEAVY_TYPES) else 'medium'
    return 'tv_%s%s' % (faction, size)


# ------------------------------------------------------------------------------------------------ props and vehicles
PROP_PACKAGES = ('vehicles', 'baseobjects', 'deployables', 'mpgameobjects')
# actor class (or class prefix) of the maps -> skeletal mesh name; checked by the mesh names of the packages
PROP_CLASSES = (
    ('VehiclePod', 'Pod'), ('VehicleAssaultShip', 'AssaultShip'), ('VehicleTank', 'Tank'), ('VehicleBuggy', 'Buggy'),
    ('BaseTurret', 'Turret'), ('BaseCatapult', 'Catapult'), ('BaseResupply', 'ResupplyStation'),
    ('BasePowerGenerator', 'Generator'), ('BaseSensor', 'SensorTower'), ('BaseInventoryStation', 'InventoryStationBase'),
    ('BaseSpawnTower', 'SpawnTower'), ('DeployedTurret', 'DepTurret'), ('DeployedShockMine', 'DepMine'), ('DeployedMine', 'DepMine'),
    ('DeployedRepairer', 'DepRepairStation'), ('DeployedInventoryStation', 'DepInvStation'), ('BaseAccessTerminal', 'ControlSwitch'),
    ('BaseObjectVehicleSpawn', 'VehicleSpawnTank'))


def prop_for_class(cls):
    """Mesh name (lower case) the actor class is drawn with, '' when it has none."""
    for prefix, mesh in PROP_CLASSES:
        if cls.startswith(prefix):
            return mesh.lower()
    return ''


def export_props(idx, game_root, pack_dir, log=print):
    """Rest-pose shapes of the vehicles, base objects and deployables (skeletal meshes bound to their root bone): shapes/tv_prop_<mesh>.json
    and gameplay/props.json {mesh name: shape id}. The biggest mesh of a name wins (the packages hold a small and a big one)."""
    art = os.path.join(game_root, 'Content', 'Art')
    os.makedirs(os.path.join(pack_dir, 'shapes'), exist_ok=True)
    props = {}
    for stem in PROP_PACKAGES:
        path = tv_statics_find(art, stem)
        if path is None:
            continue
        pkg = U.load(path)
        pkg.stem = stem
        best = {}
        for e in pkg.find('SkeletalMesh'):
            if e['name'].lower() not in best or e['size'] > best[e['name'].lower()]['size']:
                best[e['name'].lower()] = e
        for key, e in best.items():
            try:
                mesh = S.parse_skeletal_mesh(pkg, e, lenient=True)
                sid = 'tv_prop_' + _safe(key)
                js = shape_json(idx, pkg, e, mesh, None, pack_dir, METRES_PER_UU, False, sid, log)
                with open(os.path.join(pack_dir, 'shapes', sid + '.json'), 'w', encoding='utf-8') as f:
                    json.dump(js, f, separators=(',', ':'))
                props[key] = sid
            except S.MeshError as ex:
                log('prop %s skipped: %s' % (e['name'], ex))
    os.makedirs(os.path.join(pack_dir, 'gameplay'), exist_ok=True)
    with open(os.path.join(pack_dir, 'gameplay', 'props.json'), 'w', encoding='utf-8') as f:
        json.dump({'pack': 'tribes_v', 'props': props}, f, indent=1)
    log('props: %d rest-pose shapes' % len(props))
    return props
