"""Multiplayer game modes of every map, and the original rule values (docs/formats/game_modes.md).

What a map supports is read from the map's own mission data, never from a list:
  Tribes 2   the header "// MissionTypes = ..." plus each object's missionTypesList (inherited from its SimGroup):
             Flag items, Exterior/InteriorFlagStand, FlipFlop switches, the Nexus; MissionGroup <Type>_scoreLimit.
  Tribes 1   the .dsc $MDESC::Type (Capture the Flag, Capture and Hold, Defend and Destroy, Find and Retrieve,
             Deathmatch, Multiple Team), the mission's $teamScoreLimit, Flag items (team flags or neutral F&R flags),
             FlagStands, TowerSwitches (their group's deltaTeamScore) and any object with a scoreValue (D&D).
  Starsiege  the file prefix (CTF_, DM_, WAR_, Starsiege_Football) and the map script: CTF flags and
             <Colour>FlagTrigger boxes, the football RedGoal / BlueGoal / OutOfBounds triggers, the WAR bases'
             generators and HQ; the script's constants ($maxFlagCount, $flagTime, $WinScore ...).
A mode is kept only when the objects it needs are there (CTF: two team flags, C&H: a switch, Hunters: a Nexus ...).

Writes, for maps already exported by export_darkstar_maps.py / export_tribes2_maps.py (importer step "modes" runs
after "maps"; annotate_* take one mission each):
  maps/<id>/map.json    "modes" (engine mode ids), "original_modes", "mode_objects", "mode_settings"
  maps/_index.json      "modes", "mode_objects" (counts per kind)
  gameplay/game_modes.json   rule values from the user's game scripts (Tribes 2 *Game.cs, Tribes 1 objectives.cs,
                             Starsiege multiplayer libraries), keyed by engine mode id.

Usage: python tools/export_game_modes.py [tribes] [tribes2] [starsiege]
"""
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

# original mode names -> engine mode ids (game/engine/game_modes/game_modes.json)
CANON = {
    'ctf': 'ctf', 'capture the flag': 'ctf',
    'cnh': 'capture_hold', 'c&h': 'capture_hold', 'capture and hold': 'capture_hold',
    'dnd': 'defend_destroy', 'd&d': 'defend_destroy', 'defend and destroy': 'defend_destroy',
    'f&r': 'find_retrieve', 'find and retrieve': 'find_retrieve', 'retrieve': 'find_retrieve',
    'dm': 'deathmatch', 'deathmatch': 'deathmatch', 'tdm': 'team_deathmatch',
    'hunters': 'hunters', 'teamhunters': 'team_hunters', 'rabbit': 'rabbit', 'bounty': 'bounty', 'siege': 'siege',
    'war': 'war', 'football': 'football',
}
# what each mode needs on the map: (object kind, minimum count, team flag: only team-owned objects count)
REQUIRES = {
    'ctf': [('flag', 2, True)],
    'capture_hold': [('switch', 1, False)],
    'defend_destroy': [('objective', 2, True)],
    'find_retrieve': [('flag', 1, False), ('flag_stand', 2, True)],
    'hunters': [('nexus', 1, False)], 'team_hunters': [('nexus', 1, False)],
    'rabbit': [('flag', 1, False)],
    'siege': [('switch', 1, False)],
    'football': [('goal', 2, True)],
    'war': [('structure', 2, True)],
}


def write_json(path, obj, indent=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=indent)


def canon(names):
    out = []
    for n in names:
        c = CANON.get(n.strip().lower())
        if c and c not in out:
            out.append(c)
    return out


def objects_for(objects, mode):
    """The mode objects `mode` uses: those listed for it, or for every mode (empty "modes")."""
    return [o for o in objects if not o.get('modes') or mode in o['modes']]


def make_supported(declared, objects, notes):
    """`declared` engine ids kept when the map has the objects they need (REQUIRES)."""
    out = []
    for mode in declared:
        mine = objects_for(objects, mode)
        missing = [k for k, n, team in REQUIRES.get(mode, [])
                   if sum(1 for o in mine if o['kind'] == k and (not team or o.get('team', -1) >= 0)) < n]
        if missing:
            notes.append('mode %s left out: the map has too few %s' % (mode, '/'.join(missing)))
            continue
        out.append(mode)
    return out


def number_ids(objects):
    for i, o in enumerate(objects):
        o['id'] = i + 1
    return objects


