"""Tribes: Vengeance mission scripts: the UnrealScript "Script" actors of a map -> maps/<id>/script.json.

A mission is a set of Script actors (docs/formats/tribes_vengeance.md "Mission scripts"). Each Script has a Label (its name for
targetScript), a MessageClass (the event that runs it: MessageLevelStart, MessageTriggerEnter, MessageDeath ...) with
TriggeredBy (labels or tags of the actors that raise it) and an Actions array: compact object references to Action* exports in
order. Properties (verified on the 29 SP maps):
  Actions / trueActions / elseActions / testsOr / loopActions / forActions   u8 compact count + compact refs (export index + 1)
  ActionIf   testsOr = BooleanStatement refs, ORed; the true and else lists nest further actions
  BooleanStatement   lhs, rhs strings; resolveInfoList holds one record per side that is a variable: 0x1a 0x16 <name> 0x19 0x16
                     <'lhs' | 'rhs'>, name like 'global.skiing01through'; lhs 'Get Message Value' etc. are engine calls;
                     the operator is equality (no operator property is stored); logicOp joins statements
  ActionObjectiveAdd   Description (an OBJ_ text key), objectiveName, ObjectiveActors (labels of TriggerRadius markers)
  ActionSpeak   SpeechTag = file name of the .ogg under Localisation/Maps/VO, Target = speaker actor label
  ActionNextCampaignMission / ActionFailCampaignMission   the mission's win and loss
Output (all positions metres in the engine frame):
  scripts   [{label, message, by: [labels], enabled, actions: [action]}]   action = {op, ...} (ops below)
  triggers  [{label, tag, pos, radius, height, max_enter, enabled}]
  actors    {label: [x, y, z]} positions of the labels the scripts name
  ActionAddGoal / ActionReplaceGoal / ActionRemoveGoal   Target = the AI actor, AISquad or spawn point label; goal = the name of an AI_*Goal
                     export (kind, destination / target / patrol-point names, Priority, movement area); goalName names the goal for
                     removal ("DefaultGuardGoal" is every soldier's guard-the-spawn goal)
Ops: goal speak wait obj_add obj_status obj_remove exec exit_script if loop exit_loop for var enable disable destroy spawn_on spawn_off
teleport damage prompt sound next fail countdown spawn_vehicle spawn_npc enter_vehicle noop(class)
  ActionSpawnRook with a Vehicle* SpawnClass  {op spawn_vehicle, class, label (rookLabel), team (teamLabel), at (locationByActor label)}
  ActionSpawnRook with an AI* SpawnClass  {op spawn_npc, class, label (rookLabel), team (teamLabel), at (locationByActor label), body (the
                     class's Mesh as a pack body), health (healthModifier), armor (armorClass)}
  ActionEnterVehicle  {op enter_vehicle, character, vehicle}   vehicle goals (AI_VehiclePatrolGoal ...): kinds vehicle_patrol (points, once,
                     target, speed), vehicle_move (dest, speed), vehicle_attack (target), vehicle_guard, enter_vehicle (vehicle, seat), expel (occupant)
"""
import re

import json
import os

import ue2_package as U
import tv_audio
import tv_skeletal

# The goals the engine acts on: the ground soldiers' and the crewed vehicles' (the turret, animation and ski goals are not converted).
GOAL_KINDS = {'AI_MoveToGoal': 'move', 'AI_SquadMoveToGoal': 'move', 'AI_GuardGoal': 'guard', 'AI_SquadGuardGoal': 'guard',
              'AI_WanderGoal': 'wander', 'AI_PatrolGoal': 'patrol', 'AI_AttackGoal': 'attack', 'AI_SquadAttackGoal': 'attack',
              'AI_FollowGoal': 'follow', 'AI_SquadFollowGoal': 'follow',
              'AI_VehiclePatrolGoal': 'vehicle_patrol', 'AI_VehicleMoveToGoal': 'vehicle_move', 'AI_VehicleAttackGoal': 'vehicle_attack',
              'AI_VehicleGuardGoal': 'vehicle_guard', 'AI_EnterVehicleGoal': 'enter_vehicle',
              'AI_VehicleExpellOccupantGoal': 'expel'}
