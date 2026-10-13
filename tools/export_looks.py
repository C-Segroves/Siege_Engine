"""Lighting lookup tables for any 3Space DPL palette (shade lists + textured-poly light remap).

Writes gamedata/<pack>/looks/<PALETTE>_shade.png (32x256) and <PALETTE>_texlight.png (256x8),
the same tables export_es1.py writes for world palettes, so shapes from any pack light correctly.

    python tools/export_looks.py <pack> <path-to-DPL> [...]
"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import world  # noqa: E402

import siege_paths as P  # noqa: E402


def export(pack, dpl_path):
    raw, lists = world.read_dpl_full(dpl_path)
    name = os.path.splitext(os.path.basename(dpl_path))[0].upper()
    out = P.pack(pack, 'looks')
    os.makedirs(out, exist_ok=True)
    world.make_shade_list_image(lists).save(os.path.join(out, name + '_shade.png'))
    w = world.World.__new__(world.World)   # reuse the remap-table builder without a WLD
    w.raw_palette = [list(c) for c in raw]
    w.dpl_lists = lists
    world.make_light_table_image(w.texture_light_tables()).save(os.path.join(out, name + '_texlight.png'))
    return name


if __name__ == '__main__':
    pack = sys.argv[1]
    for p in sys.argv[2:]:
        print(pack, export(pack, p))