def apply_to_map(m, original, declared, objects, settings):
    """Writes the mode fields into map dict `m` (and its notes)."""
    notes = []
    objects = number_ids(objects)
    m['original_modes'] = original
    m['modes'] = make_supported(declared, objects, notes)
    m['mode_objects'] = objects
    m['mode_settings'] = {k: v for k, v in settings.items() if k in m['modes']}
    if notes:
        m['notes'] = '; '.join([x for x in [m.get('notes', '')] + notes if x])
    return m


def index_fields(m):
    counts = {}
    for o in m.get('mode_objects', []):
        counts[o['kind']] = counts.get(o['kind'], 0) + 1
    return {'modes': m['modes'], 'mode_objects': counts}


# ============================================================================================== Tribes 2
T2_KINDS = {'flag': 'flag', 'exteriorflagstand': 'flag_stand', 'interiorflagstand': 'flag_stand',
            'flipflop': 'switch', 'nexus': 'nexus', 'generatorlarge': 'generator', 'solarpanel': 'generator'}
T2_LIMIT_FIELDS = {'ctf_scorelimit': 'ctf', 'cnh_scorelimit': 'capture_hold', 'rabbit_scorelimit': 'rabbit'}


def t2_mission_types(o):
    while o is not None:
        v = o['fields'].get('missiontypeslist')
        if v:
            return canon(v.split())
        o = o['parent']
    return []


def annotate_tribes2(m, header, root):
    """Mode fields of a Tribes 2 mission (export_tribes2_maps.parse_mission result)."""
    import export_tribes2_maps as T2
    original = [x for x in re.split(r'\s+', header.get('MissionTypes', '').strip()) if x]
    objects = []
    for o in T2.walk(root):
        if o['class'] not in ('StaticShape', 'Item'):
            continue
        db = (T2.field(o, 'dataBlock') or '').lower()
        score = float(T2.field(o, 'scoreValue', '0') or 0)
        kind = T2_KINDS.get(db) or ('objective' if score > 0 else None)
        if not kind:
            continue
        pl = T2.placement(o)[0]
        e = {'kind': kind, 'team': T2.team_of(o), 'pos': pl['pos'], 'yaw': pl.get('yaw', 0.0),
             'datablock': T2.field(o, 'dataBlock'), 'modes': t2_mission_types(o), 'name': o['name'] or ''}
        if score > 0:
            e['value'] = score
        if db == 'flag':
            e['shape'] = 'tribes2:flag'
        if kind == 'switch' and o['parent'] is not None:
            e['group'] = t2_group_positions(o['parent'], o, T2)
        objects.append(e)
    objects += t2_nexus_zones(root, T2)
    settings = {}
    for k, mode in T2_LIMIT_FIELDS.items():
        v = root['children'][0]['fields'].get(k) if root['children'] else None
        if v:
            settings.setdefault(mode, {})['score_limit'] = float(v)
    declared = canon(original)
    if 'defend_destroy' not in declared and sum(1 for o in objects if o['kind'] == 'objective') >= 2:
        declared.append('defend_destroy')
    apply_to_map(m, original, declared, objects, settings)
    m['ai_objectives'] = t2_ai_objectives(root, T2)
    return m


# StaticShape / Turret classes a claimed FlipFlop hands to its team (DefaultGame claimFlipflopResources: the
# switch's whole SimGroup changes team)
T2_GROUP_CLASSES = ('StaticShape', 'Turret')


def t2_group_positions(group, switch, T2):
    """Positions (engine) of the turrets / stations in the switch's SimGroup (they change team with it)."""
    out = []
    for o in T2.walk(group):
        if o is switch or o['class'] not in T2_GROUP_CLASSES:
            continue
        out.append(T2.placement(o)[0]['pos'])
    return out