VEHICLE_SPEED_UU = 'DesiredSpeed'          # uu/s of a vehicle goal
DEFAULT_PRIORITY = 50
SKIP_CLASSES = ('Script', 'Brush', 'StaticMeshActor', 'StaticMeshInstance', 'TerrainSector', 'Light', 'Polys', 'Model', 'ActorGroup',
                'Camera', 'SpriteEmitter', 'Projector', 'ZoneInfo', 'DynamicLight')


def _refs(raw):
    """Compact object references of an array property's raw bytes (count first)."""
    if not isinstance(raw, (bytes, bytearray)) or not raw:
        return []
    r = U.Reader(raw, 0)
    try:
        n = r.index()
        return [r.index() for _ in range(n)]
    except (IndexError, ValueError):
        return []


def _resolved_names(pkg, raw):
    """{'lhs': 'variable', 'rhs': ...} of a BooleanStatement's resolveInfoList."""
    out = {}
    if isinstance(raw, str):
        raw = raw.encode('latin-1', 'replace')
    for m in re.finditer(b'\x1a\x16', raw or b''):
        r = U.Reader(raw, m.end())
        try:
            var = r.index()
            if raw[r.p:r.p + 2] == b'\x19\x16':
                r.p += 2
                side = pkg.name(r.index())
                out[side] = pkg.name(var)
        except (IndexError, ValueError):
            continue
    return out


def var_name(s):
    s = str(s).strip().lower()
    return s[len('global.'):] if s.startswith('global.') else s


SOLDIER_PREFIXES = ('AI', 'ColiseumCaptain')
BODIES_FILE = os.path.join('gameplay', 'bodies.json')


def make_npc_info(classes, pack_dir):
    """The `npc_info` of compile_map: class name -> {body, health, armor} read from the UnrealScript class defaults (Mesh is the body the
    soldier wears, healthModifier scales his health, armorClass names his armour); None for a class the game does not have. `classes` is a
    ue2_classes.ClassIndex, `pack_dir` the pack that holds gameplay/bodies.json."""
    with open(os.path.join(pack_dir, BODIES_FILE), encoding='utf-8') as f:
        bodies = {b['id'] for b in json.load(f)['bodies']}

    def info(cls):
        if not classes.has(cls):
            return None
        d = classes.defaults(cls)
        body = 'tv_' + str(d.get('Mesh', '')).lower()
        return {'body': body if body in bodies else tv_skeletal.npc_body(cls), 'health': float(d.get('healthModifier', 1.0)),
                'armor': str(d.get('armorClass', ''))}
    return info


