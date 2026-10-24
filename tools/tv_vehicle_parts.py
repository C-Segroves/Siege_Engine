"""Tribes: Vengeance vehicle bodies with their moving parts -> gamedata/tribes_v (docs/formats/tribes_vengeance.md "Drivable vehicles").

The rest-pose props of tv_skeletal.export_props bind every vertex to the root bone, so a wheel, a wing or a landing leg could not move.
The vehicle meshes keep their vertex influences in front of each level of detail (influences, wedges, triangles, points: ue2_skeletal),
so this step re-exports the four vehicles with every vertex on its own bone and adds, from the same package:

  * the MeshAnimation sequences of the vehicle (assault ship GearDown / GearUp / WingsOpen / WingsClosed ..., tank tread cycles and jet
    doors, pod idle and thrust poses, buggy hatch) as the shape's `ds_sequences`, named as in the original;
  * a node `seat<i>` for each seat whose occupant the original draws: the animation's Character / CharacterLeft / CharacterRight bone is
    where the rider's body stands (`positions` of the vehicle class: occupantConnection, occupantAnimation, hideOccupant);
  * `parts` of the catalog record (gameplay/hercs.json): the wheel nodes with their radius and steering, the sequences the landing gear,
    the wings and the treads play, the tank's turret mesh node (it yaws with the gun) and the Rover's suspension (the shock beside each
    wheel and the wheel class's SuspensionTravel), read by the engine's VehicleParts.

and patches the seat poses (Pod_Stand, Buggy_Stand, AShipGunner_Stand ...) into the soldier bodies that have them.

    python tools/tv_vehicle_parts.py <game root> [pack folder]
"""
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import siege_paths as P  # noqa: E402
import tv_skeletal as SK  # noqa: E402
import tv_weapons as TW  # noqa: E402
import ue2_classes as UC  # noqa: E402
import ue2_package as U  # noqa: E402
import ue2_skeletal as S  # noqa: E402

PACK = TW.PACK
METRES_PER_UU = TW.METRES_PER_UU
VEHICLE_PACKAGE = 'vehicles'
# vehicle key -> (mesh name, class)
BODIES = {'POD': ('Pod', 'VehiclePod'), 'TANK': ('Tank', 'VehicleTank'), 'ASSAULT_SHIP': ('AssaultShip', 'VehicleAssaultShip'),
          'BUGGY': ('Buggy', 'VehicleBuggy')}
CYCLIC = ('idle', 'leftforward', 'leftbackward', 'rightforward', 'rightbackward')
# occupantConnection (a mesh socket) -> the animation bone that carries the rider
SEAT_BONES = {'character': 'character', 'gunnerleft': 'characterleft', 'gunnerright': 'characterright'}
HAND_NODE = 'mount0'
SEAT_NODE = 'seat%d'
# the soldier bodies' seat poses (occupantAnimation names; the armour packages carry them)
RIDER_POSES = ('pod_stand', 'buggy_stand', 'ashipgunner_stand', 'aship_stand')
WHEEL_RADIUS_CLASSES = {'BUGGY': ('BuggyFrontLeftWheel', 'BuggyBackLeftWheel')}
WHEEL_NODES = {'BUGGY': [('BuggyFrontLeftWheel', True), ('BuggyFrontRightWheel', True), ('BuggyBackLeftWheel', False),
                         ('BuggyBackRightWheel', False)]}
TURRET_PART_NODES = {'TANK': 'tankturret'}      # the mesh part that carries the gun's housing: it turns with the gun's aim
SUSPENSION_FIELD = 'SuspensionTravel'     # uu: the whole travel of a wheel from full droop to full compression (HavokCarWheel)
SUSPENSION_REST_SHARE = 0.5               # a wheel rests half way along its travel: it can droop and compress by the same distance
HOVER_SHARE = 0.5                         # a flyer hovers at half its gear trace length (tv_vehicles.HOVER_FRACTION_OF_GEAR_TRACE)
STEER_FIELD = 'SteeringMaxAngle'          # uu-rotation units: 6500 = 35.7 degrees (VehicleBuggy)
TURN = 2.0 * np.pi / 65536.0