def t2_nexus_zones(root, T2):
    """The Hunters camping trigger round the Nexus (Trigger dataBlock gameTrigger): a box. Its polyhedron spans
    the unit cube from the trigger's corner along +x, -y, +z, scaled (Torque frame)."""
    out = []
    for o in T2.walk(root):
        if o['class'] != 'Trigger' or (T2.field(o, 'dataBlock') or '').lower() != 'gametrigger':
            continue
        p = T2.vec(T2.field(o, 'position', '0 0 0')) or [0, 0, 0]
        sc = T2.vec(T2.field(o, 'scale', '1 1 1')) or [1, 1, 1]
        centre = [p[0] + sc[0] / 2.0, p[1] - sc[1] / 2.0, p[2] + sc[2] / 2.0]
        out.append({'kind': 'nexus_zone', 'team': -1, 'pos': T2.eng_pos(centre), 'yaw': 0.0,
                    'half_extents': [round(sc[0] / 2.0, 2), round(sc[2] / 2.0, 2), round(sc[1] / 2.0, 2)],
                    'modes': t2_mission_types(o), 'name': o['name'] or ''})
    return out


def t2_ai_objectives(root, T2):
    """The mission's AI objectives (Teams/team<N>/AIObjectives: AIObjective(<type>) markers): what the
    original bots do on this map, with their weights per bot assigned (weightLevel1..4)."""
    out = []
    for o in T2.walk(root):
        if o['class'] != 'AIObjective':
            continue
        f = lambda k, d='': T2.field(o, k, d)  # noqa: E731
        loc = T2.vec(f('location') or f('position', '0 0 0')) or [0, 0, 0]
        out.append({'type': o['name'] or '', 'mode': f('mode'), 'team': T2.team_of(o), 'pos': T2.eng_pos(loc),
                    'target': f('targetObject'), 'weights': [float(f('weightLevel%d' % i, '0') or 0) for i in range(1, 5)],
                    'offense': f('offense') == '1', 'defense': f('defense') == '1',
                    'modes': t2_mission_types(o), 'description': f('description')})
    return out


T2_GAME_FILES = {'CTFGame.cs': 'ctf', 'CnHGame.cs': 'capture_hold', 'DMGame.cs': 'deathmatch',
                 'DnDGame.cs': 'defend_destroy', 'HuntersGame.cs': 'hunters', 'TeamHuntersGame.cs': 'team_hunters',
                 'RabbitGame.cs': 'rabbit', 'BountyGame.cs': 'bounty', 'SiegeGame.cs': 'siege'}
# original game-variable name -> (engine rule key, scale)
T2_RULE_KEYS = {
    'SCORE_PER_KILL': ('score_per_kill', 1), 'SCORE_PER_SUICIDE': ('score_per_suicide', 1),
    'SCORE_PER_TEAMKILL': ('score_per_teamkill', 1), 'SCORE_PER_DEATH': ('score_per_death', 1),
    'SCORE_PER_PLYR_FLAG_CAP': ('score_per_player_flag_cap', 1), 'SCORE_PER_TEAM_FLAG_CAP': ('score_per_team_flag_cap', 1),
    'SCORE_PER_FLAG_RETURN': ('score_per_flag_return', 1), 'SCORE_PER_CARRIER_KILL': ('score_per_carrier_kill', 1),
    'SCORE_PER_GEN_DESTROY': ('score_per_objective', 1), 'FLAG_RETURN_DELAY': ('flag_return_s', 0.001),
    'SCORE_PER_PLYR_FLIPFLOP_CAP': ('score_per_capture', 1), 'SCORE_PER_TEAM_FLIPFLOP_CAP': ('team_capture_points', 1),
    'SCORE_PER_TEAM_FLIPFLOP_HOLD': ('hold_points', 1), 'TIME_REQ_TEAM_CAP_BONUS': ('capture_delay_s', 0.001),
    'TIME_REQ_TEAM_HOLD_BONUS': ('hold_interval_s', 0.001), 'SCORE_LIMIT_PER_TOWER': ('score_limit_per_switch', 1),
    'greedMinFlags': ('greed_min_flags', 1), 'flagLifeTimeMS': ('flag_life_s', 0.001),
    'flagReturnTime': ('flag_return_s', 0.001),
    'SCORE_PER_TARGETKILL': ('score_per_target_kill', 1), 'SCORE_PER_BYSTANDERKILL': ('score_per_bystander_kill', 1),
    'SCORE_PER_COMPLETION_BONUS': ('score_completion_bonus', 1), 'SIZE_STREAK_TO_AWARD': ('streak_size', 1),
    'SCORE_PER_FLAG_DEFEND': ('score_per_flag_defend', 1), 'RADIUS_FLAG_DEFENSE': ('defend_radius_m', 1),
    'SCORE_PER_GEN_DEFEND': ('score_per_gen_defend', 1), 'RADIUS_GEN_DEFENSE': ('gen_defend_radius_m', 1),
    'stalemateTimeMS': ('stalemate_s', 0.001), 'stalemateFreqMS': ('stalemate_every_s', 0.001),
    'stalemateDurationMS': ('stalemate_reveal_s', 0.001),
    'SCORE_PER_FLIPFLOP_DEFEND': ('score_per_switch_defend', 1), 'RADIUS_FLIPFLOP_DEFENSE': ('switch_defend_radius_m', 1),
    'HoardStartTime': ('hoard_start_min', 1), 'HoardDuration': ('hoard_duration_min', 1),
    'yardSaleMin': ('yard_sale_min', 1), 'nexusCampingTime': ('camping_s', 0.001), 'flagHoarderMin': ('hoarder_min', 1),
}
T2_RULE_KEYS_LOWER = {k.lower(): v for k, v in T2_RULE_KEYS.items()}
# server preferences the game types read ($Host::<name>, serverDefaults.cs)
T2_HOST_FLAGS = {'hunters': {'HuntersGreedMode': 'greed_mode', 'HuntersHoardMode': 'hoard_mode'},
                 'team_hunters': {'TeamHuntersGreedMode': 'greed_mode', 'TeamHuntersHoardMode': 'hoard_mode'}}


