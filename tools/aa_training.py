"""Aerial Assault training missions (ct1_logic .. ct5_logic of SLUS_201.49) as state machines for AAScriptVM (aa_logic.py module doc).

Each class is a list of lessons driven by one step variable: a step plays a voice line (GameAudio), and once it has finished shows
the lesson text (PrintObjective: CAMPAIGN.BIN string n), then waits for what the lesson asks (a stick or button of the PS2 pad,
a pickup, a shot, a deployed pack, a destroyed turret, a place) before the next step. Transcribed from the traces of the Mission /
Movement / HUDTraining / Weapons / Sniper / AutoLock / GravCycle ... methods; the sequence, the voice and text ids, the waypoints
and the final Success prompts are the executable's. What is approximated, because the remake has no such thing:
  * the pad: a stick / button lesson waits for the matching action of the remake's input map (AAMissionRuntime.vm_input);
  * the HUD glow of ct1's tour is not drawn (only its voice-over plays);
  * ct2 lets the trainee pick any weapon in any order and keeps the lessons per weapon; here the pads are visited in a fixed order
    (spinfusor, plasma rifle, cycle lesson, grenade launcher, exchange lesson, chaingun, blaster);
  * loadout lessons (ct4: which pack the inventory station must hand out) advance after a pause instead of checking the loadout;
  * the vehicle lessons (ct5) have no vehicles to ride: reaching the station stands for boarding and the stations for landing.
"""

P = 0x05000000
HUD_STEPS = 'hud'
SWITCH_METRES = 8.0
PICKUP_METRES = 4.0
LEARN_SECONDS = 15.0          # the stand-in for a loadout lesson


def _a(n):
    return P | n


def build(steps, success):
    """Linear lessons -> the machine's states. A step: audio (voice id), text (CAMPAIGN string shown after the voice), waypoints
    (tags shown while the step runs), give [(item, n)], destroy [tags], spawn [waves of enemies], wait (a condition), all [conditions
    that must each have been seen], touch [tags to reach, counted], texts_by_count [text ids by tags reached]."""
    states = {}
    count = len(steps)
    for i, st in enumerate(steps, 1):
        enter = []
        if st.get('audio'):
            enter.append(['audio', st['audio']])
        for tag in st.get('destroy', []):
            enter.append(['destroy', tag])
        for item, n in st.get('give', []):
            enter.append(['give', item, n])
        for tag in st.get('waypoints', []):
            enter.append(['waypoint', tag])
        for wave in st.get('spawn', []):
            enter.append(['spawn', 'enemies', wave])
        shown = [['flag', 'shown']]
        if 'text' in st:
            shown.append(['objective', st['text']])
        rules = []
        quiet = ['not', ['voice_playing']] if st.get('audio') else None
        rules.append({'when': ['and', ['not', ['flag', 'shown']], quiet] if quiet else ['not', ['flag', 'shown']], 'do': shown})
        waits = []
        if st.get('wait'):
            waits.append(st['wait'])
        for k, cond in enumerate(st.get('all', [])):
            rules.append({'when': ['and', ['flag', 'shown'], cond], 'do': [['flag', 'seen%d' % k]]})
            waits.append(['flag', 'seen%d' % k])
        if st.get('touch'):
            tags = st['touch']
            for k, tag in enumerate(tags):
                do = [['flag', 'hit%d' % k], ['clear', tag], ['add', 'touched', 1]]
                if st.get('texts_by_count'):
                    do.append(['objective_by', 'touched', st['texts_by_count']])
                rules.append({'when': ['and', ['flag', 'shown'], ['not', ['flag', 'hit%d' % k]], ['near', tag, SWITCH_METRES]], 'do': do})
            waits.append(['counter', 'touched', '>=', len(tags)])
        advance = [['clear', t] for t in st.get('waypoints', [])]
        if i < count:
            advance.append(['state', i + 1])
        else:
            advance.append(['success', success])
        when = ['and', ['flag', 'shown']] + waits
        rules.append({'when': when if len(when) > 2 else ['flag', 'shown'] if len(when) == 2 else when, 'do': advance})
        states[i] = {'name': st.get('name', 'Step%d' % i), 'enter': enter, 'rules': rules}
        if 'state_text' in st:
            states[i]['text'] = st['state_text']
    return {'initial': 1, 'states': states}