MIXED_LIMIT = 0.1                         # more triangles than this on two bones: the influence list is not aligned with the points
COMPONENT_REACH = 1.2                     # a part belongs to a bone when its centre is within this many part radii of the bone
INFLUENCE_DTYPE = np.dtype([('w', '<f4'), ('p', '<u2'), ('b', '<u2')])


def mixed_share(mesh):
    """Share of the triangles whose three points ride different bones (a rigid vehicle has none)."""
    inf = mesh['influences']
    bone = np.zeros(len(mesh['points']), int)
    bone[inf['p']] = inf['b']
    corner = np.stack([mesh['wedges']['i'][mesh['tris']['w'][:, c]] for c in range(3)], axis=1)
    b = bone[corner]
    return float(((b[:, 0] != b[:, 1]) | (b[:, 1] != b[:, 2])).mean())


def triangle_parts(mesh):
    """[[point index]]: the connected parts of the mesh (points that share triangles)."""
    n = len(mesh['points'])
    parent = list(range(n))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    corner = np.stack([mesh['wedges']['i'][mesh['tris']['w'][:, c]] for c in range(3)], axis=1)
    for tri in corner:
        for a, b in ((tri[0], tri[1]), (tri[1], tri[2])):
            ra, rb = find(int(a)), find(int(b))
            if ra != rb:
                parent[ra] = rb
    parts = {}
    for i in range(n):
        parts.setdefault(find(i), []).append(i)
    return list(parts.values())


def part_influences(mesh):
    """Rigid influences made from the mesh's own parts: each connected part follows the bone nearest its centre (the root when no bone
    is within COMPONENT_REACH part radii of it). The vehicles other than the Rover keep their influence list out of step with the points
    (their triangles span several bones), but their wings, legs, engines and tracks are separate parts of the mesh."""
    rig = SK.Rig(mesh['bones'])
    bones = np.array([t for _r, t in rig.rest_world()])
    pts = mesh['points'].astype(float)
    bone = np.zeros(len(pts), np.uint16)
    for idxs in triangle_parts(mesh):
        centre = pts[idxs].mean(0)
        radius = float(np.linalg.norm(pts[idxs] - centre, axis=1).max())
        d = np.linalg.norm(bones[1:] - centre, axis=1)
        nearest = int(d.argmin()) + 1
        if d[nearest - 1] <= radius * COMPONENT_REACH:
            bone[idxs] = nearest
    out = np.zeros(len(pts), INFLUENCE_DTYPE)
    out['w'], out['p'], out['b'] = 1.0, np.arange(len(pts)), bone
    return out


def best_by_name(pkg, class_name):
    """{lower-case name: the biggest export of that name} (the packages hold a small and a big version)."""
    best = {}
    for e in pkg.find(class_name):
        key = e['name'].lower()
        if key not in best or e['size'] > best[key]['size']:
            best[key] = e
    return best


def sequence_names(anim):
    return {n.lower(): n for n in anim['seqs']}


def add_node(js, name, parent, transform):
    """Appends a node called `name` below node index `parent` with the transform [rx, ry, rz, x, y, z]; returns its index."""
    for i, nd in enumerate(js['nodes']):
        if nd['name'].lower() == name.lower():
            js['transforms'][nd['default']] = transform
            return i
    js['transforms'].append(transform)
    js['nodes'].append({'parent': parent, 'default': len(js['transforms']) - 1, 'name': name})
    return len(js['nodes']) - 1


def character_transform(anim, bone_name):
    """The first key of the animation bone `bone_name` as a shape node transform, or None (every sequence keys the same rest position)."""
    for seq in anim['seqs'].values():
        tr = seq['tracks'].get(bone_name.lower())
        if tr is not None and len(tr['quats']) and len(tr['pos']):
            return SK.shape_transform(SK.quat_matrix(tr['quats'][0], True), tr['pos'][0], METRES_PER_UU)
    return None


def seat_class_rows(classes, cls):
    """The `positions` struct array of the vehicle class (from the class of its chain that defines it: its own name table)."""
    for name in classes.chain(cls):
        own = classes.own_properties(name)
        if 'positions' in own:
            return UC.struct_array(classes.package_of(name), own['positions'])
    return []