def eval_product(expr):
    """A script constant written as a product ("45 * 1000", "0.5 * 1000") -> number; None when it is not one."""
    try:
        value = 1.0
        for part in expr.split('*'):
            value *= float(part.strip())
        return value
    except ValueError:
        return None


def t2_rules(scripts_dir):
    """Rule values of each Tribes 2 game type from its script's game variables."""
    out = {}
    defaults = os.path.join(scripts_dir, 'serverDefaults.cs')
    host = open(defaults, encoding='latin-1').read() if os.path.exists(defaults) else ''
    time_limit = re.search(r'\$Host::TimeLimit\s*=\s*"?(\d+)', host)
    for fname, mode in T2_GAME_FILES.items():
        path = os.path.join(scripts_dir, fname)
        if not os.path.exists(path):
            continue
        text = open(path, encoding='latin-1').read()
        rules = {}
        for name, expr in re.findall(r'%game\.(\w+)\s*=\s*(-?[\d.]+(?:\s*\*\s*[\d.]+)*)\s*;', text):
            key = T2_RULE_KEYS_LOWER.get(name.lower())
            value = eval_product(expr)
            if key and value is not None:
                rules[key[0]] = round(value * key[1], 3)
        for host_key, rule_key in T2_HOST_FLAGS.get(mode, {}).items():
            flag = re.search(r'\$Host::%s\s*=\s*"?(\d+)' % host_key, host)
            if flag:
                rules[rule_key] = flag.group(1) != '0'
        limit = re.search(r'%scoreLimit\s*=\s*(\d+)\s*;', text)
        if limit:
            rules['score_limit'] = float(limit.group(1))
        if time_limit:
            rules['time_limit_s'] = float(time_limit.group(1)) * 60.0
        out[mode] = rules
    return out


# ============================================================================================== Tribes 1
T1_TYPES = {'capture the flag': 'ctf', 'capture and hold': 'capture_hold', 'defend and destroy': 'defend_destroy',
            'find and retrieve': 'find_retrieve', 'deathmatch': 'deathmatch', 'multiple team': 'multiple team'}


def t1_team(path):
    for a in path[::-1]:
        mt = re.match(r'team(\d+)$', a['name'], re.I)
        if mt:
            return int(mt.group(1))
    return -1


def t1_objects(root, mis):
    import export_darkstar_maps as DM
    objects = []
    for o, path in mis.walk(root):
        f = o['fields']
        db = (f.get('dataBlock') or '').lower()
        pos = mis.vec(f.get('position', '')) if f.get('position') else None
        if not pos or not db:
            continue
        team = t1_team(path)
        score = float(f.get('scoreValue') or 0)
        e = {'team': team, 'pos': DM.eng(pos), 'yaw': DM.orient(mis.vec(f.get('rotation', '0 0 0')))['yaw'],
             'datablock': f.get('dataBlock'), 'modes': []}
        if db == 'flag':
            e.update(kind='flag', shape='tribes:flag')
        elif db == 'flagstand':
            e.update(kind='flag_stand')
        elif db == 'towerswitch':
            delta = next((float(a['fields'].get('deltaTeamScore')) for a in path[::-1]
                          if a['fields'].get('deltaTeamScore')), 0.0)
            e.update(kind='switch', points_per_minute=delta, group=t1_group_positions(path, o, mis))
        elif score > 0 and o['class'] in ('StaticShape', 'Sensor', 'Turret'):
            e.update(kind='objective', name=(f.get('objectiveName') or '').strip())
        else:
            continue
        if score > 0:
            e['value'] = score
        objects.append(e)
    return objects


