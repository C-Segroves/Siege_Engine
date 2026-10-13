"""Tribes (1998) and Tribes 2 (2001) deployable packs -> placement rules (docs/TRIBES_BASE_EQUIPMENT.md, Deployables).

Read from the user's game scripts by tools/export_tribes_base.py (it writes them into base_equipment.json
"deployables", keyed by the infantry gear pack id):
  Tribes 1  scripts/item.cs <Pack>::deployShape / onDeploy (and Item::deployShape): the object created (newObject /
            Item::deployShape datablock), GameBase::getLOSInfo(%player, reach), the surface classes it accepts
            (SimTerrain / InteriorShape), the flat-surface test Vector::dot($los::normal, "0 0 1") > x or the
            sticky placement (Vector::getRotation of the normal, snapped up / down past x), checkDeployArea (an
            empty box), the remote turret frequency boxes ($MaxNumTurretsInBox, $TurretBox* of game.cs) and
            $TeamItemMax[<pack>].
  Tribes 2  scripts/deployables.cs: <Pack>Image deployed / maxDepSlope, $MaxDeployableDistance,
            $MinDeployableDistance, testNoTerrainFound / testNoInteriorFound overrides, $Turret<Indoor|Outdoor>Space
            Radius / SphereRadius / MaxPerSphere, $TeamDeployableMax / Min (turrets: one per two players of the
            bigger team, countTurretsAllowed), the sensor packs' maxSensors and the indoor turret's floor / wall /
            ceiling variants by surface angle (getInitialRotation).
A rule set: {item, places: [{deployed, max_angle_deg}], reach, surfaces: [terrain|interior], max_slope_deg,
orient: player|surface|stick, stick_snap, clear_radius, self_clear, turret: {space, sphere, max_per_sphere,
min_box, max_box, max_in_box}, team_max, team_min, per_players, uses}.
"""
import math
import os
import re

import export_tribes_vehicles as V
import siege_paths as P

T1_SCRIPTS = V.T1_SCRIPTS
T2_SCRIPTS = V.T2_SCRIPTS
# The sticky deploys snap upright or upside down when the normal is this close to vertical (item.cs).
T1_SURFACES = {'SimTerrain': 'terrain', 'InteriorShape': 'interior'}
T2_DEPLOY_PACKS = ('InventoryDeployable', 'TurretIndoorDeployable', 'TurretOutdoorDeployable',
                   'MotionSensorDeployable', 'PulseSensorDeployable')


def _read(folder, name):
    with open(os.path.join(folder, name), encoding='latin1') as f:
        return re.sub(r'//[^\n]*', '', f.read())


def _body(text, name):
    m = re.search(r'function\s+%s\s*\(.*?\n\}' % re.escape(name), text, re.S | re.I)
    return m.group(0) if m else ''


def _number(rx, text, default=0.0):
    m = re.search(rx, text, re.S | re.I)
    return float(m.group(1)) if m else default


# ================================================================== Tribes 1

def t1_globals():
    game = _read(T1_SCRIPTS, 'game.cs')
    item = _read(T1_SCRIPTS, 'item.cs')
    g = {k: float(v) for k, v in re.findall(r'\$(MaxNumTurretsInBox|TurretBox\w+)\s*=\s*([\d.]+)', game)}
    g['team_max'] = {k.lower(): int(v) for k, v in re.findall(r'\$TeamItemMax\[(\w+)\]\s*=\s*(\d+)', item)}
    return g


def t1_rules(item_cs, pack, g):
    """The rules of Tribes 1 deploy pack item `pack` ({} when it has no deploy function)."""
    deploy = _body(item_cs, '%s::deployShape' % pack)
    on_deploy = _body(item_cs, '%s::onDeploy' % pack)
    generic = re.search(r'Item::deployShape\(%player,\s*"[^"]*",\s*(\w+)', on_deploy)
    if generic:
        deploy = _body(item_cs, 'Item::deployShape')
        deployed = generic.group(1)
    else:
        m = re.search(r'newObject\("[^"]*",\s*"?\w+"?,\s*"?(\w+)"?,\s*true\)', deploy)
        deployed = m.group(1) if m else None
    if not deployed:
        return {}
    sticky = 'Vector::getRotation' in deploy
    up = _number(r'Vector::dot\(\$los::normal,\s*"0 0 1"\)\s*>\s*([\d.]+)', deploy, 1.0)
    rules = {'item': pack, 'places': [{'deployed': deployed.lower(), 'max_angle_deg': 180.0}],
             'reach': _number(r'getLOSInfo\(%player,\s*([\d.]+)\)', deploy),
             'surfaces': sorted({T1_SURFACES[s] for s in re.findall(r'"(SimTerrain|InteriorShape)"', deploy)}),
             'max_slope_deg': 180.0 if sticky else round(math.degrees(math.acos(min(up, 1.0))), 2),
             'orient': 'stick' if sticky else 'player', 'stick_snap_deg': round(math.degrees(math.acos(up)), 2),
             'clear_box': t1_clear_box() if 'checkDeployArea' in deploy else 0.0,
             'team_max': g['team_max'].get(pack.lower(), 0), 'uses': 1,
             'source': 'scripts/item.cs %s::deployShape / onDeploy' % pack}
    if 'TurretBoxMax' in deploy:
        rules['turret'] = {'max_box': g['TurretBoxMaxLength'], 'max_in_box': int(g['MaxNumTurretsInBox']),
                           'min_box': g['TurretBoxMinLength'], 'same_as': deployed.lower()}
    return rules


