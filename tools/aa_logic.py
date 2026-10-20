"""Aerial Assault campaign mission logic, read from the PS2 executable (SLUS_201.49, MIPS R5900) -> campaign/logic.json.

The executable holds one class per campaign mission (cNN_logic for MISSION<NN>; MISSION09 and MISSION12 have none, like
the disc, and ctN_logic are the five trainings) derived from a game-mode class (game_logic = deathmatch, ctf_logic,
hunt_logic, cnh_logic) or from campaign_logic (the scripted missions). What this module reads automatically (aa_elf):
  * the objective list the mission shows (SetCampaignObjectives(n): OBJECTIVES.BIN string n),
  * the mission's base class and, for the arena missions 1..5, the score limit its AdvanceTime tests,
  * the object tags its RegisterItem handler recognises (GEN1, WAYPT1, TURRET3 ... the `#TAG "NAME"` lines of the
    disc's SOLO-MISSION.TXT) and the integers of its CNN_Data tuning table.
The SCRIPTS below are the state machines of the scripted missions, transcribed from the traces of those classes (AdvanceTime,
BeginGame and the per-state methods: GetReady / Travel / Siege, MovingIn / Infiltration, Transit / Bombardment, GettingReady /
Travel / Attack, Preparation / Fight / StayNearGens, MovingOut / Battle) and run by AAScriptVM (game/games/tribes_aa). Every number
of the originals that lives in the Data table is written "D<n>" and read from the executable at import time; the rest (voice
prompt ids, flags) are constants of the code. The trainings are in aa_training. Enemy waves are the DERM_<n>L_<n>M_<n>H_<n>W
tagged points of the map (bioderm soldiers; wave = W - 1, no W = wave 0: ParseTag) and BOT_ tags are allies
(campaign_logic::AddSpawnPoint / SpawnBots).
Voice prompts: GamePrompt / GameAudio / Failed / Success take an id of the audio container with tag 5 (TRAINING.PKG, bank number 5
in its header); sound index = (id & 0xFFFFFF) / 2 = the record number of the bank, exported as audio/training/NNN.ogg.

Script format (JSON): {"death": voice id of the player-died failure (none: a death does not end it), "initial": state, "states":
{"<n>": {"name", "text", "enter": [actions], "use": [shared groups], "timers": [{"name", "while": cond}], "rules": [{"when": cond,
"do": [actions]}]}}, "always": [rules], "shared": {name: {"timers", "rules"}}, "events": {event: [actions]}}.
Conditions: ["time", op, secs] (time in the state), ["timer", name, op, secs], ["counter", name, op, n], ["flag", f], ["not", c],
["and", ...], ["or", ...], ["enemies"|"allies", op, n] (living), ["near"|"far", tag, metres] (player), ["ally_far", m] (the
closest ally is farther than m from the player), ["enemy_near", tag, m], ["disabled", tag], ["became_disabled"|"became_enabled",
tag], ["destroyed", op, n] (turrets), ["deployed", op, n], ["switch"] (the player reached the control switch), ["boarded"] (the
vehicle pad was reached), ["voice_playing"], ["input", name, strength], ["count", name, op, n]. Actions: ["prompt", id] (queued),
["audio", id] (at once), ["fail", id], ["success", id], ["state", n], ["flag", f], ["unflag", f], ["spawn", "enemies"|"allies",
wave], ["order", "enemies"|"allies", task, target, slot], ["waypoint", tag], ["clear", tag], ["reset", timer|"time"],
["min_time", secs], ["add", counter, n], ["objective", text], ["objective_by", counter, [texts]], ["info"|"error", text],
["destroy", tag], ["give", item, n]. A rule fires every tick its condition holds, so one-shot rules guard themselves with a
flag; fail / success / state end the tick. Texts are numbers of the CAMPAIGN.BIN table ("texts" of logic.json).
"""
import re

import aa_training

