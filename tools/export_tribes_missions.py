"""Tribes / Tribes 2 single-player missions -> gamedata/<pack>/missions/ (docs/formats/tribes.md section 8,
docs/formats/tribes2.md section 8). The mission scripts are copied from the user's disc as they are and run by
the remake's script runtime (game/games/tribes/); nothing of them is kept in the repository.

Usage: python tools/export_tribes_missions.py tribes|tribes2 [--no-maps]

tribes   the training missions base/missions/<n>_*.mis with their .dsc (briefing) and the Training_*.cs scripts
         they exec (scripts.vol), their maps (tools/export_darkstar_maps.py --training: maps/<id>/, left out of
         the arena index), and the datablock table of scripts/*.cs (`<Type>Data <name> { field = value; };`).
tribes2  Training1-5: missions/<id>.mis, scripts/Training<N>.cs, SinglePlayerGame.cs, spDialog.cs; the training
         voice (voice.vl2 audio/voice/Training/** -> audio/voice/training/**, IMA ADPCM decoded to PCM by
         wav_pcm); the datablock table (catalog_tribes2: every `datablock Class(Name) [: Parent]`, parents merged).
         The maps are the arena maps tools/export_tribes2_maps.py already writes (maps/Training<N>/).
Both write missions/_index.json: [{id, name, order, map, script, briefing, armor}] and missions/datablocks.json:
{lower name: {type, name, fields: {lower field: text}}}.
"""
import json
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

T1_MISSIONS = P.work('tribes', 'original', 'Tribes', 'base', 'missions')
T1_SCRIPTS = P.work('tribes', 'extracted', 'scripts')
T2_SRC = P.work('tribes2', 'extracted')
T2_MISSIONS = os.path.join(T2_SRC, 'missions', 'missions')
T2_SCRIPTS = os.path.join(T2_SRC, 'scripts', 'scripts')
T2_VOICE = os.path.join(T2_SRC, 'voice', 'audio', 'voice', 'Training')
# the single-player game scripts every Tribes 2 training mission runs on (SinglePlayerGame.cs execs spDialog.cs)
T2_GAME_SCRIPTS = ['SinglePlayerGame.cs', 'spdialog.cs']
T1_TRAINING = re.compile(r'^(\d)_(\w+)\.mis$', re.I)
T2_TRAINING = re.compile(r'^Training(\d)\.mis$', re.I)
DATABLOCK = re.compile(r'^\s*(\w+Data)\s+(\w+)\s*\{(.*?)\n\s*\};', re.S | re.M)
FIELD = re.compile(r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|[^;]+);')
EXEC = re.compile(r'^\s*exec\s*\(\s*"?([\w.]+?)(?:\.cs)?"?\s*\)\s*;', re.M | re.I)
MDESC_TEXT = re.compile(r'\$MDESC::Text\s*=(.*?);\s*$', re.S | re.M)
FONT_CODES = re.compile(r'<[^<>]{1,12}>')
T2_DISPLAY_NAME = re.compile(r'^//\s*DisplayName\s*=\s*(.+?)\s*$', re.M)
T2_VOICE_REF = re.compile(r'"voice/([\w./]+\.wav)"', re.I)
T2_BRIEFING = re.compile(r'//--- MISSION BRIEFING BEGIN ---\n(.*?)//--- MISSION BRIEFING END ---', re.S)
# the armour a training mission starts in (Tribes: Game::playerSpawn gives light armour; Tribes 2:
# SinglePlayerGame::equip sets it from the script, the runtime applies setArmor)
START_ARMOR = 'LIGHT'


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, indent=1, ensure_ascii=False)


