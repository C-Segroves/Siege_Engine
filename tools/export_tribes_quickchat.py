"""Tribes (1998) chat menu -> the remake's quick-chat menu (game/engine/chat/quick_chat.gd).

The original player chat menu (scripts/chatmenu.cs, the "Root Menu" of PlayChatMenu) is built by
setPlayChatMenu(<hotkey><heading>) followed by entries:
  addPlayTeamChat(<hotkey><label>, <text>, <sound>)   said to the team
  addPlayChat(<hotkey><label>, <text>, <sound>)       said to everybody
  addPlayCMDResponse(<hotkey><label>, <action>, <text>, <sound>)   a command response, to the team
The first character of a heading or label is its menu hotkey. Animations (addPlayAnim) and local sounds
(addLocal) say nothing and are left out, as are headings left without a line.

Input  tribes/extracted/scripts/chatmenu.cs
Output gamedata/tribes/gameplay/quick_chat.json  {"pack", "engine_schema": 1, "source", "menu": [{name, hotkey,
       items: [{label, hotkey, text, team, sound}]}]}

Usage: python tools/export_tribes_quickchat.py
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

PACK = 'tribes'
SOURCE = 'scripts/chatmenu.cs (PlayChatMenu)'
HEADING = re.compile(r'^\s*setPlayChatMenu\(\s*"([^"]*)"\s*\)')
CALL = re.compile(r'^\s*(addPlayTeamChat|addPlayChat|addPlayCMDResponse)\((.*)\)\s*;')
ARG = re.compile(r'"([^"]*)"|([^,\s][^,]*)')
TEAM_CALLS = {'addPlayTeamChat', 'addPlayCMDResponse'}


def split_args(text):
    """The comma-separated arguments of a script call: quoted strings unquoted, bare words stripped."""
    return [m.group(1) if m.group(1) is not None else m.group(2).strip() for m in ARG.finditer(text)]


def make_item(call, args):
    if call == 'addPlayCMDResponse':
        label, text, sound = args[0], args[2], args[3] if len(args) > 3 else ''
    else:
        label, text, sound = args[0], args[1], args[2] if len(args) > 2 else ''
    return {'label': label[1:], 'hotkey': label[:1], 'text': text, 'team': call in TEAM_CALLS, 'sound': sound}


def parse_menu(script):
    """The chat menu's headings with their lines, in script order."""
    menu, current = [], None
    for line in script.splitlines():
        h = HEADING.match(line)
        if h:
            current = {'name': h.group(1)[1:], 'hotkey': h.group(1)[:1], 'items': []}
            menu.append(current)
            continue
        c = CALL.match(line)
        if c and current is not None:
            current['items'].append(make_item(c.group(1), split_args(c.group(2))))
    return [m for m in menu if m['items']]


def main():
    src = P.work('tribes', 'extracted', 'scripts', 'chatmenu.cs')
    with open(src, encoding='latin1') as f:
        menu = parse_menu(f.read())
    out = P.pack(PACK, 'gameplay', 'quick_chat.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump({'pack': PACK, 'engine_schema': 1, 'source': SOURCE, 'menu': menu}, f, indent=1)
    print('%s: %d chat menu headings, %d lines' % (PACK, len(menu), sum(len(m['items']) for m in menu)))


if __name__ == '__main__':
    main()
