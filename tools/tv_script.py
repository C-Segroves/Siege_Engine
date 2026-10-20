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
Ops: speak wait obj_add obj_status obj_remove exec exit_script if loop exit_loop for var enable disable destroy spawn_on spawn_off
teleport damage prompt sound next fail countdown noop(class)
"""
import re

import ue2_package as U
import tv_audio

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


class Compiler:
    def __init__(self, pkg, to_world, texts, mpu):
        self.pkg, self.to_world, self.texts, self.mpu = pkg, to_world, texts, mpu
        self.labels = set()
        self.classes = {}
        self.depth = 0

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


def compile_map(pkg, to_world, texts, mpu):
    """The script.json dictionary of one map package."""
    c = Compiler(pkg, to_world, texts, mpu)
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