# classes a captured TowerSwitch hands to its team (objectives.cs: the tower group changes team)
T1_GROUP_CLASSES = ('StaticShape', 'Turret', 'Sensor')


def t1_group_positions(path, switch, mis):
    import export_darkstar_maps as DM
    if not path:
        return []
    out = []
    for o, _p in mis.walk(path[-1]):
        pos = o['fields'].get('position')
        if o is not switch and o['class'] in T1_GROUP_CLASSES and pos:
            out.append(DM.eng(mis.vec(pos)))
    return out


def annotate_tribes(m, mission_type, text, root):
    """Mode fields of a Tribes 1 mission: `mission_type` = the .dsc $MDESC::Type, `text` = the .mis script."""
    import darkstar_mis as mis
    objects = t1_objects(root, mis)
    kind = T1_TYPES.get(mission_type.lower(), 'deathmatch')
    team_flags = sum(1 for o in objects if o['kind'] == 'flag' and o['team'] >= 0)
    if kind == 'multiple team':   # the same rules with 3+ teams: CTF when the teams have flags, else C&H
        kind = 'ctf' if team_flags >= 2 else 'capture_hold'
    declared = [kind]
    for o in objects:
        if o['kind'] == 'switch' and kind in ('find_retrieve', 'defend_destroy'):
            o['modes'] = [kind]   # mixed objectives (FogOfWar, Siege): the switches score in this mode too
    settings = {}
    limit = re.search(r'\$teamScoreLimit\s*=\s*([\d.]+)', text, re.I)
    if limit:
        settings[kind] = {'score_limit': float(limit.group(1))}
    return apply_to_map(m, [mission_type] if mission_type else [], declared, objects, settings)


def t1_rules(scripts_dir):
    path = os.path.join(scripts_dir, 'objectives.cs')
    if not os.path.exists(path):
        return {}
    text = open(path, encoding='latin-1').read()
    ret = re.search(r'\$flagReturnTime\s*=\s*([\d.]+)', text)
    common = {'flag_return_s': float(ret.group(1))} if ret else {}
    defaults = os.path.join(scripts_dir, 'serverDefaults.cs')
    if os.path.exists(defaults):
        tl = re.search(r'\$Server::timeLimit\s*=\s*"?(\d+)', open(defaults, encoding='latin-1').read(), re.I)
        if tl:
            common['time_limit_s'] = float(tl.group(1)) * 60.0
    out = {mode: dict(common) for mode in ('ctf', 'capture_hold', 'defend_destroy', 'find_retrieve', 'deathmatch')}
    # objectives.cs: a TowerSwitch changes hands at once; the holders score deltaTeamScore per minute, paid every
    # 5 s (the score check interval, read from the script when it is there)
    tick = re.search(r'schedule\("ObjectiveMission::checkPoints\(\);",\s*([\d.]+)', text)
    out['capture_hold'].update(capture_delay_s=0.0, hold_interval_s=float(tick.group(1)) if tick else 5.0)
    out['ctf'].update(t1_bonus_rules(text, T1_FLAG_BONUSES))
    switch = t1_bonus_rules(text, T1_SWITCH_BONUSES)
    for mode in ('capture_hold', 'defend_destroy', 'find_retrieve'):
        out[mode].update(switch)
    return out