def copy_text(src, dst):
    """Copies a script as UTF-8 (the originals are Latin-1)."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(src, encoding='latin-1') as f:
        text = f.read()
    with open(dst, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    return text


def find_file(folder, name):
    """`name` in `folder`, any letter case (None when missing)."""
    if not os.path.isdir(folder):
        return None
    for f in os.listdir(folder):
        if f.lower() == name.lower():
            return os.path.join(folder, f)
    return None


def unquote(v):
    v = v.strip()
    return v[1:-1] if len(v) >= 2 and v[0] == v[-1] == '"' else v


def words_of(mission_id):
    """'4_Commander_TargetLaser' -> 'Commander Target Laser'."""
    rest = mission_id.split('_', 1)[1] if '_' in mission_id else mission_id
    return re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', rest.replace('_', ' '))


# ------------------------------------------------------------------ Tribes

def t1_briefing(dsc_text):
    """The `$MDESC::Text = "..." @ "..."` concatenation as plain text (font codes dropped)."""
    m = MDESC_TEXT.search(dsc_text)
    if not m:
        return ''
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
    text = ''.join(p.replace('\\n', '\n').replace('\\"', '"') for p in parts)
    return FONT_CODES.sub('', text).strip()


def t1_datablocks():
    out = {}
    for f in sorted(os.listdir(T1_SCRIPTS)):
        if not f.lower().endswith('.cs'):
            continue
        with open(os.path.join(T1_SCRIPTS, f), encoding='latin-1') as fh:
            txt = fh.read()
        for m in DATABLOCK.finditer(txt):
            fields = {k.lower(): unquote(v) for k, v in FIELD.findall(m.group(3))}
            out[m.group(2).lower()] = {'type': m.group(1), 'name': m.group(2), 'fields': fields}
    return out


def export_tribes(with_maps):
    out = P.pack('tribes', 'missions')
    index = []
    for fn in sorted(os.listdir(T1_MISSIONS)):
        m = T1_TRAINING.match(fn)
        if not m:
            continue
        mid = fn[:-4]
        mis = copy_text(os.path.join(T1_MISSIONS, fn), os.path.join(out, mid + '.mis'))
        dsc = find_file(T1_MISSIONS, mid + '.dsc')
        briefing = t1_briefing(copy_text(dsc, os.path.join(out, mid + '.dsc'))) if dsc else ''
        scripts = []
        for name in EXEC.findall(mis):
            src = find_file(T1_SCRIPTS, name + '.cs')
            if src:
                text = copy_text(src, os.path.join(out, 'scripts', os.path.basename(src)))
                scripts.append('scripts/' + os.path.basename(src))
                scripts += ['scripts/' + os.path.basename(s) for s in _t1_execs(text, out)]
        index.append({'id': mid, 'name': words_of(mid), 'order': int(m.group(1)), 'map': 'tribes:' + mid,
                      'mission': mid + '.mis', 'scripts': list(dict.fromkeys(scripts)), 'briefing': briefing,
                      'armor': 'tribes:' + START_ARMOR})
        print('tribes training', mid, scripts)
    write_json(os.path.join(out, '_index.json'), index)
    write_json(os.path.join(out, 'datablocks.json'), t1_datablocks())
    if with_maps:
        import export_darkstar_maps as M
        old = sys.argv
        sys.argv = ['export_darkstar_maps.py', 'tribes', '--training', '--no-preview']
        try:
            M.main()
        finally:
            sys.argv = old
    return index


def _t1_execs(text, out):
    """The training helper scripts a training script execs itself (Training_AI.cs); base scripts such as game.cs
    are the engine's part in the remake and are not copied."""
    copied = []
    for name in EXEC.findall(text):
        if not name.lower().startswith('training'):
            continue
        src = find_file(T1_SCRIPTS, name + '.cs')
        if src:
            copy_text(src, os.path.join(out, 'scripts', os.path.basename(src)))
            copied.append(src)
    return copied


# ------------------------------------------------------------------ Tribes 2

