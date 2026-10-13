"""Starsiege squadmate orders and their spoken replies -> the engine catalog (docs/COMMAND_MAP.md section 3).

From the user's install:
  scripts/missionStdLib.cs addSquadmateOrders(): the squad order menu (addSquadOrder(IDSTR_SQORDER_<n>, "<function>()")),
        its labels from Sim.Strings.cs IDSTR_SQORDER_1..7, and each function's order(...) calls;
  scripts/DatPilot_hu.cs, DatPilot_cy.cs: every pilot's voice set (soundVolName sm_<set>.vol) and its 45 clip fields
        (CR1 .. DC1: the exe picks clips by slot, Starsiege.exe loader 0x54fb28);
  sm_<set>/ (the unpacked sm_*.vol): the clips.
Which clip answers which order is traced in Starsiege.exe (squawk calls in the order code, docs/COMMAND_MAP.md):
  Attack My Target AT (WT when the target is missing or friendly: refused), Join On Me FM, Defend My Target GD,
  Go To Nav Point GO, Hold Fire HF, Fire At Will FW, Halt! GN (Acknowledge); a squadmate called up answers CR.

Writes gamedata/starsiege/gameplay/squad_orders.json {menu: [{key, label, function, orders}], pilots: {lower pilot name:
voice set}, replies: [codes]} and the reply clips to audio/voice/squad/<set>/<code>.wav (Sfx "starsiege:squad/<set>/<code>").

Usage: python tools/export_starsiege_squad.py
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402
import wav_pcm  # noqa: E402

SCRIPTS = P.work('starsiege', 'extracted', 'scripts')
EXTRACTED = P.work('starsiege', 'extracted')
# The clips the order replies use (Starsiege.exe order code; the remaining 45-slot fields are combat chatter).
REPLIES = ('CR1', 'CR2', 'GN1', 'GN2', 'GN3', 'GN4', 'AT1', 'AT2', 'GD1', 'GD2', 'FM1', 'FM2', 'GO1', 'GO2', 'AW1',
           'HF1', 'FW1', 'FW2', 'WT1', 'WT2')


def read(path):
    with open(path, encoding='latin1') as f:
        return re.sub(r'//[^\n]*', '', f.read())


def squad_menu():
    """addSquadmateOrders(): [{key, label, function, orders: [[order name, value]]}] in menu order (key 1..)."""
    lib = read(os.path.join(SCRIPTS, 'missionStdLib.cs'))
    strings = read(os.path.join(SCRIPTS, 'Sim.Strings.cs'))
    body = re.search(r'function\s+addSquadmateOrders\s*\(.*?\n\}', lib, re.S | re.I).group(0)
    menu = []
    for sid, func in re.findall(r'addSquadOrder\(\s*\*?(IDSTR_SQORDER_\d+)\s*,\s*"(\w+)\(\)\s*;?\s*"\s*\)', body):
        label = re.search(r'%s\s*=\s*\d+\s*,\s*"([^"]*)"' % re.escape(sid), strings)
        fbody = re.search(r'function\s+%s\s*\(.*?\n\}' % re.escape(func), lib, re.S | re.I)
        orders = re.findall(r'order(?:SquadMate)?\([^,]+,\s*(\w+)\s*(?:,\s*([^)]*))?\)', fbody.group(0) if fbody else '')
        menu.append({'key': str(len(menu) + 1), 'label': label.group(1) if label else sid, 'function': func,
                     'orders': [[name, value.strip()] for name, value in orders]})
    return menu


def pilot_voices():
    """{pilot id: voice set} from the pilot records (Pilot pilotData<n> { id = <n>; ... soundVolName = "sm_<set>.vol"; })."""
    out = {}
    for name in ('DatPilot_hu.cs', 'DatPilot_cy.cs'):
        text = read(os.path.join(SCRIPTS, name))
        for rec in re.finditer(r'Pilot\s+\w+\s*\{(.*?)\n\s*\}', text, re.S):
            pid = re.search(r'\bid\s*=\s*(\d+)', rec.group(1))
            vol = re.search(r'soundVolName\s*=\s*"sm_(\w+)\.vol"', rec.group(1), re.I)
            if pid and vol:
                out[pid.group(1)] = vol.group(1).lower()
    return out


def copy_replies():
    sets = []
    for folder in sorted(glob.glob(os.path.join(EXTRACTED, 'sm_*'))):
        voice = os.path.basename(folder)[3:].lower()
        files = {os.path.basename(f).lower(): f for f in glob.glob(os.path.join(folder, '*'))}
        for code in REPLIES:
            src = files.get('sm_%s_%s.wav' % (voice, code.lower()))
            if src:
                out = P.pack('starsiege', 'audio', 'voice', 'squad', voice, code.lower() + '.wav')
                os.makedirs(os.path.dirname(out), exist_ok=True)
                wav_pcm.copy_as_pcm(src, out)
        sets.append(voice)
    return sets


def main():
    data = {'source': 'scripts/missionStdLib.cs addSquadmateOrders, Sim.Strings.cs IDSTR_SQORDER_*, DatPilot_*.cs; '
                      'replies traced in Starsiege.exe (docs/COMMAND_MAP.md)',
            'menu': squad_menu(), 'pilots': pilot_voices(), 'voice_sets': copy_replies(), 'replies': list(REPLIES)}
    out = P.pack('starsiege', 'gameplay', 'squad_orders.json')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1)
    print('starsiege squad: %d orders, %d pilots, %d voice sets' % (len(data['menu']), len(data['pilots']), len(data['voice_sets'])))
    return 0


if __name__ == '__main__':
    sys.exit(main())
