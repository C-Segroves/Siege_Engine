"""Tribes: Vengeance campaign import -> pack "tribes_v" (docs/formats/tribes_vengeance.md).

  python tools/tv_import.py <game root | TribesVengeance.zip> <pack folder> [--keep-scratch]

The game root is the unpacked installer's "app/Tribes Vengeance" folder (tools/tv_unpack.py makes it; a zip is
unpacked into a short scratch folder first and the scratch is deleted afterwards).

Also terrain, static meshes and editor brushes (tv_terrain, tv_statics, tv_bsp; --only=<map> converts one map) and the drivable
vehicles (tv_vehicles: hercs.json, weapons_engine.json, vehicle_seats.json and the maps' "vehicles" lists).
Writes: campaign/campaign.json (16 chapters, 29 maps in play order: names, objective text, a dialogue excerpt for
the briefing), maps/<Id>/map.json (player and NPC spawns, objective markers as waypoints, placeholder flat ground,
positions in metres) and maps/_index.json. No geometry yet. Everything is read from the user's own copy.
"""
import json
import math
import os
import re
import shutil
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ue2_package as U  # noqa: E402
import fx_default  # noqa: E402
import tv_weapons  # noqa: E402
import tv_assets  # noqa: E402
import tv_audio  # noqa: E402
import tv_bsp  # noqa: E402
import tv_lights  # noqa: E402
import tv_script  # noqa: E402
import tv_skeletal  # noqa: E402
import tv_statics  # noqa: E402
import tv_terrain  # noqa: E402
import tv_vehicles  # noqa: E402

PACK = 'tribes_v'
METRES_PER_UU = 1.0 / 70.0          # the Pawn collision is 156 units tall; the engine soldier is 2.2 m (docs/formats/tribes_vengeance.md)
SPAWN_LIFT_M = 1.0
BRIEFING_LINES = 6


# ---------------------------------------------------------------------------------------------- text files
def read_text(path):
    raw = open(path, 'rb').read()
    if raw[:2] in (b'\xff\xfe', b'\xfe\xff'):
        return raw.decode('utf-16')
    try:
        return raw.decode('utf-8-sig')
    except UnicodeDecodeError:
        return raw.decode('cp1252')


def read_int(path):
    """{section: {key: value}} of an Unreal .int file (keys in file order, quotes stripped)."""
    out, sec = {}, None
    if not os.path.isfile(path):
        return out
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line or line.startswith(';'):
            continue
        if line.startswith('[') and line.endswith(']'):
            sec = out.setdefault(line[1:-1], {})
        elif '=' in line and sec is not None:
            k, v = line.split('=', 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
                v = v[1:-1]
            sec[k.strip()] = v.strip()
    return out


def parse_campaign_ini(text):
    """[{number, name, maps: [{map, start_cutscene, end_cutscene}]}] from Campaign.ini (the '; NN-Name' comments
    start a chapter, each missions=(...) line is one map)."""
    chapters, cur = [], None
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r';\s*(\d\d)-(\w+)', line)
        if m:
            cur = {'number': int(m.group(1)), 'name': m.group(2), 'maps': []}
            chapters.append(cur)
        elif line.startswith('missions=(') and cur is not None:
            kv = dict(re.findall(r'(\w+)="?([^",)]*)"?', line[len('missions=('):]))
            cur['maps'].append({'map': kv['mapName'], 'start_cutscene': kv.get('startCutsceneMap', ''),
                                'end_cutscene': kv.get('endCutsceneMap', '')})
    return chapters


# ---------------------------------------------------------------------------------------------- actors
def to_world(v):
    """Unreal (x forward, y right, z up; units) -> engine metres (x right, y up, -z forward)."""
    return [round(v[1] * METRES_PER_UU, 3), round(v[2] * METRES_PER_UU, 3), round(-v[0] * METRES_PER_UU, 3)]


def yaw_degrees(rotation_raw):
    """Unreal rotator (three int32, 65536 per turn) -> engine yaw in degrees."""
    if not isinstance(rotation_raw, (bytes, bytearray)) or len(rotation_raw) != 12:
        return 0.0
    yaw = struct.unpack('<3i', rotation_raw)[1]
    return round(-(yaw % 65536) * 360.0 / 65536.0, 2)


