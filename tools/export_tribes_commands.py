"""Tribes (1998) and Tribes 2 (2001) commander orders -> base_equipment.json "commands" (docs/TRIBES_BASE_EQUIPMENT.md,
Command map). Read from the user's scripts by tools/export_tribes_base.py:
  Tribes 1  scripts/chatmenu.cs: the Command Menu's top-level orders (addCommand "aAttack", 1, "*Attack": hotkey a,
            label Attack) and the message Commander::StarCommand issues for each $CommandTarget ("enemy turret" ->
            "Destroy enemy turret at waypoint", "friendly player" -> "Cover <name>" ...);
  Tribes 2  scripts/commanderMap.cs: $CommandTask[<target type>, i, text / tag / hotkey / enemy], the commander map's
            context menu per target (Location, Player, Flag, Objective, Object) and side (enemy or own).
Both become menus by target: {"location" | "player_enemy" | "player_friend" | "object_enemy" | "object_friend" |
"flag_enemy" | "flag_friend" | "objective": [{key, label, task, message}]}; `task` is the Tribes 2 task tag (Tribes 1
orders are named the same way: AttackLocation, EscortPlayer ...), which the runtime maps to bot goals.
"""
import os
import re

import export_tribes_vehicles as V

# Tribes 1 $CommandTarget kinds -> menu, and the Tribes 2 task tag each order becomes there.
T1_TARGETS = {'waypoint': 'location', '*': 'location', 'enemy static': 'object_enemy', 'enemy turret': 'object_enemy',
              'enemy sensor': 'object_enemy', 'enemy player': 'player_enemy', 'enemy vehicle': 'player_enemy',
              'friendly player': 'player_friend', 'friendly vehicle': 'player_friend', 'friendly static': 'object_friend',
              'friendly turret': 'object_friend', 'friendly sensor': 'object_friend'}
T1_TASKS = {('attack', 'location'): 'AttackLocation', ('attack', 'object_enemy'): 'AttackObject',
            ('attack', 'player_enemy'): 'AttackPlayer', ('attack', 'player_friend'): 'EscortPlayer',
            ('defend', 'location'): 'DefendLocation', ('defend', 'player_friend'): 'EscortPlayer',
            ('defend', 'object_friend'): 'DefendObject', ('repair', 'location'): 'RepairObject',
            ('repair', 'player_friend'): 'RepairPlayer', ('repair', 'object_friend'): 'RepairObject'}
T2_TYPES = {'Location': ('location', 'location'), 'Player': ('player_friend', 'player_enemy'),
            'Flag': ('flag_friend', 'flag_enemy'), 'Objective': ('objective', 'objective'),
            'Object': ('object_friend', 'object_enemy')}


def _strip_colour(text):
    return re.sub(r'\\c\w', '', text)


def t1_commands():
    path = os.path.join(V.T1_SCRIPTS, 'chatmenu.cs')
    text = re.sub(r'//[^\n]*', '', open(path, encoding='latin1').read())
    body = re.search(r'function\s+Commander::StarCommand.*?\n\}', text, re.S).group(0)
    top = text.split('setCommanderChatMenu("eDeploy")')[0]
    menus = {}
    for label, _action, star in re.findall(r'addCommand\("(\w[^"]*)",\s*(\d+),\s*"\*(\w+)"\)', top):
        block = re.search(r'"\*%s"\)\s*\{(.*?)\n   \}' % star, body, re.S)
        targets = {}
        for cond, msg in re.findall(r'(?:if\s*\((.*?)\)\s*)?contextIssueCommand\(\d+,\s*"([^"]*)"',
                                    block.group(1) if block else ''):
            for k in re.findall(r'\$CommandTarget == "([^"]+)"', cond) or ['*']:
                targets.setdefault(k, msg.strip())
        if '*' in targets:          # the general order also applies to a waypoint and to own equipment
            for k in ('waypoint', 'friendly static'):
                targets.setdefault(k, targets['*'])
        for kind, msg in targets.items():
            menu = T1_TARGETS.get(kind)
            task = T1_TASKS.get((star.lower(), menu))
            entries = menus.setdefault(menu, []) if menu and task else None
            if entries is not None and not any(e['key'] == label[0] for e in entries):
                entries.append({'key': label[0], 'label': label[1:], 'task': task, 'message': msg})
    return {'source': 'scripts/chatmenu.cs Command Menu, Commander::StarCommand', 'menus': menus}


def t2_commands():
    path = os.path.join(V.T2_SCRIPTS, 'commanderMap.cs')
    text = open(path, encoding='latin1').read()
    rows = {}
    for kind, i, field, value in re.findall(
            r"\$CommandTask\['(\w+)',\s*(\d+),\s*(\w+)\]\s*=\s*(\"[^\"]*\"|'[^']*'|\w+)\s*;", text):
        rows.setdefault((kind, int(i)), {})[field] = value.strip('"\'')
    menus = {}
    for (kind, _i), r in sorted(rows.items()):
        if kind not in T2_TYPES or 'tag' not in r:
            continue
        enemy = r.get('enemy', 'false') == 'true'
        friend_menu, enemy_menu = T2_TYPES[kind]
        menu = enemy_menu if enemy else friend_menu
        label = _strip_colour(r.get('text', r['tag']))
        menus.setdefault(menu, []).append({'key': r.get('hotkey', label[:1].lower()), 'label': label, 'task': r['tag'],
                                           'message': label})
    return {'source': 'scripts/commanderMap.cs $CommandTask', 'menus': menus, 'reply_voices': copy_t2_replies(),
            'replies': {'ack': 'cmd.acknowledge', 'decline': 'cmd.decline', 'completed': 'cmd.completed'}}


# Tribes 2 order replies a unit speaks in its own voice (serverTasks.cs MsgTaskCompleted '~wvoice/<voice>/cmd.*.wav';
# aiHumanTasks.cs: a bot given a task by the commander map accepts it at once and the issuer hears cmd.acknowledge).
T2_REPLIES = ('cmd.acknowledge', 'cmd.decline', 'cmd.completed')


def copy_t2_replies():
    """Copies every voice's order replies to the pack's audio/voice/<voice>/ (Sfx names "tribes2:<voice>/cmd.*");
    returns the voices copied."""
    import glob
    import siege_paths as P
    import wav_pcm
    root = P.work('tribes2', 'extracted', 'voice', 'audio', 'voice')
    voices = []
    for folder in sorted(glob.glob(os.path.join(root, '*'))):
        voice = os.path.basename(folder).lower()
        for name in T2_REPLIES:
            src = next((f for f in glob.glob(os.path.join(folder, '*')) if os.path.basename(f).lower() == name + '.wav'), None)
            if src:
                out = P.pack('tribes2', 'audio', 'voice', voice, name + '.wav')
                os.makedirs(os.path.dirname(out), exist_ok=True)
                wav_pcm.copy_as_pcm(src, out)
                if voice not in voices:
                    voices.append(voice)
    return voices
