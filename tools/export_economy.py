"""Campaign economy tables (salvage tonnage, Herc / weapon prices, repair costs, pilot roster) ->
<pack>/gameplay/economy.json for Earthsiege ("es1") and Earthsiege 2 ("es2").

    python tools/export_economy.py [es1|es2|all]

Format and evidence: docs/formats/campaign_availability.md section 7. All money is in kilograms of
salvage, as the originals keep it (the shells show it / 1000 as tons).

Earthsiege 1 (GO.EXE, flat image, file offset = VA + 0x48fd like tools/exe.py):
  0x808a8 s16[8] Herc tons, 0x808b8 s16[8] build price (tons), 0x808c8 s16[8] km/h,
  0x808d8 s16[8] build time (missions); new career pool 0xea60 kg (0x163ec);
  CFG/DAMAGE.DAT (loader 0x387ac): s16 factor, s16[6] armour part weights, s16[10] system weights,
  s16 weapon factor, s16[18] weapon repair costs (shell weapon order, hangar.json "tech_weapons");
  CAR/NAMES.DAT: u8 n, n x {u8 k, k NUL names} (pilot, replacement 1, replacement 2).
Earthsiege 2 (VSHELL.EXE, data files from SHELL0/GAM):
  HERC_INF.DAT (loader 0x41181c -> 0x483b54): s16 n, n x {type, tons, km/h, hardpoints, price
  (tons, 0x411019 build cost x1000), ?, build time (missions, 0x411086), available flag (unlock 0x4118c5)};
  DAMAGE.DAT (loader 0x413628): s16 factor, s16[6] armour, s16[9] systems, s16 weapon factor, s16 n,
  s16[n] weapon repair costs (WEAPONS.DAT order);
  WEAPONS.DAT (loader 0x411fc4): s16 n, n x {s16 id, s16 len, name, u16 price (tons, 0x411d57 x1000),
  u8 available (unlock 0x4126be), s16 shelf}, then s16 k, k x {s16 weapon, s16 condition, s16 missile}
  = the campaign's starting weapon inventory;
  SIMVOL0/STR/PILOTS.STR: 12 pilots x 3 names (pilot, replacement 1, replacement 2).
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import siege_paths as P  # noqa: E402

GO_FILE_DELTA = 0x48fd                 # tools/exe.py IMAGES['GO']
ES1_HERC_TABLES = {"tons": 0x808a8, "price_tons": 0x808b8, "kmh": 0x808c8, "build_missions": 0x808d8}
ES1_HERC_UNITS = ["ROADRUNN", "GUNSLING", "RAPTOR", "TOMAHAWK", "PATRIOT", "PANTHER", "HERCULES", "COLOSSUS"]
ES1_START_POOL_KG = 0xea60             # GO.EXE 0x163ec: new career salvage
# GO.EXE / CFG weapon order (hangar.json "tech_weapons") + the empty slot
ES1_WEAPONS = ["ATC20", "ATC35", "ATC50", "ELF", "EMP", "GREN", "LAS100", "LAS200", "LAS300", "MLRS6", "MLRS8",
               "MLRS10", "PBEAM", "ECM", "EMP_CYBRID", "PBEAM_CYBRID", "MISSL_CYBRID", ""]
ES2_HERC_UNITS = ["OUTLAW", "RAPTOR2", "TOMAHAWK", "SAMSON", "COLOSSUS", "APOCA", "OGRE", "MAVERICK", "RAZOR"]
# WEAPONS.DAT record -> engine weapon name (game/games/es1/mission/es2_unit_catalog.gd WEAPON_NAMES)
ES2_WEAPONS = ["", "ATC20", "ATC35", "ATC50", "ATC75", "ATC100", "ELF", "EMP", "LAS100", "LAS200",
               "LAS300", "LAS400", "LAS500", "MSL6", "MSL8", "MSL10", "FLYMSL", "PBEAM", "ECM", "EMP_BULL", "PBEAM_BULL",
               "MISSL_BULL", "ELF2", "EMP2", "PBW2", "PLAS", "LAEW", "MINE", "MAGN", "TARG", "SHIELD", "TURBO", "ENERGY"]
ES2_START_POOL = {"base_kg": 100000, "random_steps": 11, "step_kg": 1000}   # VSHELL 0x40e2ed
# VSHELL 0x46f8a4: the 13 armour components (DMG index) grouped into the 6 repair parts
ARMOUR_PARTS = [[0, 1], [2, 4], [3, 5], [6], [7, 9, 11], [8, 10, 12]]
# VSHELL 0x46fd78 / 0x46fd84: damage levels (repair targets) and their lower bounds, percent
REPAIR_LEVELS = [100, 90, 80, 60, 30, 1]
WRITE_OFF_PERCENT = 29                 # VSHELL 0x410cbd: a Herc at <= 29 % is written off for scrap
SQUAD_MAX = 3                          # VSHELL squad.h asserts (wingman index < 3); ES1 HDD: 3 wingman windows
TONS_KG = 1000


def _words(b, n, off=0):
    return list(struct.unpack_from('<%dh' % n, b, off))


def _repair(factor, armour, systems, weapon_factor, weapon_costs):
    return {"factor": factor, "armour_parts": ARMOUR_PARTS, "armour_weights": armour,
            "system_weights": systems, "weapon_factor": weapon_factor, "weapon_costs": weapon_costs,
            "levels": REPAIR_LEVELS, "write_off_percent": WRITE_OFF_PERCENT}


# ---------------------------------------------------------------------------------------------- es1

def es1():
    go = open(P.work('original', 'GO.EXE'), 'rb').read()
    tables = {k: _words(go, 8, va + GO_FILE_DELTA) for k, va in ES1_HERC_TABLES.items()}
    hercs = {}
    for i, unit in enumerate(ES1_HERC_UNITS):
        hercs['es1:%s' % unit] = {"price_kg": tables['price_tons'][i] * TONS_KG,
                                  "build_missions": tables['build_missions'][i], "tons": tables['tons'][i]}
    w = _words(open(P.work('extracted', 'SHELL0', 'CFG', 'DAMAGE.DAT'), 'rb').read(), 36)
    weapon_costs = {'es1:%s' % n: c for n, c in zip(ES1_WEAPONS, w[18:36]) if n and c > 0}
    return {"pack": "es1", "source": "GO.EXE 0x808a8..0x808e8, CFG/DAMAGE.DAT, CAR/NAMES.DAT (tools/export_economy.py)",
            "start_pool": {"base_kg": ES1_START_POOL_KG, "random_steps": 0, "step_kg": 0},
            "hercs": hercs, "repair": _repair(w[0], w[1:7], w[7:16], w[17], weapon_costs),
            "weapons": {}, "start_weapons": [], "pilots": _es1_names(), "squad_max": SQUAD_MAX}


def _es1_names():
    d = open(P.work('extracted', 'SHELL0', 'CAR', 'NAMES.DAT'), 'rb').read()
    p = 1
    out = []
    for _ in range(d[0]):
        k = d[p]
        p += 1
        names = []
        for _ in range(k):
            e = d.index(b'\0', p)
            names.append(d[p:e].decode('latin-1'))
            p = e + 1
        out.append(names)
    return out


# ---------------------------------------------------------------------------------------------- es2

def _gam(name):
    return open(P.work('es2', 'extracted', 'SHELL0', 'GAM', name), 'rb').read()


def es2():
    weapons, start_weapons = _es2_weapons()
    return {"pack": "es2", "source": "SHELL0/GAM HERC_INF.DAT, DAMAGE.DAT, WEAPONS.DAT, PILOTS.STR (tools/export_economy.py)",
            "start_pool": ES2_START_POOL, "hercs": _es2_hercs(), "repair": _es2_repair(),
            "weapons": weapons, "start_weapons": start_weapons, "pilots": _es2_names(), "squad_max": SQUAD_MAX}


def _es2_hercs():
    d = _gam('HERC_INF.DAT')
    n = struct.unpack_from('<h', d, 0)[0]
    out = {}
    for i in range(n):
        typ, tons, kmh, hardpoints, price, _u, build, available = _words(d, 8, 2 + i * 16)
        out['es2:%s' % ES2_HERC_UNITS[typ]] = {"price_kg": price * TONS_KG, "build_missions": build, "tons": tons,
                                                "available": bool(available)}
    return out


def _es2_repair():
    w = _words(_gam('DAMAGE.DAT'), 51)
    n = w[17]
    costs = {'es2:%s' % ES2_WEAPONS[i]: c for i, c in enumerate(w[18:18 + n]) if ES2_WEAPONS[i] and c > 0}
    return _repair(w[0], w[1:7], w[7:16], w[16], costs)


def _es2_weapons():
    d = _gam('WEAPONS.DAT')
    n = struct.unpack_from('<h', d, 0)[0]
    p = 2
    weapons = {}
    for _ in range(n):
        wi, ln = struct.unpack_from('<hh', d, p)
        p += 4 + ln
        price, available = struct.unpack_from('<HB', d, p)
        p += 3 + 2
        if ES2_WEAPONS[wi]:
            weapons['es2:%s' % ES2_WEAPONS[wi]] = {"price_kg": price * TONS_KG, "available": bool(available)}
    k = struct.unpack_from('<h', d, p)[0]
    start = []
    for i in range(k):
        wi, cond, _missile = struct.unpack_from('<hhh', d, p + 2 + i * 6)
        start.append({"weapon": 'es2:%s' % ES2_WEAPONS[wi], "condition": cond})
    return weapons, start


def _es2_names():
    import audio
    names = [s for s, _ in audio.read_str(P.work('es2', 'extracted', 'SIMVOL0', 'STR', 'PILOTS.STR'))]
    return [names[i:i + 3] for i in range(0, len(names) - len(names) % 3, 3)]


def write(pack, data):
    path = P.pack(pack, 'gameplay', 'economy.json')
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=1)
    print('economy: %s (%d Hercs, %d weapon prices, %d pilots)' % (path, len(data['hercs']), len(data['weapons']),
                                                                    len(data['pilots'])))


def main():
    which = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if which in ('es1', 'all'):
        write('es1', es1())
    if which in ('es2', 'all'):
        write('es2', es2())


if __name__ == '__main__':
    main()