MISSION_NUMBERS = ('01', '02', '03', '04', '05', '06', '07', '08', '10', '11', '13')
ARENA_MODES = {'game_logic': 'deathmatch', 'ctf_logic': 'ctf', 'hunt_logic': 'hunters', 'cnh_logic': 'cnh'}
# the arena score limit counts points; a kill is worth ARENA_POINTS_PER_KILL of them (assumption: the first mission's limit
# of 15 is a kill count, the others are scored in tens)
ARENA_POINTS_PER_KILL = {'01': 1}
ARENA_DEFAULT_POINTS = 40
ARENA_BOTS = 6

# ---------------------------------------------------------------------------------------------------------------------------
# State machines of the scripted missions (see the module doc for the format). "D<n>" = entry n of the mission's Data table.
# Order tasks (campaign_logic::OrderBots): 0 attack object, 1 and 3 roam to a position, 2 defend a position, 4 mortar an object,
# 5 repair an object, 6 destroy an object, 7 deathmatch, 8 antagonize (hunt the player).
# Prompts: 0x05000000 | sound index * 2 of the TRAINING bank.
P = 0x05000000

SCRIPTS = {
    # Onslaught: get a vehicle at the pad, drive to the waypointed base, hold it three waves.
    '06': {'death': P | 0xC8, 'initial': 1, 'states': {
        1: {'name': 'GetReady', 'text': 'Get a vehicle at the vehicle station',
            'enter': [['waypoint', 'VSTATION1'], ['prompt', P | 0xD4]],
            'timers': [{'name': 'far', 'while': ['far', 'VSTATION1', 'D4']}],
            'rules': [
                {'when': ['near', 'VSTATION1', 'D3'], 'do': [['clear', 'VSTATION1']]},
                {'when': ['timer', 'far', '>', 'D6'], 'do': [['fail', P | 0xDA]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['timer', 'far', '>', 'D5']], 'do': [['flag', 'hurry'], ['prompt', P | 0xCE]]},
                {'when': ['boarded'], 'do': [['clear', 'VSTATION1'], ['state', 2]]},
                {'when': ['time', '>', 'D1'], 'do': [['fail', P | 0xDA]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['time', '>', 'D0']], 'do': [['flag', 'hurry'], ['prompt', P | 0xCE]]}]},
        2: {'name': 'Travel', 'text': 'Travel to the waypointed base',
            'enter': [['waypoint', 'WAYPT1'], ['prompt', P | 0xCA]],
            'rules': [
                {'when': ['near', 'WAYPT1', 'D9'], 'do': [['clear', 'WAYPT1'], ['state', 3]]},
                {'when': ['time', '>', 'D8'], 'do': [['fail', P | 0xC8]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['time', '>', 'D7']], 'do': [['flag', 'hurry'], ['prompt', P | 0xE0]]}]},
        3: {'name': 'Siege', 'text': 'Defend the base against the BioDerm waves',
            'enter': [['waypoint', 'GEN1'], ['prompt', P | 0xCC]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'boost']], ['deployed', '>=', 2]], 'do': [['flag', 'boost'], ['min_time', 'D10']]},
                {'when': ['and', ['not', ['flag', 'w0']], ['time', '>', 'D10+D11']],
                 'do': [['flag', 'w0'], ['spawn', 'enemies', 0], ['order', 'enemies', 0, 'player', -1], ['prompt', P | 0xC6]]},
                {'when': ['and', ['flag', 'w0'], ['not', ['flag', 'w1']], ['enemies', '<=', 'D12']],
                 'do': [['flag', 'w1'], ['spawn', 'enemies', 1], ['order', 'enemies', 0, 'player', -1], ['prompt', P | 0xD2]]},
                {'when': ['and', ['flag', 'w1'], ['not', ['flag', 'w2']], ['enemies', '<=', 'D13']],
                 'do': [['flag', 'w2'], ['spawn', 'enemies', 2], ['order', 'enemies', 0, 'player', -1]]},
                {'when': ['and', ['flag', 'w2'], ['enemies', '==', 0]], 'do': [['success', P | 0xDC]]}]}}},

    # Dystopia: reach the first waypoint, then infiltrate with six heavy allies and clear the base.
    '07': {'death': P | 0x110, 'initial': 1, 'states': {
        1: {'name': 'MovingIn', 'text': 'Head to the enemy base',
            'enter': [['spawn', 'enemies', 0], ['spawn', 'enemies', 1], ['order', 'enemies', 3, 'WAYPT1', 0],
                      ['order', 'enemies', 8, None, 1], ['waypoint', 'WAYPT2'], ['prompt', P | 0xF0]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'p1']], ['time', '>', 'D1']], 'do': [['flag', 'p1'], ['prompt', P | 0xE4]]},
                {'when': ['near', 'WAYPT1', 'D0'], 'do': [['state', 2]]},
                {'when': ['time', '>', 'D3'], 'do': [['fail', P | 0xF4]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['time', '>', 'D2']], 'do': [['flag', 'hurry'], ['prompt', P | 0xEC]]}]},
        2: {'name': 'Infiltration', 'text': 'Destroy the generators and clear the base',
            'enter': [['spawn', 'allies', 0], ['order', 'allies', 7, None, -1], ['prompt', P | 0xE2]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'hurry']], ['not', ['and', ['disabled', 'GEN1'], ['disabled', 'GEN2']]],
                          ['far', 'WAYPT2', 'D4'], ['time', '>', 'D5']], 'do': [['flag', 'hurry'], ['prompt', P | 0xEA]]},
                {'when': ['and', ['not', ['flag', 'gens']], ['disabled', 'GEN1'], ['disabled', 'GEN2']],
                 'do': [['flag', 'gens'], ['prompt', P | 0x10C]]},
                {'when': ['allies', '<', 'D6'], 'do': [['fail', P | 0xF2]]},
                {'when': ['enemies', '==', 0], 'do': [['success', P | 0xF6]]}]}}},

    # Scorched Earth: march with the allies to the waypoint, then take the turrets' base and the switch.
    '08': {'death': P | 0x104, 'initial': 1, 'events': {'turret_destroyed': [['info', 153]]}, 'states': {
        1: {'name': 'Transit', 'text': 'Travel to the waypoint with the allies',
            'enter': [['flag', 'base'], ['spawn', 'enemies', 0], ['spawn', 'enemies', 1], ['order', 'enemies', 2, 'WAYPT2', 1],
                      ['order', 'enemies', 8, None, 0], ['spawn', 'allies', 0], ['order', 'allies', 8, None, -1],
                      ['waypoint', 'WAYPT1'], ['prompt', P | 0x10A]],
            'timers': [{'name': 'stray', 'while': ['ally_far', 'D2']}],
            'rules': [
                {'when': ['and', ['not', ['flag', 'go']], ['or', ['time', '>', 'D1'], ['far', 'INVEN1', 'D0']]],
                 'do': [['flag', 'go'], ['order', 'allies', 1, 'WAYPT1', -1], ['prompt', P | 0x10E]]},
                {'when': ['and', ['ally_far', 'D2'], ['not', ['flag', 's1']]],
                 'do': [['flag', 's1'], ['reset', 'stray'], ['prompt', P | 0x112]]},
                {'when': ['and', ['flag', 's1'], ['not', ['flag', 's2']], ['timer', 'stray', '>', 'D3']],
                 'do': [['flag', 's2'], ['reset', 'stray'], ['prompt', P | 0x102]]},
                {'when': ['and', ['flag', 's2'], ['timer', 'stray', '>', 'D3']], 'do': [['fail', P | 0x110]]},
                {'when': ['allies', '==', 0], 'do': [['fail', P | 0x110]]},
                {'when': ['near', 'WAYPT1', 'D4'], 'do': [['clear', 'WAYPT1'], ['state', 2]]}]},
        2: {'name': 'Bombardment', 'text': 'Take out the turrets, hit the control switch and kill all BioDerms',
            'enter': [['waypoint', 'TURRET1'], ['waypoint', 'TURRET2'], ['waypoint', 'TURRET3'], ['waypoint', 'TURRET4'],
                      ['waypoint', 'TURRET5'], ['prompt', P | 0x100]],
            'timers': [{'name': 'mortar', 'while': ['not', ['flag', 'noturrets']]}],
            'rules': [
                {'when': ['and', ['timer', 'mortar', '>', 'D6'], ['not', ['flag', 'noturrets']]],
                 'do': [['reset', 'mortar'], ['order', 'allies', 4, 'TURRETS', -1]]},
                {'when': ['and', ['not', ['flag', 'fall']], ['destroyed', '>', 0]],
                 'do': [['flag', 'fall'], ['order', 'enemies', 7, None, 1], ['prompt', P | 0x108]]},
                {'when': ['and', ['not', ['flag', 'noturrets']], ['destroyed', '>=', 5]],
                 'do': [['flag', 'noturrets'], ['order', 'allies', 7, None, -1]]},
                {'when': ['and', ['not', ['flag', 'late']], ['enemies', '>', 0], ['switch']], 'do': [['flag', 'late'], ['prompt', P | 0x10C]]},
                {'when': ['and', ['enemies', '==', 0], ['switch']], 'do': [['success', P | 0x114]]}]}}},

    # Death From Above: take the grav cycle from the vehicle station, ride to the waypoint, destroy the three turrets.
    '10': {'death': P | 0x110, 'initial': 1, 'events': {'turret_destroyed': [['info', 153]]}, 'states': {
        1: {'name': 'GettingReady', 'text': 'Get a vehicle at the vehicle station',
            'enter': [['spawn', 'enemies', 0], ['spawn', 'enemies', 1], ['spawn', 'enemies', 2], ['order', 'enemies', 3, 'WAYPT2', 0],
                      ['order', 'enemies', 8, None, 1], ['order', 'enemies', 8, None, 2], ['waypoint', 'INVEN1'],
                      ['waypoint', 'VSTATION1'], ['prompt', P | 0x12A]],
            'rules': [
                {'when': ['near', 'INVEN1', 'D0'], 'do': [['clear', 'INVEN1']]},
                {'when': ['near', 'VSTATION1', 'D1'], 'do': [['clear', 'VSTATION1']]},
                {'when': ['time', '>', 'D3'], 'do': [['fail', P | 0x130]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['time', '>', 'D2']], 'do': [['flag', 'hurry'], ['prompt', P | 0x120]]},
                {'when': ['boarded'], 'do': [['clear', 'INVEN1'], ['clear', 'VSTATION1'], ['state', 2]]}]},
        2: {'name': 'Travel', 'text': 'Travel to the waypoint',
            'enter': [['waypoint', 'WAYPT1'], ['prompt', P | 0x124]],
            'rules': [
                {'when': ['near', 'WAYPT1', 'D4'], 'do': [['clear', 'WAYPT1'], ['state', 3]]},
                {'when': ['time', '>', 'D6'], 'do': [['fail', P | 0x12C]]},
                {'when': ['and', ['not', ['flag', 'hurry']], ['time', '>', 'D5']], 'do': [['flag', 'hurry'], ['prompt', P | 0x134]]}]},
        3: {'name': 'Attack', 'text': 'Destroy the three turrets, hit the control switch and kill all BioDerms',
            'enter': [['flag', 'base'], ['order', 'enemies', 7, None, 0], ['waypoint', 'TURRET1'], ['waypoint', 'TURRET2'],
                      ['waypoint', 'TURRET3'], ['prompt', P | 0x12E]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'air']], ['time', '>', 'D7']], 'do': [['flag', 'air'], ['prompt', P | 0x128]]},
                {'when': ['and', ['not', ['flag', 'sw']], ['destroyed', '>=', 3], ['time', '>', 'D7+D9']],
                 'do': [['flag', 'sw'], ['waypoint', 'SWITCH1']]},
                {'when': ['and', ['not', ['flag', 'clear']], ['enemies', '==', 0], ['not', ['switch']]],
                 'do': [['flag', 'clear'], ['prompt', P | 0x15E]]},
                {'when': ['and', ['not', ['flag', 'late']], ['enemies', '>', 0], ['switch']], 'do': [['flag', 'late'], ['prompt', P | 0x10C]]},
                {'when': ['and', ['enemies', '==', 0], ['switch']], 'do': [['success', P | 0x132]]}]}}},

    # Gen Defender: defend the two generators; the allies guard, three BioDerm waves attack.
    '11': {'death': P | 0x144, 'initial': 1,
           'always': [{'when': ['and', ['disabled', 'GEN1'], ['disabled', 'GEN2']], 'do': [['fail', P | 0x142]]}],
           'shared': {'stay': {
               'timers': [{'name': 'stray', 'while': ['or', ['far', 'GEN1', 'D1'], ['far', 'GEN2', 'D1']]}],
               'rules': [
                   {'when': ['and', ['not', ['flag', 'w1']], ['timer', 'stray', '>', 'D2']], 'do': [['flag', 'w1'], ['reset', 'stray'], ['prompt', P | 0x14A]]},
                   {'when': ['and', ['flag', 'w1'], ['not', ['flag', 'w2']], ['timer', 'stray', '>', 'D2']],
                    'do': [['flag', 'w2'], ['reset', 'stray'], ['prompt', P | 0x150]]},
                   {'when': ['and', ['flag', 'w2'], ['timer', 'stray', '>', 'D2']], 'do': [['fail', P | 0x142]]}]}},
           'states': {
        1: {'name': 'Preparation', 'text': 'Prepare the defense of the generators', 'use': ['stay'],
            'enter': [['spawn', 'allies', 0], ['order', 'allies', 3, 'player', -1], ['prompt', P | 0x14C]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'e0']], ['time', '>', 'D5']],
                 'do': [['flag', 'e0'], ['spawn', 'enemies', 0], ['order', 'enemies', 6, 'GENS', -1], ['prompt', P | 0x13E]]},
                {'when': ['enemy_near', 'GEN1', 'D0'], 'do': [['state', 2]]}]},
        2: {'name': 'Fight', 'text': 'Defend the generators and kill the BioDerm intruders', 'use': ['stay'],
            'enter': [['prompt', P | 0x136]],
            'rules': [
                {'when': ['became_disabled', 'GEN1'], 'do': [['order', 'enemies', 6, 'GENS', -1]]},
                {'when': ['and', ['became_disabled', 'GEN1'], ['not', ['and', ['disabled', 'GEN1'], ['disabled', 'GEN2']]]],
                 'do': [['prompt', P | 0x146]]},
                {'when': ['became_disabled', 'GEN2'], 'do': [['order', 'enemies', 6, 'GENS', -1]]},
                {'when': ['and', ['became_disabled', 'GEN2'], ['not', ['and', ['disabled', 'GEN1'], ['disabled', 'GEN2']]]],
                 'do': [['prompt', P | 0x146]]},
                {'when': ['became_enabled', 'GEN1'], 'do': [['order', 'enemies', 6, 'GENS', -1], ['prompt', P | 0x148]]},
                {'when': ['became_enabled', 'GEN2'], 'do': [['order', 'enemies', 6, 'GENS', -1], ['prompt', P | 0x148]]},
                {'when': ['and', ['not', ['flag', 'c0']], ['not', ['flag', 'e1']], ['enemies', '<=', 'D3']],
                 'do': [['flag', 'c0'], ['prompt', P | 0x14E], ['reset', 'time']]},
                {'when': ['and', ['flag', 'c0'], ['not', ['flag', 'e1']], ['time', '>', 'D6']],
                 'do': [['flag', 'e1'], ['spawn', 'enemies', 1], ['order', 'enemies', 6, 'GENS', -1]]},
                {'when': ['and', ['flag', 'e1'], ['not', ['flag', 'c1']], ['enemies', '<=', 'D4']],
                 'do': [['flag', 'c1'], ['prompt', P | 0x140], ['reset', 'time']]},
                {'when': ['and', ['flag', 'c1'], ['not', ['flag', 'e2']], ['time', '>', 'D7']],
                 'do': [['flag', 'e2'], ['spawn', 'enemies', 2], ['order', 'enemies', 6, 'GENS', -1]]},
                {'when': ['and', ['flag', 'e2'], ['enemies', '==', 0]], 'do': [['success', P | 0x152]]}]}}},

    # Bastion: move out with the assault team to the first waypoint, then take the base.
    '13': {'death': P | 0x156, 'initial': 1, 'states': {
        1: {'name': 'MovingOut', 'text': 'Proceed to the enemy base with the assault team',
            'enter': [['waypoint', 'WAYPT1'], ['spawn', 'allies', 0], ['spawn', 'enemies', 0], ['order', 'allies', 1, 'WAYPT1', -1],
                      ['order', 'enemies', 8, None, -1], ['prompt', P | 0x160]],
            'timers': [{'name': 'away', 'while': ['and', ['allies', '>', 0], ['ally_far', 'D0']]}],
            'rules': [
                {'when': ['and', ['allies', '>', 0], ['ally_far', 'D0'], ['not', ['flag', 'w1']]],
                 'do': [['flag', 'w1'], ['reset', 'away'], ['prompt', P | 0x166]]},
                {'when': ['and', ['flag', 'w1'], ['not', ['flag', 'w2']], ['timer', 'away', '>', 'D1']],
                 'do': [['flag', 'w2'], ['reset', 'away'], ['prompt', P | 0x15C]]},
                {'when': ['and', ['flag', 'w2'], ['timer', 'away', '>', 'D1']], 'do': [['fail', P | 0x15A]]},
                {'when': ['near', 'WAYPT1', 'D2'], 'do': [['clear', 'WAYPT1'], ['state', 2]]}]},
        2: {'name': 'Battle', 'text': 'Get into the base, hit the control switch and kill all BioDerms',
            'enter': [['flag', 'base'], ['waypoint', 'SWITCH1'], ['order', 'enemies', 7, None, -1], ['order', 'allies', 7, None, -1],
                      ['prompt', P | 0x164]],
            'rules': [
                {'when': ['and', ['not', ['flag', 'clear']], ['enemies', '==', 0], ['not', ['switch']]],
                 'do': [['flag', 'clear'], ['order', 'allies', 3, 'WAYPT1', -1], ['prompt', P | 0x15E]]},
                {'when': ['and', ['not', ['flag', 'late']], ['enemies', '>', 0], ['switch']], 'do': [['flag', 'late'], ['prompt', P | 0x10C]]},
                {'when': ['and', ['enemies', '==', 0], ['switch']], 'do': [['success', P | 0x168]]}]}}},
}