def t2_datablocks():
    import catalog_tribes2 as C
    C.SCR = T2_SCRIPTS
    db = C.datablocks()
    out = {}
    for k, d in db.items():
        try:
            fields = C.resolved(db, k)
        except Exception:  # noqa: BLE001 - a parent cycle: keep the block's own fields
            fields = d.get('fields', {})
        out[k] = {'type': d.get('class', ''), 'name': d.get('name', k),
                  'fields': {str(f).lower(): str(v) for f, v in (fields or {}).items()}}
    return out


def t2_voice(out, scripts_text):
    """Every training voice clip as PCM: audio/voice/training/<folder>/<file>.wav, lower case; plus the other
    voice clips the training scripts name ("voice/derm2/gbl.woohoo.WAV" -> audio/voice/derm2/gbl.woohoo.wav)."""
    import wav_pcm
    voice_root = os.path.dirname(T2_VOICE)
    clips = set()
    for dp, _, files in os.walk(T2_VOICE):
        clips.update(os.path.relpath(os.path.join(dp, f), voice_root) for f in files if f.lower().endswith('.wav'))
    for rel in T2_VOICE_REF.findall(scripts_text):
        src = find_path(voice_root, rel)
        if src:
            clips.add(os.path.relpath(src, voice_root))
    for rel in sorted(clips):
        dst = os.path.join(out, 'audio', 'voice', *rel.lower().replace(os.sep, '/').split('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        wav_pcm.copy_as_pcm(os.path.join(voice_root, rel), dst)
    return len(clips)


def find_path(root, rel):
    """`rel` ("derm2/gbl.woohoo.WAV") under `root`, any letter case (None when missing)."""
    cur = root
    for part in rel.replace('\\', '/').split('/'):
        cur = find_file(cur, part)
        if not cur:
            return None
    return cur


def export_tribes2():
    pack = P.pack('tribes2')
    out = os.path.join(pack, 'missions')
    scripts_text = ''
    for name in T2_GAME_SCRIPTS:
        src = find_file(T2_SCRIPTS, name)
        if src:
            scripts_text += copy_text(src, os.path.join(out, 'scripts', os.path.basename(src)))
    index = []
    for fn in sorted(os.listdir(T2_MISSIONS)):
        m = T2_TRAINING.match(fn)
        if not m:
            continue
        mid = fn[:-4]
        mis = copy_text(os.path.join(T2_MISSIONS, fn), os.path.join(out, mid + '.mis'))
        scripts_text += mis
        script = find_file(T2_SCRIPTS, mid + '.cs')
        if script:
            scripts_text += copy_text(script, os.path.join(out, 'scripts', os.path.basename(script)))
        name = T2_DISPLAY_NAME.search(mis)
        brief = T2_BRIEFING.search(mis)
        briefing = '\n'.join(l[2:] if l.startswith('//') else l for l in brief.group(1).split('\n')).strip() if brief else ''
        scripts = ['scripts/' + os.path.basename(find_file(T2_SCRIPTS, s) or s) for s in T2_GAME_SCRIPTS]
        if script:
            scripts.append('scripts/' + os.path.basename(script))
        index.append({'id': mid, 'name': name.group(1) if name else mid, 'order': int(m.group(1)),
                      'map': 'tribes2:' + mid, 'mission': mid + '.mis', 'scripts': scripts, 'briefing': briefing,
                      'armor': 'tribes2:' + START_ARMOR})
        print('tribes2 training', mid, scripts)
    write_json(os.path.join(out, '_index.json'), index)
    write_json(os.path.join(out, 'datablocks.json'), t2_datablocks())
    print('training voice clips:', t2_voice(pack, scripts_text))
    return index


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args or args[0] not in ('tribes', 'tribes2'):
        print(__doc__)
        return 2
    if args[0] == 'tribes':
        index = export_tribes('--no-maps' not in sys.argv)
    else:
        index = export_tribes2()
    print('%s: %d training missions' % (args[0], len(index)))
    return 0 if index else 1


if __name__ == '__main__':
    sys.exit(main())