def wanted_class(cls):
    return cls in ('SPStartDefault', 'PlayerStart', 'SinglePlayerStart', 'AISpawnPoint', 'TriggerRadius') or (cls.startswith('AI') and cls != 'AICommon') or tv_skeletal.prop_for_class(cls) != ''


def read_actors(pkg):
    """[(export, class name, properties)] of the spawn, trigger-marker and AI exports that have a Location."""
    out = []
    for e in pkg.exports:
        if e['size'] < 16 or not wanted_class(pkg.class_name(e)):
            continue
        props = U.object_properties(pkg, e)
        if isinstance(props.get('Location'), (bytes, bytearray)) and len(props['Location']) == 12:
            out.append((e, pkg.class_name(e), props))
    return out


def _team_of(props):
    """The TeamInfo<Faction><n> name of an AI actor (the property name varies: m_team, Team or a mis-read tag)."""
    for v in props.values():
        if isinstance(v, str) and v.startswith('TeamInfo'):
            return v
    return ''


def actor_pos(props):
    return to_world(U.vec3(props['Location']))


def export_map(pkg, map_id, name, props=None, pad_table=None):
    """The engine map dictionary of one mission package, and its objective keys in script order."""
    actors = read_actors(pkg)
    by_label = {p.get('Label'): (c, p) for _e, c, p in actors if p.get('Label')}
    spawns, npcs = [], []
    squads = {e['name']: U.object_properties(pkg, e).get('Label', e['name']) for e in pkg.find('AISquad')}
    for _e, cls, p in actors:
        if cls in ('SPStartDefault', 'PlayerStart', 'SinglePlayerStart'):
            spawns.append({'kind': 'infantry', 'pos': actor_pos(p), 'yaw': yaw_degrees(p.get('Rotation')),
                           'team': 0, 'radius': 20.0, 'pawn': p.get('PawnClass', ''), 'team_name': str(p.get('Team', ''))})
        elif cls == 'AISpawnPoint':
            klass = p.get('spawnAICharacterClass', '')
            npcs.append({'kind': 'npc', 'pos': actor_pos(p), 'yaw': yaw_degrees(p.get('Rotation')),
                         'label': p.get('aiCharacterLabel', '') or p.get('Label', ''), 'spawn_label': p.get('Label', ''),
                         'class': klass, 'body': tv_skeletal.npc_body(klass), 'team': _team_of(p),
                         'enabled': bool(p.get('Enabled', True)), 'spawn_point': True})
        elif cls.startswith('AI') and cls not in ('AISpawnPoint', 'AISquad', 'AITalkingHead'):
            npcs.append({'kind': 'npc', 'pos': actor_pos(p), 'yaw': yaw_degrees(p.get('Rotation')),
                         'label': p.get('Label', ''), 'class': cls, 'body': tv_skeletal.npc_body(cls), 'team': _team_of(p),
                         'squad': squads.get(str(p.get('m_squad', '')), ''), 'enabled': True, 'spawn_point': False})
    objectives, waypoints = [], []
    for e in pkg.exports:
        if pkg.class_name(e) != 'ActionObjectiveAdd':
            continue
        p = U.object_properties(pkg, e)
        key, marker = p.get('Description') or p.get('objectiveName'), p.get('ObjectiveActors')
        if not key:
            continue
        objectives.append({'key': key, 'name': p.get('objectiveName', '')})
        target = by_label.get(marker)
        if target is not None:
            waypoints.append({'pos': actor_pos(target[1]), 'objective': key, 'marker': marker})
    placed = []
    for _e, cls, p in actors:
        if tv_vehicles.vehicle_id_of(cls) or tv_vehicles.is_pad(cls):       # drivable or a pad: a record below, not scenery
            continue
        mesh = tv_skeletal.prop_for_class(cls)
        shape = (props or {}).get(mesh) if mesh else None
        if shape:
            scale = float(p.get('DrawScale', 1.0))
            s3 = U.vec3(p.get('DrawScale3D', b'')) or (1.0, 1.0, 1.0)
            b = tv_statics._basis(p.get('Rotation'), [scale * s3[0], scale * s3[1], scale * s3[2]])
            placed.append({'shape': 'tribes_v:' + shape, 'pos': actor_pos(p), 'basis': [[round(float(x), 5) for x in row] for row in b],
                           'collide': True, 'actor': cls})
    all_pos = [actor_pos(p) for _e, c, p in actors if not tv_skeletal.prop_for_class(c)]
    xs, zs = [q[0] for q in all_pos] or [0.0], [q[2] for q in all_pos] or [0.0]
    ground = (min(s['pos'][1] for s in spawns) - SPAWN_LIFT_M) if spawns else 0.0
    pads = tv_vehicles.export_pads(actors, pad_table or {}, to_world, tv_statics._basis, _team_of, yaw_degrees)
    m = {'pack': PACK, 'id': map_id, 'name': name, 'source': map_id + '.tvm', 'modes': [], 'original_modes': [],
         'mode_objects': [], 'mode_settings': {},
         'bounds': {'min': [round(min(xs) - 50, 1), round(min(zs) - 50, 1)], 'max': [round(max(xs) + 50, 1), round(max(zs) + 50, 1)]},
         'ground_y': round(ground, 3), 'environment': {}, 'interiors': [], 'statics': [], '_props': placed, 'spawns': spawns + [],
         'vehicles': tv_vehicles.export_vehicles(actors, to_world, tv_statics._basis, _team_of, yaw_degrees),
         'vehicle_pads': pads, 'stations': tv_vehicles.make_pad_stations(pads), 'power': [], 'switch': [], 'power_groups': [], 'waypoints': waypoints, 'cameras': [],
         'npc_spawns': npcs, 'objectives': objectives,
         'notes': 'Tribes: Vengeance %s: terrain heightmap, textured static meshes and the editor brushes (approximate '
                  'room shells) are converted, with the sun, zone ambient, fog and point lights; the compiled BSP, lightmaps, water, decorations and skeletal models are not. '
                  'Flat ground at ground_y where the map has no terrain. Positions are metres (Unreal units x %.5f).'
                  % (map_id, METRES_PER_UU)}
    return m