def resolve(node, data):
    """Replaces the "D<n>" and "D<n>+D<m>" strings of a script by the numbers of the mission's Data table."""
    if isinstance(node, str):
        m = re.fullmatch(r'D(\d+)(?:\+D(\d+))?', node)
        if m:
            total = data[int(m.group(1))] + (data[int(m.group(2))] if m.group(2) else 0)
            return total
        return node
    if isinstance(node, list):
        return [resolve(x, data) for x in node]
    if isinstance(node, dict):
        return {k: resolve(v, data) for k, v in node.items()}
    return node


# the PS2 pad's button glyphs in the CAMPAIGN.BIN hints (U+0080 .. U+0083), written as the action they stand for in the lessons
GLYPHS = {'\x80': '[Grenade]', '\x81': '[Target]', '\x82': '[Pack]', '\x83': '[Weapon]'}


def pad_text(text):
    for g, name in GLYPHS.items():
        text = text.replace(g, name)
    return text


def class_facts(elf, num):
    """What the executable says about class c<num>_logic (see the module doc)."""
    import aa_elf                          # needs capstone: imported on use
    sym = '9c%s_logic' % num
    facts = {'class': 'c%s_logic' % num}
    names = [n for n in elf.symbols if n.endswith('__' + sym) or ('__' + sym) in n]
    begin = next((n for n in names if n.startswith('BeginGame__')), None)
    if begin:
        for line in aa_elf.trace(elf, begin):
            m = re.search(r'(?:TAIL)?CALL SetCampaignObjectives\w*\((\d+),', line)
            if m:
                facts['objectives'] = int(m.group(1))
            m = re.search(r'CALL BeginGame__(\d+)(\w+?)\(', line)
            if m and m.group(2) != 'c%s_logic' % num and not m.group(2).startswith('game_mgr'):
                facts['base'] = m.group(2)
            m = re.search(r'CALL SetVehicleLimits__\w+\(\w+, (\d+), (\d+|=\$zero), (\d+|=\$zero)\)', line)
            if m:
                facts['vehicle_limits'] = [int(x) if x.isdigit() else 0 for x in m.groups()]
    advance = next((n for n in names if n.startswith('AdvanceTime__')), None)
    if advance and facts.get('base') in ARENA_MODES:
        lim = [int(m.group(1), 16) for m in (re.search(r'slti \$v0, \$v0, (0x[0-9a-f]+)', l) for l in aa_elf.trace(elf, advance)) if m]
        if lim:
            facts['score_limit'] = lim[0]
    register = next((n for n in names if n.startswith('RegisterItem__')), None)
    if register:
        facts['tags'] = [m.group(1) for m in (re.search(r'x_strcmp\w*\([^,]*, "([^"]+)"', l) for l in aa_elf.trace(elf, register)) if m]
    data = elf.symbols.get('C%s_Data' % num)
    if data:
        facts['data'] = [elf.u32(data[0] + 4 * i) for i in range(data[1] // 4)]
    return facts


def extract(elf, objectives_table, campaign_table=None):
    """-> logic.json content: the numbered campaign missions (read from the executable), the five trainings (aa_training) and the
    CAMPAIGN.BIN strings the scripts show ("texts": {number: text}, the PS2 pad's button glyphs written out)."""
    out = {}
    for num in MISSION_NUMBERS:
        f = class_facts(elf, num)
        rec = {'class': f['class']}
        if 'objectives' in f:
            rec['objectives_index'] = f['objectives']
            if f['objectives'] < len(objectives_table):
                rec['objectives_text'] = objectives_table[f['objectives']]
        if f.get('base') in ARENA_MODES:
            rec['type'] = 'arena'
            rec['mode'] = ARENA_MODES[f['base']]
            rec['score_limit'] = f.get('score_limit', 0)
            rec['points_per_kill'] = ARENA_POINTS_PER_KILL.get(num, ARENA_DEFAULT_POINTS)
            rec['enemy_bots'] = ARENA_BOTS
        elif num in SCRIPTS and 'data' in f:
            rec['type'] = 'scripted'
            rec['script'] = resolve(SCRIPTS[num], f['data'])
        else:
            rec['type'] = 'fallback'
        rec['tags'] = f.get('tags', [])
        if 'data' in f:
            rec['data'] = f['data']
        if 'vehicle_limits' in f:
            rec['vehicle_limits'] = f['vehicle_limits']
        out['MISSION' + num] = rec
    for folder, script in aa_training.scripts().items():
        out[folder] = {'class': 'ct%s_logic' % folder[-1], 'type': 'training', 'script': script, 'tags': []}
    wanted = set()
    for rec in out.values():
        aa_training.texts_of(rec.get('script', {}), wanted)
    wanted.add(153)                                    # "Turret destroyed." (the missions' turret event)
    texts = {}
    for k in sorted(wanted):
        if campaign_table and k < len(campaign_table):
            texts[str(k)] = pad_text(campaign_table[k])
    return {'source': 'SLUS_201.49 campaign classes (tools/aa_logic.py)', 'texts': texts,
            'voice': {'bank': 'training', 'container_tag': 5, 'mask': 0xFFFFFF, 'index_shift': 1, 'file': 'audio/training/%03d.ogg'},
            'missions': out}


def read_elf(iso_path):
    import aa_elf
    import pycdlib
    iso = pycdlib.PyCdlib()
    iso.open(iso_path)
    try:
        import io
        buf = io.BytesIO()
        iso.get_file_from_iso_fp(buf, iso_path='/SLUS_201.49;1')
    finally:
        iso.close()
    return aa_elf.Elf(buf.getvalue())
