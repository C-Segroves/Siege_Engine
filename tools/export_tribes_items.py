"""Items lying in the Tribes / Tribes 2 maps (weapons, ammunition, packs, hand items, repair patches): what each item
datablock looks like and where the missions place them (docs/formats/tribes_infantry.md section 8).

Usage: python tools/export_tribes_items.py tribes|tribes2 [mission ...]      (importer step `items`, after `maps`)

Writes:
  gamedata/<pack>/gameplay/items.json   {"pack", "items": {datablock (lower case): {name, class, shape, radius,
                                         amount}}}: every ItemData with a model - name = T2 pickUpName / T1
                                         description, class = the script className (Weapon, Ammo, Pack / Backpack,
                                         HandInventory / HandAmmo, Repair ...), shape = the exported model,
                                         radius = T2 pickupRadius (T1: 2 m), amount = what one pickup gives
                                         (T2 weapons.cs $AmmoIncrement, else 1). The game resolves what an item
                                         gives (weapon, rounds, gear) with TribesItems, as the mission runtime does.
  gamedata/<pack>/maps/<id>/items.json  {"items": [{datablock, pos, yaw, team, count, rotate}]}: the mission's
                                         Item objects (engine frame, as map.json), flags left out (the game modes
                                         own them); count = the T1 mission Item's count (else 1).
Item models are exported through tools/export_tribes.py / export_tribes2.py like the maps' shapes.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

# Item datablocks the game modes own (flags) or that are no pickups.
SKIPPED_CLASSES = {'flag', 'armor'}
SKIPPED_ITEMS = {'flag'}
# Tribes 1 ItemData has no pickup radius (the engine's item box); the remake uses Tribes 2's common value.
T1_PICKUP_RADIUS = 2.0
T2_DEFAULT_RADIUS = 2.0


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f, separators=(',', ':'))


def is_item_block(name, fields):
    cls = str(fields.get('classname', '')).lower()
    return name not in SKIPPED_ITEMS and cls not in SKIPPED_CLASSES and bool(fields.get('shapefile'))


# ================================================================== Tribes 2

def t2_ammo_increments():
    """weapons.cs $AmmoIncrement[item] = n -> {item (lower): n}."""
    path = os.path.join(P.work('tribes2', 'extracted'), 'scripts', 'scripts', 'weapons.cs')
    if not os.path.exists(path):
        return {}
    txt = open(path, encoding='latin1').read()
    return {m.group(1).lower(): int(m.group(2)) for m in re.finditer(r'\$AmmoIncrement\[(\w+)\]\s*=\s*(\d+)', txt)}


def t2_item_blocks():
    """{datablock (lower): fields (lower-case keys, parents merged)} of every Tribes 2 ItemData."""
    import catalog_tribes2 as C
    import export_tribes2_maps as M
    C.SCR = os.path.join(M.SRC, 'scripts', 'scripts')
    db = C.datablocks()
    return {k: {fk.lower(): fv for fk, fv in C.resolved(db, k).items()} for k, v in db.items() if v.get('class') == 'ItemData'}


def t2_catalog():
    import export_tribes2_maps as M
    increments = t2_ammo_increments()
    items = {}
    for name, f in t2_item_blocks().items():
        if not is_item_block(name, f):
            continue
        shape = M.export_dts(f['shapefile'])
        if not shape:
            continue
        items[name] = {'name': f.get('pickupname', name), 'class': f.get('classname', ''), 'shape': shape,
                       'radius': float(f.get('pickupradius', T2_DEFAULT_RADIUS) or T2_DEFAULT_RADIUS),
                       'amount': increments.get(name, 1)}
    return items


def t2_map_items(mis_path, catalog):
    import export_tribes2_maps as M
    _, root = M.parse_mission(open(mis_path, encoding='latin1').read())
    out = []
    for o in M.walk(root):
        db = (M.field(o, 'dataBlock') or '').lower()
        if o['class'] != 'Item' or db not in catalog:
            continue
        pl = M.placement(o)[0]
        out.append({'datablock': db, 'pos': pl['pos'], 'yaw': pl.get('yaw', 0.0), 'team': M.team_of(o),
                    'count': int(float(M.field(o, 'count', '1') or 1)),
                    'rotate': (M.field(o, 'rotate', '0') or '0').lower() in ('1', 'true')})
    return out


def export_tribes2(missions):
    import export_tribes2_maps as M
    catalog = t2_catalog()
    write_json(P.pack('tribes2', 'gameplay', 'items.json'), {'pack': 'tribes2', 'items': catalog})
    mdir = os.path.join(M.SRC, 'missions', 'missions')
    return export_maps('tribes2', catalog, mdir, missions, t2_map_items)


# ================================================================== Tribes 1

def t1_context():
    import export_darkstar_maps as DM
    cfg = DM.GAMES['tribes']
    src = P.work(*cfg['extracted'])
    vfs = DM.VFS(src)
    return DM, {'mdir': P.work(*cfg['missions']), 'shapes': DM.ShapeExporter('tribes', vfs, src),
                'ppl_rel': ('lushWorld', 'lush.day.ppl')}


def t1_catalog(DM, ctx):
    import export_tribes_vehicles as V
    import export_tribes_infantry as I
    db = V.t1_datablocks()
    db.update({k: {'type': 'ItemData', 'fields': {fk.lower(): fv for fk, fv in v.items()}}
               for k, v in I.t1_items(db).items()})
    items = {}
    for name, rec in db.items():
        f = rec.get('fields', {})
        if rec.get('type') != 'ItemData' or not is_item_block(name, f):
            continue
        sid, _ = ctx['shapes'].dts(f['shapefile'], ctx['ppl_rel'])
        if not sid:
            continue
        items[name] = {'name': f.get('description', name), 'class': f.get('classname', ''), 'shape': 'tribes:' + sid,
                       'radius': T1_PICKUP_RADIUS, 'amount': 1}
    return items


def t1_map_items(mis_path, catalog):
    import darkstar_mis as MI
    import export_darkstar_maps as DM
    root = MI.parse_text(open(mis_path, encoding='latin-1').read())
    out = []
    for o, path in MI.walk(root):
        f = o['fields']
        db = f.get('dataBlock', '').lower()
        pos = MI.vec(f.get('position', '')) if 'position' in f else None
        if o['class'] != 'Item' or db not in catalog or not pos:
            continue
        team = -1
        for a in path:
            m = re.match(r'team(\d+)$', a['name'], re.I)
            if a['class'] == 'TeamGroup' and m:
                team = int(m.group(1))
        out.append({'datablock': db, 'pos': DM.eng(pos), 'yaw': DM.orient(MI.vec(f.get('rotation', '0 0 0')))['yaw'],
                    'team': team, 'count': int(float(f.get('count', '1') or 1)),
                    'rotate': str(f.get('rotate', 'false')).lower() in ('1', 'true')})
    return out


def export_tribes(missions):
    DM, ctx = t1_context()
    catalog = t1_catalog(DM, ctx)
    write_json(P.pack('tribes', 'gameplay', 'items.json'), {'pack': 'tribes', 'items': catalog})
    return export_maps('tribes', catalog, ctx['mdir'], missions, t1_map_items)


# ================================================================== both

def export_maps(pack, catalog, mdir, missions, read_items):
    """maps/<id>/items.json for every converted map whose mission is in `mdir` (or the `missions` named)."""
    if not os.path.isdir(mdir):
        print('%s: no missions folder %s' % (pack, mdir))
        return 1
    files = {os.path.splitext(f)[0].lower(): f for f in os.listdir(mdir) if f.lower().endswith('.mis')}
    maps_dir = P.pack(pack, 'maps')
    ids = [d for d in os.listdir(maps_dir) if os.path.isdir(os.path.join(maps_dir, d))] if os.path.isdir(maps_dir) else []
    want = {m.lower() for m in missions}
    total = 0
    for mid in sorted(ids):
        if (want and mid.lower() not in want) or mid.lower() not in files:
            continue
        items = read_items(os.path.join(mdir, files[mid.lower()]), catalog)
        write_json(os.path.join(maps_dir, mid, 'items.json'), {'items': items})
        total += len(items)
        if items:
            print('%-28s %d items' % (mid, len(items)))
    print('%s: %d item kinds, %d placed items' % (pack, len(catalog), total))
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ('tribes', 'tribes2'):
        print(__doc__)
        return 2
    return {'tribes': export_tribes, 'tribes2': export_tribes2}[args[0]](args[1:])


if __name__ == '__main__':
    sys.exit(main())