def is_hidden(row):
    return bool(row.get('hideOccupant', False))


def seat_node_name(row):
    return str(row.get('occupantConnection', 'None')).lower()


def pose_of(row):
    name = str(row.get('occupantAnimation', 'None'))
    return [name.lower()] if name and name != 'None' else []


def add_seat_nodes(js, anim, rows):
    """A node `seat<i>` for every seat the original draws; returns {seat index: node name} of the seats that got one."""
    placed = {}
    for i, row in enumerate(rows):
        bone = SEAT_BONES.get(seat_node_name(row))
        tf = character_transform(anim, bone) if bone and not is_hidden(row) else None
        if tf is not None:
            add_node(js, SEAT_NODE % i, 0, tf)
            placed[i] = SEAT_NODE % i
    return placed


def seat_records(roles, rows, placed, gunner_pitch):
    """vehicle_seats.json rows: role, the node the rider shows on (the hand node when he is not drawn), his pose sequence."""
    out = []
    for i, role in enumerate(roles):
        row = rows[i] if i < len(rows) else {}
        shown = i in placed
        rec = {'seat': i, 'role': role, 'node': placed.get(i, HAND_NODE), 'shown': shown, 'pose': pose_of(row) if shown else ['sitting'],
               'weapon_shown': False}
        if role == 'gunner':
            rec['pitch_min_deg'], rec['pitch_max_deg'] = gunner_pitch
        out.append(rec)
    return out


def export_body(idx, pkg, mesh_entry, anim_entry, pack_dir, stem, log):
    """(shape json, mesh, anim): the vehicle with every vertex on its bone and the animation's sequences."""
    mesh = S.parse_skeletal_mesh(pkg, mesh_entry, lenient=True)
    if mixed_share(mesh) > MIXED_LIMIT:
        mesh['influences'] = part_influences(mesh)
    anim = S.parse_animation(pkg, anim_entry)
    js = SK.shape_json(idx, pkg, mesh_entry, mesh, None, pack_dir, METRES_PER_UU, False, stem, log)
    rig = SK.Rig(mesh['bones'])
    seqs = []
    for name, seq in anim['seqs'].items():
        if seq['tracks'] and seq['frames'] >= 1:
            seqs.append(SK.sequence_json(rig, seq, name.lower(), name.lower() in CYCLIC, METRES_PER_UU, js['transforms']))
    js['ds_sequences'] = seqs
    bound = len(js['lods'][0]['pieces'])
    log('  %-14s bones %2d  pieces bound to %2d bones  sequences %s' % (stem, len(mesh['bones']), bound, [q['name'] for q in seqs]))
    return js, mesh, anim


def wheel_parts(key, classes, js):
    """The wheels of a car: node names, radius (m) and which steer."""
    wheels = []
    names = {nd['name'].lower() for nd in js['nodes']}
    radius = 0.0
    for cls in WHEEL_RADIUS_CLASSES.get(key, ()):
        radius = max(radius, TW.uu(classes.defaults(cls).get('WheelRadius', 0.0)))
    for node, steer in WHEEL_NODES.get(key, []):
        if node.lower() in names:
            wheels.append({'node': node, 'steer': steer})
    return {'radius_m': round(radius, 3), 'list': wheels} if wheels else {}


def tread_stride(anim):
    """Metres the track teeth travel in one cycle of leftforward: the longest translation of a tooth bone over the cycle's frames."""
    seq = anim['seqs']['leftforward']
    frames = max(int(seq['frames']), 2)
    best = 0.0
    for tr in seq['tracks'].values():
        if len(tr['pos']) > 1:
            best = max(best, float(np.linalg.norm(tr['pos'][-1] - tr['pos'][0])))
    return round(best * METRES_PER_UU * frames / (frames - 1), 3)


def has_node(js, name):
    return any(nd['name'].lower() == name.lower() for nd in js['nodes'])