def _terrain_bounds(t):
    w, h = t['size']
    x0, z0 = t['origin']
    return {'min': [x0, z0], 'max': [round(x0 + (w - 1) * t['square'], 1), round(z0 + (h - 1) * t['square'], 1)]}


def dialogue_excerpt(pkg, texts):
    """The first spoken lines of the mission script (ActionSpeak speech tags), as a briefing stand-in."""
    out = []
    for e in pkg.exports:
        if pkg.class_name(e) == 'ActionSpeak':
            tag = U.object_properties(pkg, e).get('SpeechTag')
            if tag in texts and texts[tag] not in out:
                out.append(texts[tag])
            if len(out) >= BRIEFING_LINES:
                break
    return out


def map_sounds(pkg, voice_files, pack_dir):
    """(sound stems played by the map's ActionPlaySound, speech tags of its ActionSpeak that have an .ogg, copied to the pack)."""
    stems, tags = [], []
    for e in pkg.exports:
        cls = pkg.class_name(e)
        if cls == 'ActionPlaySound':
            ref = U.object_properties(pkg, e).refs.get('SoundToPlay', 0)
            stem = tv_audio.sound_import_name(pkg, ref)
            if stem and stem not in stems:
                stems.append(stem)
        elif cls == 'ActionSpeak':
            tag = U.object_properties(pkg, e).get('SpeechTag')
            if tag and tag not in tags:
                tags.append(tag)
    return stems, tv_audio.copy_voice(voice_files, tags, pack_dir)


# ---------------------------------------------------------------------------------------------- driver
def system_dir(game_root):
    return os.path.join(game_root, 'Content', 'System')


def tx_sections(chapter_text):
    return [chapter_text.get('Objectives', {}), chapter_text.get('Mission Text', {})]


def find_game_root(path):
    for dirpath, dirs, _files in os.walk(path):
        if 'Content' in dirs and os.path.isdir(os.path.join(dirpath, 'Content', 'Maps')):
            return dirpath
    raise FileNotFoundError('no Tribes: Vengeance Content/Maps folder under ' + path)