# Flag::clientKilled / TowerSwitch::clientKilled / timeLimitCheckPoints: a kill near your flag (victim), near your
# carrier (killer) or near your tower (killer) scores a point; a tower still held some time after its capture
# gives the capturer a bonus. rule key -> (pattern, value when found)
T1_FLAG_BONUSES = {
    'defend_radius_m': (r'getDistance\(%flagPos,\s*%playerPos\)\s*<\s*(\d+)', None),
    'escort_radius_m': (r'GameBase::getPosition\(%killer\)\)\s*<\s*(\d+)', None),
    'score_per_flag_defend': (r'bonus for defending the flag!', 1.0),
    'score_per_escort': (r'bonus for defending the flag carrier', 1.0),
}
T1_SWITCH_BONUSES = {
    'switch_defend_radius_m': (r'if\(%dist <= (\d+)\)', None),
    'score_per_switch_defend': (r'bonus for defending', 1.0),
    'hold_bonus_s': (r'timeLimitCheckPoints\(" @ .*?\);",\s*(\d+)\)', None),
    'score_per_hold_bonus': (r'function TowerSwitch::timeLimitCheckPoints[^}]*?%client\.score\s*\+=\s*(\d+)', None),
}


def t1_bonus_rules(text, table):
    out = {}
    for key, (pattern, value) in table.items():
        mt = re.search(pattern, text, re.S)
        if mt:
            out[key] = value if value is not None else float(mt.group(1))
    return out


# ============================================================================================== Starsiege
SS_COLOURS = ('red', 'blue', 'yellow', 'purple')
SS_PREFIX = {'ctf': ['ctf'], 'dm': ['deathmatch', 'team_deathmatch'], 'war': ['war'], 'starsiege': ['football']}
IDENTITY = struct.pack('<9f', 1, 0, 0, 0, 1, 0, 0, 0, 1)
SS_CTF_VARS = {'maxFlagCount': 'score_limit', 'flagValue': 'score_per_player_flag_cap',
               'carrierValue': 'score_per_carrier_kill', 'killPoints': 'score_per_kill',
               'deathPoints': 'score_per_death', 'flagTime': 'carrier_time_s'}
SS_FOOTBALL_VARS = {'PointInterval': 'score_per_goal', 'WinScore': 'score_limit', 'TouchDownValue': 'score_per_player_goal',
                    'BallCarrierKillValue': 'score_per_carrier_kill', 'MaxFouls': 'max_fouls', 'PenaltyTime': 'penalty_s'}
SS_DM_VARS = {'killPoints': 'score_per_kill', 'deathPoints': 'score_per_death'}
SS_WAR_VARS = {'BUILDINGS_TO_DESTROY': 'structures_to_win', 'respawnDelay': 'ai_respawn_s',
               'respawnDelayNoHq': 'ai_respawn_no_hq_s'}
SS_FOOTBALL_EXTRA = {'FumbleTakeUpsValue': 'score_per_fumble_takeup'}


def ss_football_extras(script, teams):
    """Starsiege_Football.cs: the fumble odds (vehicle::onAttacked: fumble(<n>), 1 in n per hit) and the penalty
    boxes (sendToPenaltyBox: randomTransport into a rectangle; the first for blue players, the second for red)."""
    if not os.path.exists(script):
        return {}
    text = open(script, encoding='latin-1').read()
    out = ss_script_vars(script, SS_FOOTBALL_EXTRA)
    odds = re.search(r'fumble\((\d+)\)\s*==', text)
    if odds:
        out['fumble_chance'] = round(1.0 / float(odds.group(1)), 6)
    body = re.search(r'function sendToPenaltyBox.*?\n}', text, re.S)
    rects = re.findall(r'randomTransport\(%vehicleId,\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+)\)',
                       body.group(0) if body else '')
    boxes = {}
    for colour, r in zip(('blue', 'red'), rects):
        team = next((t for t, c in teams.items() if c == colour), None)
        x0, y0, x1, y1 = (float(v) for v in r)
        if team is not None:   # Darkstar (x, y) -> engine (x, -y)
            boxes[team] = [min(x0, x1), -max(y0, y1), max(x0, x1), -min(y0, y1)]
    if boxes:
        out['penalty_boxes'] = boxes
    return out