def turret_parts(key, js):
    """The mesh node that yaws with the vehicle's turret ({} when the vehicle has none)."""
    node = TURRET_PART_NODES.get(key)
    return {'node': node} if node and has_node(js, node) else {}


def suspension_parts(key, classes, js):
    """The Rover's suspension: the wheel class's SuspensionTravel (m) split into compression and droop about the rest position, and the
    shock node of each wheel (the wheel's name with Shock for Wheel; the class's SupportBoneName)."""
    wheels = []
    for node, _steer in WHEEL_NODES.get(key, []):
        shock = node.replace('Wheel', 'Shock')
        if has_node(js, node) and has_node(js, shock):
            wheels.append({'wheel': node, 'shock': shock})
    if not wheels:
        return {}
    travel = TW.uu(classes.defaults(WHEEL_RADIUS_CLASSES[key][0]).get(SUSPENSION_FIELD, 0.0))
    return {'compress_m': round(travel * SUSPENSION_REST_SHARE, 3), 'droop_m': round(travel * (1.0 - SUSPENSION_REST_SHARE), 3), 'wheels': wheels}


def make_parts(key, classes, cls, js, anim):
    """The `parts` block of the catalog record (the engine's VehicleParts): wheels, steering angle, landing gear, wings, treads."""
    seqs = sequence_names(anim)
    parts = {}
    wheels = wheel_parts(key, classes, js)
    if wheels:
        parts['wheels'] = wheels
        parts['steer_max_rad'] = round(float(classes.defaults(cls).get(STEER_FIELD, 6500.0)) * TURN, 4)
    if 'geardown' in seqs and 'gearup' in seqs:
        trace = TW.uu(classes.defaults(cls).get('gearTraceLength', 600.0))         # the gear is out when the ground is this near
        parts['gear'] = {'down': 'geardown', 'up': 'gearup', 'start_alt_m': round(trace, 2), 'full_alt_m': round(trace * HOVER_SHARE, 2)}
    if 'wingsopen' in seqs and 'wingsclosed' in seqs:
        parts['wings'] = {'open': 'wingsopen', 'closed': 'wingsclosed', 'left': 'wingsleft', 'right': 'wingsright'}
    if 'leftforward' in seqs and 'rightforward' in seqs:
        parts['treads'] = {'left': {'forward': 'leftforward', 'backward': 'leftbackward'},
                           'right': {'forward': 'rightforward', 'backward': 'rightbackward'}, 'stride_m': tread_stride(anim),
                           'left_node': 'LeftTrack', 'right_node': 'RightTrack'}
    if turret_parts(key, js):
        parts['turret'] = turret_parts(key, js)
    if suspension_parts(key, classes, js):
        parts['suspension'] = suspension_parts(key, classes, js)
    if 'idle' in seqs:
        parts['idle'] = 'idle'
    if 'thrust' in seqs and 'dive' in seqs:
        parts['thrust'] = {'forward': 'throttleforward', 'back': 'throttleback', 'thrust': 'thrust', 'dive': 'dive',
                           'strafe_left': 'strafeleft', 'strafe_right': 'straferight'}
    return parts


def export_vehicle_bodies(idx, game_root, pack_dir, log=print):
    """Re-exports the four vehicle shapes bound to their bones; returns {key: {'shape', 'parts', 'rows', 'placed'}} for the catalog."""
    art = os.path.join(game_root, 'Content', 'Art')
    pkg = U.load(SK.tv_statics_find(art, VEHICLE_PACKAGE))
    pkg.stem = VEHICLE_PACKAGE
    meshes, anims = best_by_name(pkg, 'SkeletalMesh'), best_by_name(pkg, 'MeshAnimation')
    classes = UC.ClassIndex(game_root)
    out = {}
    for key, (mesh_name, cls) in BODIES.items():
        stem = 'tv_prop_' + mesh_name.lower()
        js, mesh, anim = export_body(idx, pkg, meshes[mesh_name.lower()], anims[mesh_name.lower()], pack_dir, stem, log)
        rows = seat_class_rows(classes, cls)
        placed = add_seat_nodes(js, anim, rows)
        out[key] = {'stem': stem, 'js': js, 'parts': make_parts(key, classes, cls, js, anim), 'rows': rows, 'placed': placed}
        log('  %-14s seats drawn %s' % (stem, sorted(placed)))
    return out


