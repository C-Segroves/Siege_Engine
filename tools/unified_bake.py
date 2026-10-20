"""Bakes the unified-render texture strips (docs/RENDER_UNIFICATION.md section 2) for the palette-indexed 3Space packs.

For every indexed texture of a texture set and a world palette, writes
    <out>/unified/<palette id with ':' -> '_'>__<texset>__<index>.png
a vertical strip, width w and height h*R (R = rows of the palette's texlight table: 8 for ES1, 32 for ES2/BD), RGBA8:
level L is rows [L*h, (L+1)*h) = palette[texlight[L][index]], with index 0 transparent. This is exactly what the
runtime load-time bake (game/engine/render/unified_material.gd) builds, which the engine now loads instead when the
file exists. Importers call bake_pack() after writing a pack; the default output is the pack itself, so run
with --out <scratch dir> first and verify (game/tests/render_unified_bake_check.tscn, env RU_BAKE_DIR).

    python tools/unified_bake.py es2 --palettes WORLD0 --out scratch/unified_es2
    python tools/unified_bake.py es1 es2 bd                 (all palettes, written into gamedata/<pack>/unified)
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
GAMEDATA = ROOT / "gamedata"


def _load_look(pack_dir: Path, name: str):
    """(texlight table as uint8 [R, 256]) for palette `name`, or None when the palette has no tables."""
    num = name.removeprefix("WORLD")
    cands = []
    if num.isdigit():
        cands.append(pack_dir / "worlds" / f"texlight_{num}.png")
    cands.append(pack_dir / "looks" / f"{name}_texlight.png")
    for c in cands:
        if c.exists():
            return np.asarray(Image.open(c).convert("L"), dtype=np.uint8)
    return None


def bake_strip(index_png: Path, texlight: np.ndarray, palette: np.ndarray) -> Image.Image:
    idx = np.asarray(Image.open(index_png).convert("L"), dtype=np.uint8)
    h, w = idx.shape
    levels = texlight.shape[0]
    out = np.zeros((levels * h, w, 4), dtype=np.uint8)
    for level in range(levels):
        mapped = texlight[level][idx]
        rgb = palette[mapped]
        out[level * h:(level + 1) * h, :, :3] = rgb
        out[level * h:(level + 1) * h, :, 3] = np.where(idx == 0, 0, 255)
    return Image.fromarray(out, "RGBA")


def bake_pack(pack: str, out_root: Path = None, palettes=None) -> int:
    pack_dir = GAMEDATA / pack
    out_dir = (out_root if out_root is not None else pack_dir) / "unified"
    pal_files = sorted((pack_dir / "palettes").glob("*.json"))
    count = 0
    for pf in pal_files:
        name = pf.stem
        if palettes and name not in palettes:
            continue
        texlight = _load_look(pack_dir, name)
        if texlight is None:
            continue
        palette = np.array(json.loads(pf.read_text()), dtype=np.uint8)[:, :3]
        for meta in sorted((pack_dir / "textures").glob("*.json")):
            texset = meta.stem
            tex_dir = pack_dir / "textures" / texset
            if not tex_dir.is_dir():
                continue
            for png in sorted(tex_dir.glob("*.png"), key=lambda p: int(p.stem) if p.stem.isdigit() else 0):
                if not png.stem.isdigit():
                    continue
                dest = out_dir / f"{pack}_{name}__{texset}__{png.stem}.png"
                dest.parent.mkdir(parents=True, exist_ok=True)
                bake_strip(png, texlight, palette).save(dest, optimize=False, compress_level=3)
                count += 1
    return count


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("packs", nargs="+")
    ap.add_argument("--out", type=Path, help="scratch root (gets a unified/ folder); default: the pack's own folder")
    ap.add_argument("--palettes", nargs="*", help="palette names to bake (default all with texlight tables)")
    a = ap.parse_args()
    for pack in a.packs:
        print(pack, bake_pack(pack, a.out, a.palettes), "strips")


if __name__ == "__main__":
    sys.exit(main())
