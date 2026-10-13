"""Export Earthsiege missions as data for the Godot runtime mission compiler.

    python tools/export_missions.py [out_dir]      (default gamedata/es1/missions)

Writes the PARSED but UNEVALUATED mission scripts; the per-play compile step (conditions,
random picks, merges, id resolution) is done at runtime by
game/games/es1/mission/mission_compiler.gd, a port of tools/mission.py (Compiler, Rng,
eng_texts, mission_json).

  index.json          {"missions": [MSN names], "eng": [ENG names]}
  msn/<NAME>.json     parse_msn() output (cond, hdr, point, heading, path, area, region,
                      herc, flyer, struct, group; legacy files also fixed_header)
  eng/<NAME>.json     parse_eng() chunks (tag, segments with conditional switch blocks)
  campaign.json       battle sets / campaigns / slots / variants, any_*.dat lists, single
                      mission categories, progression tables
  tables.json         name and enum tables used by the resolver (MECHS.NAM, FLYERS.NAM, ...)
  zones.json          ZONE<n>.DAT terrain features in tools/mission.py read_zone() form
Structure (BASES.DAT) types have no names in the data; their raw records are in gameplay/bases.json.
"""
import glob, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import mission as M  # noqa: E402

import siege_paths as P  # noqa: E402
NAM_DIR = P.work('extracted', 'SIMVOL0', 'NAM')


def read_nam(name, fallback):
    p = os.path.join(NAM_DIR, name)
    if not os.path.exists(p):
        return list(fallback)
    d = open(p, 'rb').read()
    out = [s.decode('latin1') for s in d.split(b'\0') if s.strip(b'\r\n\x1a ')]
    return out


def _dump(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, separators=(',', ':'), ensure_ascii=False)


def _base(n):
    return os.path.splitext(n)[0].upper()


def campaign_json():
    info = M.campaign_info()
    files = M.parse_batlsets(open(os.path.join(M.BST_DIR, 'BATLSETS.BIN'), 'rb').read())
    return dict(
        battle_set_files=files,
        battle_sets=info['battle_sets'],
        any_lists=info['any_lists'],
        single_missions=info.get('single_missions', []),
        # [campaign] -> [next after success, next after failure]; -1 game over, 99 victory (GO 0x7ead0)
        next_campaign=[list(M.CAMPAIGN_NEXT[i]) for i in range(len(M.CAMPAIGN_NEXT))],
        campaign_kind=M.CAMPAIGN_KIND,
        campaign_terrain=M.CAMPAIGN_TERRAIN,
        # mission failed if debrief code (mission.var[0]) > threshold[mission type] (GO 0x7ec80)
        outcome_threshold=M.OUTCOME_THRESHOLD,
        game_over=-1, victory=99,
        notes='Slot variant 0 is played after a successful previous mission, 1 after a failure. '
              'A variant without ".MSN" names an any_*.dat list; one entry is picked at random.',
    )


def tables_json():
    herc = read_nam('MECHS.NAM', M.HERC_TYPES)
    flyer = read_nam('FLYERS.NAM', M.FLYER_TYPES)
    if len(herc) != len(M.HERC_TYPES) or len(flyer) != len(M.FLYER_TYPES):
        print('warning: NAM tables differ in size from tools/mission.py constants', herc, flyer)
    s = lambda d: {str(k): v for k, v in d.items()}
    return dict(
        # display names (as tools/mission.py) + the 8.3 resource names stored in MECHS.NAM / FLYERS.NAM
        herc_types=M.HERC_TYPES, flyer_types=M.FLYER_TYPES, herc_nam=herc, flyer_nam=flyer,
        terrain_names=M.TERRAIN_NAMES,
        cond_ops=s(M.COND_OPS), group_kinds=s(M.GROUP_KINDS), target_kinds=s(M.TARGET_KINDS),
        herc_orders=s(M.HERC_ORDERS), flyer_orders=s(M.FLYER_ORDERS), death_ops=s(M.DEATH_OPS),
        region_ops=s(M.REGION_OPS), region_types=s(M.REGION_TYPES), mission_types=s(M.MISSION_TYPES),
        campaign_terrain=M.CAMPAIGN_TERRAIN, default_options=M.DEFAULT_OPTIONS,
        structure_types_source='gameplay/bases.json (BASES.DAT, 9 records, no names)',
    )


def zones_json():
    nums = set()
    for d in M.ZONE_DIRS:
        for p in glob.glob(os.path.join(d, 'ZONE*.DAT')):
            m = re.match(r'ZONE(\d+)\.DAT$', os.path.basename(p).upper())
            if m:
                nums.add(int(m.group(1)))
    out = {}
    for n in sorted(nums):
        z = M.read_zone(n)
        if z is not None:
            out[str(n)] = z
    return out


def main(out=None):
    out = out or P.pack('es1', 'missions')
    os.makedirs(out, exist_ok=True)
    msns, engs = [], []
    for p in sorted(glob.glob(os.path.join(M.MSN_DIR, '*.MSN'))):
        n = _base(os.path.basename(p))
        try:
            raw = M.parse_msn(open(p, 'rb').read())
        except Exception as e:
            print('MSN %s failed: %r' % (n, e))
            continue
        _dump(os.path.join(out, 'msn', n + '.json'), raw)
        msns.append(n)
    for p in sorted(glob.glob(os.path.join(M.MSN_DIR, '*.ENG'))):
        n = _base(os.path.basename(p))
        try:
            ch = M.parse_eng(open(p, 'rb').read())
        except Exception as e:
            print('ENG %s failed: %r' % (n, e))
            continue
        _dump(os.path.join(out, 'eng', n + '.json'), ch)
        engs.append(n)
    _dump(os.path.join(out, 'index.json'), dict(missions=msns, eng=engs))
    _dump(os.path.join(out, 'campaign.json'), campaign_json())
    _dump(os.path.join(out, 'tables.json'), tables_json())
    _dump(os.path.join(out, 'zones.json'), zones_json())
    print('missions: %d MSN, %d ENG -> %s' % (len(msns), len(engs), out))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else None)