def ss_war_defenders(script, mid, teams):
    """WAR base defenders: the mission's AI Hercs (<colour>Hercs/h<n>, starsiege_mis) and where the script
    re-drops each one (trevorsCloneVehicle("$<colour>Herc<n>", %this, x, y, z))."""
    import starsiege_mis as SM
    import export_starsiege_missions as E
    import export_darkstar_maps as DM
    text = open(script, encoding='latin-1').read() if os.path.exists(script) else ''
    drops = {(c.lower(), int(n)): (float(x), float(y), float(z)) for c, n, x, y, z in re.findall(
        r'trevorsCloneVehicle\(\\"\$(\w+?)Herc(\d)\\",\s*"\s*@\s*%this\s*@\s*",\s*(-?[\d.]+),\s*(-?[\d.]+),\s*(-?[\d.]+)\)', text)}
    lk = E.make_lookups(False)
    out = []
    root = SM.read_mis(os.path.join(os.path.dirname(script), mid + '.mis'))
    for path, n in SM.walk(root):
        if n.get('kind') != 'herc':
            continue
        mt = re.search(r'(\w+?)Hercs/h(\d)$', path)
        if not mt:
            continue
        colour, k = mt.group(1).lower(), int(mt.group(2))
        team = next((int(t) for t, c in teams.items() if c == colour), -1)
        drop = drops.get((colour, k))
        out.append({'kind': 'defender', 'team': team, 'pos': DM.eng(n['pos']), 'yaw': n.get('yaw', 0.0),
                    'vehicle': E._vehicle_fields(n, lk)['vehicle'], 'name': '%s defender %d' % (colour.capitalize(), k),
                    'respawn_pos': DM.eng(drop) if drop else DM.eng(n['pos']), 'modes': []})
    return out


def trigger_box(raw):
    """A Starsiege trigger record: identity rotation, then position and the box (min, max), metres."""
    k = raw.find(IDENTITY)
    if k < 0 or len(raw) < k + 36 + 36:
        return None
    vals = struct.unpack_from('<9f', raw, k + 36)
    return {'pos': vals[0:3], 'min': vals[3:6], 'max': vals[6:9]}


def ss_team_number(name, teams):
    """Engine team of a colour-named object (map.json "teams": {engine team: colour})."""
    low = name.lower()
    for t, colour in teams.items():
        if colour in low:
            return int(t)
    return -1


def ss_script_vars(path, names):
    if not os.path.exists(path):
        return {}
    text = open(path, encoding='latin-1').read()
    out = {}
    for name, key in names.items():
        mt = re.search(r'\$%s\s*=\s*(-?[\d.]+)\s*;' % re.escape(name), text, re.I)
        if mt:
            # the scripts subtract $deathPoints per death: stored as a negative score
            out[key] = -float(mt.group(1)) if key == 'score_per_death' else float(mt.group(1))
    return out


def ss_objects(root, mis, teams):
    import export_darkstar_maps as DM
    objects = []
    for o, path in mis.walk(root):
        name = o.get('name', '')
        f = o['fields']
        if o['class'] == 'trgr':
            box = trigger_box(f.get('_raw') or b'')
            low = name.lower()
            if not box or not (low.endswith('flagtrigger') or low.endswith('goal') or low.startswith('outofbounds')):
                continue
            kind = 'flag_stand' if low.endswith('flagtrigger') else 'goal' if low.endswith('goal') else 'out_of_bounds'
            half = [round((b - a) / 2.0, 2) for a, b in zip(box['min'], box['max'])]
            objects.append({'kind': kind, 'team': ss_team_number(name, teams), 'pos': DM.eng(box['pos']),
                            'yaw': 0.0, 'half_extents': [half[0], half[2], half[1]], 'name': name, 'modes': []})
        elif o['class'] == '0x100' and f.get('position'):
            raw = f.get('_raw') or b''
            mt = re.search(rb'((?:red|yellow|blue|purple)(?:Gen\d|HQ))', raw, re.I)
            low = (f.get('file') or '').lower()
            flag = re.match(r'team(\d)\.dts$', low)
            if flag:
                colour = SS_COLOURS[int(flag.group(1)) - 1]
                team = next((int(t) for t, c in teams.items() if c == colour), -1)
                objects.append({'kind': 'flag', 'team': team, 'pos': DM.eng(f['position']), 'yaw': 0.0,
                                'shape': 'starsiege:' + os.path.splitext(low)[0], 'name': name, 'modes': []})
            elif mt:
                label = mt.group(1).decode('ascii')
                objects.append({'kind': 'structure', 'team': ss_team_number(label, teams), 'pos': DM.eng(f['position']),
                                'yaw': 0.0, 'name': label, 'modes': []})
    return objects