def _ci_file(folder, name):
    low = name.lower()
    for f in os.listdir(folder):
        if f.lower() == low:
            return os.path.join(folder, f)
    return None


def load_texts(game_root):
    """(chapters of Campaign.ini, {chapter number: its text sections}, the prompt sections): the mission text of every campaign map."""
    system = os.path.join(game_root, 'Content', 'System')
    loc = os.path.join(system, 'Localisation', 'Maps', 'text files')
    chapters = parse_campaign_ini(read_text(os.path.join(system, 'Campaign.ini')))
    chapter_texts = {}
    for f in os.listdir(loc):
        m = re.match(r'SP-(\d\d)', f)
        if m:
            chapter_texts[int(m.group(1))] = read_int(os.path.join(loc, f))
    prompts = read_int(os.path.join(system_dir(game_root), 'Localisation', 'GUI', 'Prompts.int'))
    return chapters, chapter_texts, prompts


def make_map_texts(chapter_texts, prompts, number):
    """{lower-case key: text} the scripts of a chapter's maps look their speech and prompts up in."""
    return {k.lower(): v for sec in list(tx_sections(chapter_texts.get(number, {}))) + list(prompts.values()) for k, v in sec.items()}


def import_campaign(game_root, pack_dir, log=print, only=None):
    idx = tv_assets.PackageIndex(game_root)
    tv_audio.export_sounds(game_root, pack_dir, log=log)
    fx_default.export(PACK, pack_dir)                  # death effects: engine defaults + its Explo_* sounds
    log('weapons: %d hand weapons' % tv_weapons.export(game_root, pack_dir))   # after the sounds (fire sounds) and fx (merges its effects)
    if not only or not os.path.isfile(os.path.join(pack_dir, 'gameplay', 'bodies.json')):
        tv_skeletal.export_bodies(idx, game_root, pack_dir, log=log)
    props_file = os.path.join(pack_dir, 'gameplay', 'props.json')
    if not only or not os.path.isfile(props_file):
        props = tv_skeletal.export_props(idx, game_root, pack_dir, log=log)
    else:
        with open(props_file, encoding='utf-8') as f:
            props = json.load(f)['props']
    log('vehicles: %d drivable' % tv_vehicles.export(game_root, pack_dir, log=log))      # after the props (their shapes) and the weapon sounds
    chapters, chapter_texts, prompts = load_texts(game_root)
    pad_table = tv_vehicles.make_pad_table(game_root)
    voice_files = tv_audio.find_voice_files(game_root)
    shape_cache = {}
    content = os.path.join(game_root, 'Content')
    system, maps_dir = os.path.join(content, 'System'), os.path.join(content, 'Maps')
    out_maps = os.path.join(pack_dir, 'maps')
    os.makedirs(os.path.join(pack_dir, 'campaign'), exist_ok=True)
    missions, index = [], []
    for ch in chapters:
        tx = chapter_texts.get(ch['number'], {})
        objective_text = tx.get('Objectives', {})
        speech = tx.get('Mission Text', {})
        for k, entry in enumerate(ch['maps']):
            path = _ci_file(maps_dir, entry['map'] + '.tvm')
            if path is None:
                log('missing map package ' + entry['map'])
                continue
            if only and entry['map'].lower() not in only:
                continue
            pkg = U.load(path)
            pkg.stem = entry['map'].lower()
            title = read_int(os.path.join(system, entry['map'] + '.int')).get('LevelSummary', {}).get('Title', '').strip()
            m = export_map(pkg, os.path.splitext(os.path.basename(path))[0], title or entry['map'], props, pad_table)
            m['statics'], failed = tv_statics.export_statics(idx, pkg, pack_dir, METRES_PER_UU, shape_cache)
            m['statics'].extend(m.pop('_props'))
            if failed:
                log('  %d static meshes not converted' % failed)
            bsp = tv_bsp.export_bsp(idx, pkg, pack_dir, m['id'].lower(), METRES_PER_UU)
            if bsp:
                m['statics'].insert(0, bsp)
            m['environment'], m['point_lights'] = tv_lights.export_lighting(pkg, to_world, METRES_PER_UU)
            m['sounds'], m['voice'] = map_sounds(pkg, voice_files, pack_dir)
            texts = make_map_texts(chapter_texts, prompts, ch['number'])
            script = tv_script.compile_map(pkg, to_world, texts, METRES_PER_UU)
            m['player_team'] = next((sp.get('team_name', '') for sp in m['spawns'] if sp.get('team_name')), '')
            keys = [q['key'] for q in m['objectives'] if q['key'] in objective_text]
            lines = [objective_text[q] for q in keys]
            excerpt = dialogue_excerpt(pkg, speech)
            os.makedirs(os.path.join(out_maps, m['id']), exist_ok=True)
            terrain = tv_terrain.export_terrain(idx, pkg, os.path.join(out_maps, m['id']), METRES_PER_UU)
            if terrain:
                m['terrain'] = terrain
                m['bounds'] = _terrain_bounds(terrain)
            with open(os.path.join(out_maps, m['id'], 'script.json'), 'w', encoding='utf-8') as f:
                json.dump(script, f, separators=(',', ':'), ensure_ascii=False)
            m['script'] = 'script.json'
            with open(os.path.join(out_maps, m['id'], 'map.json'), 'w', encoding='utf-8') as f:
                json.dump(m, f, indent=1, ensure_ascii=False)
            missions.append({
                'folder': m['id'], 'map': m['id'], 'name': title or entry['map'], 'kind': 'mission',
                'chapter': ch['number'], 'chapter_name': ch['name'], 'part': k + 1,
                'start_cutscene': entry['start_cutscene'], 'end_cutscene': entry['end_cutscene'],
                'objectives_text': ('OBJECTIVES\n\n' + '\n'.join(' - ' + t for t in lines)) if lines else '',
                'index': len(missions),
                'briefing': '\n\n'.join(excerpt)})
            index.append({'id': m['id'], 'name': m['name'], 'modes': [], 'terrain': 'terrain' in m,
                          'spawns': {'infantry': len(m['spawns']), 'npc': len(m['npc_spawns'])},
                          'waypoints': len(m['waypoints'])})
            log('%-28s %2d spawns %3d npc %2d waypoints %d objectives' % (m['id'], len(m['spawns']), len(m['npc_spawns']),
                                                                         len(m['waypoints']), len(keys)))
    with open(os.path.join(out_maps, '_index.json'), 'w', encoding='utf-8') as f:
        json.dump(index, f, indent=1, ensure_ascii=False)
    with open(os.path.join(pack_dir, 'campaign', 'campaign.json'), 'w', encoding='utf-8') as f:
        json.dump({'id': 'main', 'name': 'Tribes: Vengeance', 'missions': missions}, f, indent=1, ensure_ascii=False)
    return {'missions': len(missions), 'chapters': len(chapters)}