def _in(name, thr=0.0):
    return ['input', name, thr] if thr else ['input', name]


def _near(tag, m=PICKUP_METRES):
    return ['near', tag, m]


def training1():
    steps = [
        {'audio': _a(0x14), 'text': 0, 'wait': _in('look_up')},
        {'audio': _a(0x10), 'text': 1, 'wait': _in('look_down')},
        {'audio': _a(0x12), 'text': 2, 'all': [_in('look_left'), _in('look_right')]},
        {'audio': _a(0x1A), 'text': 3, 'wait': _in('move_forward')},
        {'audio': _a(0x18), 'text': 4, 'wait': _in('move_back')},
        {'audio': _a(0x1C), 'text': 5, 'all': [_in('strafe_left'), _in('strafe_right')]},
        {'audio': _a(0x0E), 'text': 6, 'wait': _in('jump')},
        {'audio': _a(0x0C), 'text': 7, 'wait': _in('jet', 0.5)},
        {'audio': _a(0x24), 'text': 8, 'waypoints': ['SWITCH1', 'SWITCH2', 'SWITCH3', 'SWITCH4', 'SWITCH5'],
         'touch': ['SWITCH1', 'SWITCH2', 'SWITCH3', 'SWITCH4', 'SWITCH5'], 'texts_by_count': [8, 9, 10, 11, 12]},
        # the HUD tour: the voice-over of the glowing parts (the glow itself is not drawn)
        {'audio': _a(0x08)}, {'audio': _a(0x00)}, {'audio': _a(0x02)}, {'audio': _a(0x20)}, {'audio': _a(0x0A)},
        {'audio': _a(0x1E)}, {'audio': _a(0x16)},
    ]
    return build(steps, _a(0x22))


def training2():
    weapons = [('SPINFUSOR', 0x2C, 24), ('PLASMARIFLE', 0x38, 25), ('GRENADELAUNCHER', 0x34, 26), ('CHAINGUN', 0x28, 27), ('BLASTER', 0x26, 28)]
    steps = [{'audio': _a(0x36)}]
    for k, (tag, voice, text) in enumerate(weapons):
        steps.append({'waypoints': [tag], 'text': 23, 'wait': _near(tag)})
        steps.append({'audio': _a(voice), 'text': text, 'wait': _in('fire')})
        if k == 1:
            steps.append({'audio': _a(0x2A), 'text': 30, 'wait': _in('weapon_next')})        # cycle to the next weapon
        if k == 2:
            steps.append({'audio': _a(0x30), 'text': 31, 'wait': _in('interact')})           # exchange the weapon held
    steps += [
        # sniper range: the energy pack and the laser rifle, the zoom, the training bot
        {'audio': _a(0x32), 'text': 32, 'waypoints': ['SNIPER', 'WAYPT1'], 'wait': _near('SNIPER')},
        {'audio': _a(0x3C), 'text': 33, 'wait': _in('scope_zoom')},
        {'audio': _a(0x3A), 'text': 29, 'spawn': [0], 'wait': ['enemies', '==', 0]},
        # target lock: a second training bot
        {'audio': _a(0x16A), 'text': 34, 'spawn': [0], 'wait': ['or', _in('target_next'), _in('target_nearest')]},
        {'audio': _a(0x16C), 'text': 35, 'wait': ['enemies', '==', 0]},
    ]
    return build(steps, _a(0x3E))