def annotate_starsiege(m, mid, root, script_dir):
    """Mode fields of a Starsiege multiplayer map (binary .mis root, the folder of its .cs script)."""
    import darkstar_mis as mis
    teams = {str(k): v for k, v in (m.get('teams') or {}).items()}
    if not teams:   # the football map's teams come from its triggers, not its drop points
        teams = {'0': 'red', '1': 'blue'}
    objects = ss_objects(root, mis, teams)
    prefix = mid.split('_')[0].lower()
    declared = list(SS_PREFIX.get(prefix, ['deathmatch']))
    script = os.path.join(script_dir, mid + '.cs')
    settings = {}
    if prefix == 'ctf':
        # CTFstdLib: a flag lives on its stand or on a carrier's Herc, never on the ground (playerDropsFlag)
        settings['ctf'] = dict(ss_script_vars(script, SS_CTF_VARS), drop_returns_home=True)
    elif prefix == 'starsiege':
        settings['football'] = dict(ss_script_vars(script, SS_FOOTBALL_VARS), **ss_football_extras(script, teams))
    elif prefix == 'war':
        settings['war'] = ss_script_vars(script, SS_WAR_VARS)
        objects += ss_war_defenders(script, mid, teams)
    elif prefix == 'dm':
        dm = ss_script_vars(os.path.join(script_dir, 'DMstdLib.cs'), SS_DM_VARS)
        settings = {'deathmatch': dm, 'team_deathmatch': dict(dm)}
    original = {'ctf': 'CTF', 'dm': 'DM', 'war': 'WAR', 'starsiege': 'Football'}.get(prefix, prefix)
    return apply_to_map(m, [original], declared, objects, settings)


# ============================================================================================== main
def update_pack(pack, annotate_one, rules):
    idx_path = P.pack(pack, 'maps', '_index.json')
    if not os.path.exists(idx_path):
        print('%s: no maps/_index.json (export the maps first)' % pack)
        return 0
    index = json.load(open(idx_path, encoding='utf-8'))
    for e in index:
        path = P.pack(pack, 'maps', e['id'], 'map.json')
        if not os.path.exists(path):
            continue
        m = json.load(open(path, encoding='utf-8'))
        try:
            annotate_one(m)
        except FileNotFoundError as ex:
            print('  %s: source missing (%s)' % (e['id'], ex))
            continue
        write_json(path, m)
        e.update(index_fields(m))
        print('  %-28s %-45s %s' % (e['id'], ','.join(m['modes']), e['mode_objects']))
    write_json(idx_path, index, indent=1)
    write_json(P.pack(pack, 'gameplay', 'game_modes.json'), rules, indent=1)
    return len(index)


def run_tribes2():
    import export_tribes2_maps as T2
    mdir = P.work('tribes2', 'extracted', 'missions', 'missions')

    def one(m):
        header, root = T2.parse_mission(open(os.path.join(mdir, m['id'] + '.mis'), encoding='latin1').read())
        annotate_tribes2(m, header, root)
    return update_pack('tribes2', one, t2_rules(P.work('tribes2', 'extracted', 'scripts', 'scripts')))


def run_tribes():
    import darkstar_mis as mis
    mdir = P.work('tribes', 'original', 'Tribes', 'base', 'missions')
    files = {f.lower(): f for f in os.listdir(mdir)}

    def one(m):
        text = open(os.path.join(mdir, files[m['id'].lower() + '.mis']), encoding='latin-1').read()
        dsc = files.get(m['id'].lower() + '.dsc')
        mtype = ''
        if dsc:
            mt = re.search(r'\$MDESC::Type\s*=\s*"([^"]+)"', open(os.path.join(mdir, dsc), encoding='latin-1').read())
            mtype = mt.group(1) if mt else ''
        annotate_tribes(m, mtype, text, mis.parse_text(text))
    return update_pack('tribes', one, t1_rules(P.work('tribes', 'extracted', 'scripts')))


def run_starsiege():
    import darkstar_mis as mis
    mdir = P.work('starsiege', 'original', 'installed', 'multiplayer')

    def one(m):
        root = mis.parse_binary(open(os.path.join(mdir, m['id'] + '.mis'), 'rb').read())
        annotate_starsiege(m, m['id'], root, mdir)
    return update_pack('starsiege', one, {})


def main():
    wanted = [a for a in sys.argv[1:] if not a.startswith('--')] or ['tribes', 'tribes2', 'starsiege']
    runners = {'tribes': run_tribes, 'tribes2': run_tribes2, 'starsiege': run_starsiege}
    for pack in wanted:
        print(pack)
        runners[pack]()
    return 0


if __name__ == '__main__':
    sys.exit(main())