class Compiler:
    def __init__(self, pkg, to_world, texts, mpu, npc_info=None):
        self.pkg, self.to_world, self.texts, self.mpu = pkg, to_world, texts, mpu
        self.npc_info = npc_info
        self.labels = set()
        self.classes = {}
        self.depth = 0
        self.teams = None

    def props(self, e):
        return U.object_properties(self.pkg, e)

    def action_list(self, raw):
        out = []
        for ref in _refs(raw):
            if ref > 0 and ref <= len(self.pkg.exports):
                a = self.action(self.pkg.exports[ref - 1])
                if a is not None:
                    out.append(a)
        return out

    def label(self, name):
        if name and name != 'None':
            self.labels.add(str(name))
        return str(name) if name else ''

    def team_name(self, label):
        """The TeamInfo<Faction><n> export name of the team actor labelled `label` (a script says 'teambeagle'), else `label`."""
        if self.teams is None:
            self.teams = {str(self.props(e).get('Label', '')): e['name'] for e in self.pkg.exports
                          if self.pkg.class_name(e).startswith('TeamInfo')}
        return self.teams.get(str(label), str(label))

    def goal_export(self, name):
        for e in self.pkg.exports:
            if e['name'] == name and self.pkg.class_name(e) in GOAL_KINDS:
                return e
        return None

    def name_list(self, raw):
        """The names of a compact-index array property (patrolPointNames)."""
        return [self.pkg.name(i) for i in _refs(raw)]

    def goal(self, name):
        """{kind, name, priority, dest, target, center, radius, points} of the AI_*Goal export called `name` (None when the
        engine does not act on its kind). Names of actors are labels (recorded so their positions are exported)."""
        e = self.goal_export(name)
        if e is None:
            return None
        p = self.props(e)
        g = p.get
        kind = GOAL_KINDS[self.pkg.class_name(e)]
        out = {'kind': kind, 'name': str(g('goalName', '')), 'priority': int(g('Priority', DEFAULT_PRIORITY))}
        for key, field in (('destinationName', 'dest'), ('targetName', 'target'), ('movementAreaCenterName', 'center'),
                           ('attackTargetName', 'target'), ('vehicleOrTurretName', 'vehicle'), ('occupantName', 'occupant')):
            if g(key):
                out[field] = self.label(g(key))
        if kind == 'enter_vehicle':
            out['seat'] = int(g('VehiclePosition', 0) or 0)
        if kind.startswith('vehicle_') and g(VEHICLE_SPEED_UU):
            out['speed'] = round(float(g(VEHICLE_SPEED_UU)) * self.mpu, 2)
        if kind == 'guard':
            out['radius'] = round(float(g('movementAreaRadius', 0.0)) * self.mpu, 1)
        if kind == 'follow':
            out['radius'] = round(float(g('proximity', 0.0)) * self.mpu, 1)
        if kind in ('patrol', 'vehicle_patrol'):
            out['points'] = [self.label(n) for n in self.name_list(g('patrolPointNames'))]
            out['once'] = bool(g('bExecuteOnce', False))
        return out

    def spawn_npc(self, g):
        """ActionSpawnRook of a soldier class: the class's body, health modifier and armour (npc_info), else the body guessed from the name."""
        klass = str(g('SpawnClass', ''))
        info = (self.npc_info(klass) if self.npc_info else None) or {'body': tv_skeletal.npc_body(klass), 'health': 1.0, 'armor': ''}
        return {'op': 'spawn_npc', 'class': klass, 'label': str(g('rookLabel', '')), 'team': self.team_name(g('teamLabel', '')),
                'at': self.label(g('locationByActor', '')), 'body': info['body'], 'health': info['health'], 'armor': info['armor']}

    def test(self, e):
        p = self.props(e)
        resolved = _resolved_names(self.pkg, p.get('resolveInfoList'))
        sides = {}
        for side in ('lhs', 'rhs'):
            text = str(p.get(side, '')).strip()
            if side in resolved:
                sides[side] = {'var': var_name(resolved[side])}
            elif text.lower() in ('get message value', 'get object property', 'calculate distance', 'get armor type', 'get property'):
                sides[side] = {'call': text.lower()}
            else:
                sides[side] = {'lit': text}
        return {'lhs': sides['lhs'], 'rhs': sides['rhs'], 'and': int(p.get('logicOp', 0) or 0) == 0}

    def action(self, e):
        cls = self.pkg.class_name(e)
        p = self.props(e)
        g = p.get
        if cls == 'ActionSpeak':
            tag = str(g('SpeechTag', ''))
            return {'op': 'speak', 'tag': tag, 'target': self.label(g('Target', '')), 'text': self.texts.get(tag.lower(), ''),
                    'wait': bool(g('bWaitForSpeech', True))}
        if cls == 'ActionWait':
            return {'op': 'wait', 's': float(g('Seconds', 0.0))}
        if cls == 'ActionObjectiveAdd':
            markers = [str(v) for k, v in p.items() if k == 'ObjectiveActors' or k.startswith('ObjectiveActors[')]
            for m in markers:
                self.label(m)
            key = str(g('Description', '') or g('objectiveName', ''))
            return {'op': 'obj_add', 'name': str(g('objectiveName', key)), 'desc': key, 'text': self.texts.get(key.lower(), ''), 'markers': markers}
        if cls == 'ActionObjectiveSetStatus':
            return {'op': 'obj_status', 'name': str(g('objectiveName', '')), 'status': int(g('status', 0))}
        if cls in ('ActionObjectiveRemove', 'ActionObjectiveRemoveActor'):
            return {'op': 'obj_remove', 'name': str(g('objectiveName', '')), 'actor': str(g('actorLabel', ''))}
        if cls in ('ActionNonBlockingExecuteScript', 'ActionBlockingExecuteScript'):
            return {'op': 'exec', 'script': str(g('targetScript', '')), 'block': cls == 'ActionBlockingExecuteScript'}
        if cls == 'ActionExitScript':
            return {'op': 'exit_script', 'script': str(g('targetScript', ''))}
        if cls == 'ActionIf':
            return {'op': 'if', 'tests': [self.test(self.pkg.exports[r - 1]) for r in _refs(g('testsOr')) if 0 < r <= len(self.pkg.exports)],
                    'then': self.action_list(g('trueActions')), 'else': self.action_list(g('elseActions'))}
        if cls == 'ActionLoop':
            return {'op': 'loop', 'actions': self.action_list(g('loopActions'))}
        if cls == 'ActionExitLoop':
            return {'op': 'exit_loop'}
        if cls == 'ActionFor':
            return {'op': 'for', 'from': float(g('beginValue', 0.0)), 'to': float(g('endValue', 0.0)), 'actions': self.action_list(g('forActions'))}
        if cls in ('ActionVariableAssign', 'ActionVariableAssignIfNotExist', 'ActionVariableSubtract', 'ActionVariableMultiply',
                   'ActionVariableDivide', 'ActionVariableAdd'):
            kind = {'ActionVariableAssign': 'set', 'ActionVariableAssignIfNotExist': 'init', 'ActionVariableSubtract': 'sub',
                    'ActionVariableMultiply': 'mul', 'ActionVariableDivide': 'div', 'ActionVariableAdd': 'add'}[cls]
            return {'op': 'var', 'kind': kind, 'name': var_name(g('lhs', '')), 'value': str(g('rhs', ''))}
        if cls in ('ActionVariableIncrement', 'ActionVariableDecrement'):
            return {'op': 'var', 'kind': 'inc' if cls.endswith('Increment') else 'dec', 'name': var_name(g('Target', '')), 'value': '1'}
        if cls == 'ActionRandomNumber':
            return {'op': 'random', 'min': float(g('minimum', 0.0)), 'max': float(g('maximum', 1.0))}
        if cls in ('ActionEnableActor', 'ActionDisableActor', 'ActionDestroyActor', 'ActionKill'):
            op = {'ActionEnableActor': 'enable', 'ActionDisableActor': 'disable', 'ActionDestroyActor': 'destroy', 'ActionKill': 'destroy'}[cls]
            return {'op': op, 'target': self.label(g('Target', ''))}
        if cls in ('ActionEnableAISpawnPoint', 'ActionDisableAISpawnPoint'):
            return {'op': 'spawn_on' if cls == 'ActionEnableAISpawnPoint' else 'spawn_off', 'target': self.label(g('AISpawnPointLabel', ''))}
        if cls == 'ActionTeleport':
            return {'op': 'teleport', 'target': self.label(g('Target', '')), 'to': self.label(g('locationByActor', ''))}
        if cls == 'ActionDealDamage':
            return {'op': 'damage', 'target': self.label(g('Target', '')), 'amount': float(g('DamageAmount', 0.0))}
        if cls == 'ActionDisplayPrompt':
            key = str(g('textID', ''))
            return {'op': 'prompt', 'key': key, 'text': self.texts.get(key.lower(), '')}
        if cls == 'ActionPlaySound':
            stem = tv_audio.sound_import_name(self.pkg, p.refs.get('SoundToPlay', 0))
            return {'op': 'sound', 'stem': stem, 'at': self.label(g('actorLabel', '')), 'radius': float(g('Radius', 0.0)) * self.mpu}
        if cls in ('ActionAddGoal', 'ActionReplaceGoal', 'ActionRemoveGoal'):
            mode = {'ActionAddGoal': 'add', 'ActionReplaceGoal': 'replace', 'ActionRemoveGoal': 'remove'}[cls]
            goal = self.goal(str(g('goal', ''))) if mode != 'remove' else None
            if mode != 'remove' and goal is None:
                return None
            return {'op': 'goal', 'mode': mode, 'target': self.label(g('Target', '')), 'goal': goal,
                    'name': str(g('goalName', '') or g('nameOfGoalToReplace', ''))}
        if cls == 'ActionSpawnRook' and str(g('SpawnClass', '')).startswith('Vehicle'):
            return {'op': 'spawn_vehicle', 'class': str(g('SpawnClass', '')), 'label': str(g('rookLabel', '')),
                    'team': self.team_name(g('teamLabel', '')), 'at': self.label(g('locationByActor', ''))}
        if cls == 'ActionSpawnRook' and str(g('SpawnClass', '')).startswith(SOLDIER_PREFIXES):
            return self.spawn_npc(g)
        if cls == 'ActionEnterVehicle':
            return {'op': 'enter_vehicle', 'character': self.label(g('targetCharacter', '')), 'vehicle': self.label(g('targetVehicle', ''))}
        if cls == 'ActionNextCampaignMission':
            return {'op': 'next'}
        if cls == 'ActionFailCampaignMission':
            return {'op': 'fail'}
        if cls == 'ActionStartCountDown':
            return {'op': 'countdown', 's': float(g('Seconds', 0.0))}
        if cls == 'ActionStopCountDown':
            return {'op': 'countdown', 's': 0.0}
        return None