def t1_clear_box():
    """checkDeployArea: containerBoxFillSet(..., %pos, 1, 1, 1, 1): nothing but the deployer within this box."""
    body = _body(_read(T1_SCRIPTS, 'item.cs'), 'checkDeployArea')
    return _number(r'containerBoxFillSet\([^,]+,[^,]+,%pos,\s*([\d.]+)', body, 1.0)


def t1_deployables(pack_ids):
    """{pack id: rules} of the Tribes 1 deploy packs in `pack_ids` ({item: pack id})."""
    item_cs = _read(T1_SCRIPTS, 'item.cs')
    g = t1_globals()
    out = {}
    for item, pid in pack_ids.items():
        rules = t1_rules(item_cs, item, g)
        if rules:
            out[pid] = rules
    return out


# ================================================================== Tribes 2

def t2_deployables(resolve, pack_ids):
    """{pack id: rules} of the Tribes 2 deploy packs (`resolve`: datablock fields with inheritance)."""
    text = _read(T2_SCRIPTS, 'deployables.cs')
    glob = {k.lower(): float(v) for k, v in re.findall(r'\$(\w+)\s*=\s*([\d.]+)\s*;', text)}
    team_max = {k.lower(): int(v) for k, v in re.findall(r'\$TeamDeployableMax\[(\w+)\]\s*=\s*(\d+)', text)}
    team_min = {k.lower(): int(v) for k, v in re.findall(r'\$TeamDeployableMin\[(\w+)\]\s*=\s*(\d+)', text)}
    out = {}
    for item in T2_DEPLOY_PACKS:
        pid = pack_ids.get(item)
        image_name = item + 'Image'
        img = resolve(image_name)
        if not pid or not img:
            continue
        surfaces = ['terrain', 'interior']
        if _body(text, image_name + '::testNoTerrainFound'):
            surfaces = ['terrain']
        if _body(text, image_name + '::testNoInteriorFound'):
            surfaces = ['interior']
        rules = {'item': item, 'places': t2_places(text, image_name, img), 'reach': glob['maxdeployabledistance'],
                 'surfaces': surfaces, 'max_slope_deg': float(img.get('maxDepSlope', 180)),
                 'orient': 'surface' if 'turret' in item.lower() else 'stick' if 'motion' in item.lower() else 'player',
                 'clear_radius': glob['mindeployabledistance'], 'self_clear': glob['mindeployabledistance'],
                 'team_max': team_max.get(item.lower(), 0), 'uses': int(float(resolve(item).get('maxSensors', 1))),
                 'source': 'scripts/deployables.cs %s / %s' % (image_name, item)}
        too_close = _body(text, image_name + '::testTurretTooClose')
        if too_close:
            side = re.search(r'\$Turret(Indoor|Outdoor)SpaceRadius', too_close).group(1).lower()
            rules['turret'] = {'space': glob['turret%sspaceradius' % side], 'sphere': glob['turret%ssphereradius' % side],
                               'max_per_sphere': int(glob['turret%smaxpersphere' % side])}
            rules['team_min'] = team_min.get(item.lower(), 0)
            rules['per_players'] = 2      # countTurretsAllowed: mFloor(maxPlayers / 2)
        out[pid] = rules
    return out


def t2_places(text, image_name, img):
    """The deployed datablock, or the indoor turret's variants by surface angle (getInitialRotation)."""
    body = _body(text, image_name + '::getInitialRotation')
    variants = re.findall(r'%surfaceAngle\s*>\s*([\d.]+)\)\s*%item\.deployed\s*=\s*(\w+)', body)
    if variants:
        default = re.search(r'else\s*%item\.deployed\s*=\s*(\w+)', body.split('else if')[-1])
        places, low = [], 0.0
        bounds = sorted((float(a), n) for a, n in variants)
        names = [default.group(1)] + [n for _, n in bounds]
        limits = [b for b, _ in bounds] + [180.0]
        for name, top in zip(names, limits):
            places.append({'deployed': name.lower(), 'min_angle_deg': low, 'max_angle_deg': top})
            low = top
        return places
    return [{'deployed': str(img.get('deployed', '')).lower(), 'max_angle_deg': 180.0}]


def pack_ids(pack):
    """{pack item datablock: gear pack id} of the pack's deploy packs (infantry_gear.json, effect "deploy")."""
    import json
    path = P.pack(pack, 'gameplay', 'infantry_gear.json')
    if not os.path.exists(path):
        return {}
    with open(path, encoding='utf-8') as f:
        packs = json.load(f).get('packs', [])
    return {p['item']: p['id'] for p in packs if p.get('effect') == 'deploy'}