def training3():
    steps = [
        {'audio': _a(0x4E), 'text': 37, 'waypoints': ['PATCH', 'KIT'], 'give': [('repair_patch', 3), ('repair_kit', 3)],
         'touch': ['PATCH', 'KIT']},
        {'audio': _a(0x46), 'text': 38, 'give': [('grenade', 1)], 'wait': _in('grenade_throw')},
        {'audio': _a(0x44), 'text': 39, 'give': [('flare_grenade', 1)], 'wait': _in('grenade_throw')},
        {'audio': _a(0x42), 'text': 40, 'give': [('concussion_grenade', 1)], 'wait': _in('grenade_throw')},
        {'audio': _a(0x48), 'text': 41, 'give': [('mine', 1)], 'wait': _in('mine_drop')},
        {'audio': _a(0x4C), 'text': 42, 'waypoints': ['TURRET1', 'TURRET2', 'TURRET3', 'TURRET4', 'TURRET5'],
         'wait': ['destroyed', '>=', 2]},
        {'audio': _a(0x50), 'text': 43, 'wait': _in('weapon_next')},
        {'audio': _a(0x4A), 'text': 44, 'wait': ['destroyed', '>=', 5]},
    ]
    return build(steps, _a(0x40))


def training4():
    steps = [
        {'audio': _a(0x5A), 'text': 46, 'waypoints': ['WAYPT1'], 'destroy': ['INVEN'], 'wait': _near('WAYPT1')},
        {'audio': _a(0x60), 'text': 47, 'waypoints': ['INVEN'], 'wait': _near('INVEN', 15.0)},
        {'audio': _a(0x5C), 'text': 48, 'wait': ['not', ['disabled', 'INVEN']]},
        {'audio': _a(0x5E), 'text': 49, 'wait': _in('pack_use')},
        {'audio': _a(0x66), 'text': 51, 'wait': ['time', '>', LEARN_SECONDS]},
        {'audio': _a(0x54), 'text': 53, 'waypoints': ['WAYPT3'], 'wait': ['deployed', '>=', 1]},
        {'audio': _a(0x64), 'text': 54, 'wait': ['time', '>', LEARN_SECONDS]},
        {'audio': _a(0x62), 'text': 55, 'waypoints': ['TURRET'], 'wait': ['deployed', '>=', 2]},
        {'audio': _a(0x58), 'text': 56, 'wait': ['deployed', '>=', 3]},
        {'audio': _a(0x56), 'text': 59, 'wait': ['deployed', '>=', 4]},
        {'audio': _a(0x6A), 'text': 57, 'wait': ['or', ['deployed', '>=', 5], ['time', '>', 4 * LEARN_SECONDS]]},
        {'audio': _a(0x6C), 'text': 58, 'wait': _in('pack_use')},
    ]
    return build(steps, _a(0x52))


def training5():
    # (station tag, intro voice, text to board, text to ride, done voice, next station)
    lessons = [('GRAV', 0x72, 66, 67, 0x7C, 'TRANSPORT'), ('TRANSPORT', 0x78, 68, 69, 0x80, 'BOMBER'),
               ('BOMBER', 0x70, 70, 71, 0x7A, 'SCOUT'), ('SCOUT', 0x76, 72, 73, 0x7E, 'GRAV')]
    steps = [{'audio': _a(0x82)}]
    for tag, intro, board, ride, done, nxt in lessons:
        steps.append({'audio': _a(intro), 'text': board, 'waypoints': [tag], 'wait': _near(tag, 6.0)})
        steps.append({'audio': _a(0x74), 'text': 62, 'wait': ['time', '>', 6.0]})
        steps.append({'text': ride, 'waypoints': ['WAYPT1', 'WAYPT2', nxt], 'wait': _near(nxt, 12.0)})
        steps.append({'audio': _a(0x84), 'text': 65, 'wait': ['time', '>', 6.0]})
        steps.append({'audio': _a(done)})
    return build(steps, _a(0x6E))


TRAININGS = {'TRAINING1': training1, 'TRAINING2': training2, 'TRAINING3': training3, 'TRAINING4': training4, 'TRAINING5': training5}


def scripts():
    """{folder: script} of the five trainings."""
    return {k: f() for k, f in TRAININGS.items()}


def texts_of(node, out):
    """The CAMPAIGN string numbers a script (or part of one) shows: objective / objective_by / info / error actions."""
    if isinstance(node, dict):
        for v in node.values():
            texts_of(v, out)
    elif isinstance(node, list):
        if node and node[0] in ('objective', 'info', 'error') and len(node) > 1 and isinstance(node[1], int):
            out.add(node[1])
        elif node and node[0] == 'objective_by':
            out.update(node[2])
        else:
            for x in node:
                texts_of(x, out)