def _position(props, to_world):
    loc = U.vec3(props.get('Location', b''))
    return to_world(loc) if loc is not None else None


def compile_map(pkg, to_world, texts, mpu, npc_info=None):
    """The script.json dictionary of one map package (`npc_info`: make_npc_info)."""
    c = Compiler(pkg, to_world, texts, mpu, npc_info)
    scripts, triggers = [], []
    for e in pkg.find('Script'):
        p = c.props(e)
        refs = p.get('Actions')
        actions = c.action_list(refs)
        message = str(p.get('MessageClass', '') or '')
        by = [s.strip() for s in str(p.get('TriggeredBy', '')).split(',') if s.strip()] if p.get('TriggeredBy') else []
        scripts.append({'label': str(p.get('Label', e['name'])), 'name': e['name'], 'message': message, 'by': by,
                        'filter': str(p.get('messageFilter', '') or ''), 'enabled': bool(p.get('Enabled', True)), 'actions': actions})
    for e in pkg.find('TriggerRadius'):
        p = c.props(e)
        pos = _position(p, to_world)
        if pos is None:
            continue
        triggers.append({'label': str(p.get('Label', e['name'])), 'tag': str(p.get('Tag', '')), 'pos': pos,
                         'radius': round(float(p.get('CollisionRadius', 0.0)) * mpu, 2),
                         'height': round(float(p.get('CollisionHeight', 0.0)) * mpu, 2),
                         'max_enter': int(p.get('maxEnterCount', 0) or 0), 'enabled': bool(p.get('Enabled', True))})
    # positions of every labelled actor the scripts name (objective markers, teleport targets, sound sources)
    wanted = set(c.labels)
    actors = {}
    if wanted:
        for e in pkg.exports:
            if e['size'] < 16 or pkg.class_name(e) in SKIP_CLASSES:
                continue
            p = c.props(e)
            lab = p.get('Label')
            if lab in wanted and lab not in actors:
                pos = _position(p, to_world)
                if pos is not None:
                    actors[lab] = pos
    return {'scripts': scripts, 'triggers': triggers, 'actors': actors}