def write_shape(pack_dir, stem, js):
    with open(os.path.join(pack_dir, 'shapes', stem + '.json'), 'w', encoding='utf-8') as f:
        json.dump(js, f, separators=(',', ':'))


# ------------------------------------------------------------------------------------------------ rider poses
def patch_rider_poses(idx, game_root, pack_dir, log=print):
    """Adds the vehicle seat poses to the soldier bodies of the pack that have them in their animation package; returns the count of bodies."""
    art = os.path.join(game_root, 'Content', 'Art')
    path = os.path.join(pack_dir, 'gameplay', 'bodies.json')
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    packages = {}
    patched = 0
    for body in doc['bodies']:
        shape_path = os.path.join(pack_dir, 'shapes', body['id'] + '.json')
        if not os.path.isfile(shape_path):
            continue
        pkg = packages.get(body['package'])
        if pkg is None:
            found = SK.tv_statics_find(art, body['package'])
            pkg = packages[body['package']] = U.load(found) if found else False
        if not pkg:
            continue
        added = add_rider_poses(idx, pkg, body, shape_path, log)
        if added:
            body['sequences'] = body.get('sequences', []) + [n for n in added if n not in body.get('sequences', [])]
            patched += 1
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
    return patched


def add_rider_poses(idx, pkg, body, shape_path, log):
    """Appends the RIDER_POSES the body's animation has to its shape file; returns the names added."""
    entries = [e for e in pkg.find('SkeletalMesh') if e['name'].lower() == body['mesh'].lower()]
    if not entries:
        return []
    with open(shape_path, encoding='utf-8') as f:
        js = json.load(f)
    have = {q['name'] for q in js['ds_sequences']}
    if all(p in have for p in RIDER_POSES):
        return []
    mesh = S.parse_skeletal_mesh(pkg, max(entries, key=lambda e: e['size']), lenient=True)
    anim = SK.pick_animation(pkg, mesh)
    if anim is None:
        return []
    rig = SK.Rig(mesh['bones'])
    added = []
    for want in RIDER_POSES:
        key, seq = SK.find_sequence(anim['seqs'], [want])
        if seq is None or want in have or not seq['tracks']:
            continue
        js['ds_sequences'].append(SK.sequence_json(rig, seq, want, True, METRES_PER_UU, js['transforms']))
        added.append(want)
    if added:
        with open(shape_path, 'w', encoding='utf-8') as f:
            json.dump(js, f, separators=(',', ':'))
        log('  body %-26s + %s' % (body['id'], added))
    return added


# ------------------------------------------------------------------------------------------------ catalog patch
def retrofit_catalog(game_root, pack_dir, log=print):
    """Gives the installed catalog records (gameplay/hercs.json) the turret and suspension parts and the class's original TopSpeed
    (m/s: what a script's DesiredSpeed is a share of) without exporting the vehicles again; returns the number of records patched."""
    classes = UC.ClassIndex(game_root)
    path = os.path.join(pack_dir, 'gameplay', 'hercs.json')
    with open(path, encoding='utf-8') as f:
        doc = json.load(f)
    patched = 0
    for key, (mesh_name, cls) in BODIES.items():
        shape_path = os.path.join(pack_dir, 'shapes', 'tv_prop_%s.json' % mesh_name.lower())
        if key not in doc or not os.path.isfile(shape_path):
            continue
        with open(shape_path, encoding='utf-8') as f:
            js = json.load(f)
        rec = doc[key]
        for name, block in (('turret', turret_parts(key, js)), ('suspension', suspension_parts(key, classes, js))):
            if block:
                rec['parts'][name] = block
        rec['top_speed_mps'] = round(TW.uu(classes.defaults(cls).get('TopSpeed', 0.0)), 2)
        patched += 1
        log('  %-14s parts %s  original top speed %.1f m/s' % (key, sorted(rec['parts']), rec['top_speed_mps']))
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(doc, f, indent=1)
    return patched