def write_pack_json(pack_dir, extra=None):
    meta = {'name': 'Tribes: Vengeance', 'engine': 'unreal_2_5', 'unit_scale': 1.0, 'world_metres_per_unit': 1.0,
            'placeholder_shapes': True, 'era': 5, 'game': 'tribes_v'}
    meta.update(extra or {})
    with open(os.path.join(pack_dir, 'pack.json'), 'w', encoding='utf-8') as f:
        json.dump(meta, f, indent=1)


def main(argv):
    keep = '--keep-scratch' in argv
    only = {a.split('=', 1)[1].lower() for a in argv if a.startswith('--only=')}
    args = [a for a in argv if not a.startswith('--')]
    if len(args) != 2:
        sys.exit(__doc__)
    src, pack_dir = args
    scratch = None
    try:
        if src.lower().endswith('.zip'):
            import tv_unpack
            scratch = tempfile.mkdtemp(prefix='tvs', dir=os.path.splitdrive(tempfile.gettempdir())[0] + os.sep)
            root = find_game_root(tv_unpack.unpack(src, scratch))
        else:
            root = find_game_root(src)
        os.makedirs(pack_dir, exist_ok=True)
        res = import_campaign(root, pack_dir, only=only or None)
        write_pack_json(pack_dir, {'provides': {'missions': res['missions'], 'hercs': len(tv_vehicles.VEHICLES)}})
        print(res)
    finally:
        if scratch and not keep:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == '__main__':
    main(sys.argv[1:])
