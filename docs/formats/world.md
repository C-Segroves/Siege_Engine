# World rendering data: WLD, palettes and shade ramps, haze, sky, ground, terrain

Covers how DBSIM draws the environment and how object colours are produced.
The tool is `tools/world.py`. It parses everything below, writes JSON per world, and renders previews.
VAs are DBSIM.EXE virtual addresses (file offset − 0x48FD).

Confidence levels:
- **H** = read directly from the disassembly and checked against the data.
- **M** = the mechanism is understood, but some semantic or orientation details are inferred.
- **L** = a guess.

## 1. World selection (H)

The sim reads a 20-byte struct `W` at `0xbc49c`. The mission or script fills it; that loader has not been traced yet. `0x1e5b9` calls `zone_load(W.terrain, W.zone)` (`0x20238`), then `world_load(&W)` (`0x251c4`).

| W offset | meaning |
|---|---|
| +0 u16 | terrain type: 0 = desert, 1 = temper, 2 = ice, 3 = urban. Name table at `0x924a0`. |
| +2 u16 | zone number, which selects `ZONE<n>.DAT` |
| +0x10 u16 | low-detail flag |
| +0x12 u16 | time of day: 0 = day, 1 = dusk, 2 = night. Confirmed by the palettes. |

- Palette: `WORLD<terrain*6 + time*2>.DPL`. Only even numbers are used; WORLD1.DPL and WORLD3.DPL are unused leftovers.
- World file: `WORLD<terrain*6 + time*2 + lowdetail>.WLD`. Odd-numbered worlds are the low-detail variants: no panorama, `tex_lo` distances, coarser bands.
- `<palette name>.CYC` is optional palette cycling (`0x258c6`). Format: u16 n, then n × (u16 first, u16 count, u16 period), up to 5 cycles (`0x28260`). **No .CYC files ship.**

## 2. WLD format (H for layout; semantics as marked)

All values are little-endian. Offsets below are for the 5-string layout; low-detail files are the same apart from the strings.

| off | type | name in world.py | used by / meaning |
|---|---|---|---|
| 00 | s16 | horizon_offset | Copied to horizon+0x6c. The first sky and ground band starts `v/2` px from the horizon line. Ground texturing also forces the first `v/2` rows to full haze (`0x294bd`). (M) |
| 02 | s16 | sky_first | First palette index of the sky ramp. This is the zenith colour and fills everything above the bands. (H) |
| 04 | s16 | sky_band_px | Thickness of each sky band in pixels at 320×200 (horizon+0x54). (H) |
| 06 | s16 | sky_count | Number of sky bands (horizon+0x58). Band k counted from the horizon uses colour `sky_first + sky_count - 1 - k`. (H) |
| 08 | s16 | ground_first | First index of the ground ramp (horizon+0x2c). This is the flat ground colour when texturing is off. (H) |
| 0a | s16 | ground_band_px | Ground band thickness (horizon+0x5c). (H) |
| 0c | s16 | ground_count | Ground band count (horizon+0x60). The colour at the horizon is `ground_first + count - 1`, which equals the haze colour. Also sets `0x928e0 = ground_first + count - 1`. (H) |
| 0e | s16 | horizon_field_30 | horizon+0x30, added to a horizon coordinate. Values are 0 or 1. (L) |
| 10 | s16 | flat_field_15 | Copied to +0x15 of the decal pool object (`0x26dec`). The value is always a palette index in 0xe4–0xfb, probably the crater or scorch colour. (L) |
| 12 | s16 | flat_variant | ≠0 loads shape set `flat2.dts` instead of `flat.dts` (craters/scorches, `0x6cf8`). Set for worlds 16–21. (H) |
| 14 | s16 | ambient_low_index | Palette index. See the cockpit ambient in section 3.3. (H mechanism) |
| 16 | s16 | ambient_high_index | Same as above. |
| 18 | u32 n + n×u32 | haze_dist_objects | Haze level thresholds for ordinary objects (16 values). (H) |
| … | u32 n + n×u32 | haze_dist_terrain | Thresholds for shade class 0, the terrain grid shapes (16 values). (H) |
| … | u16 | haze_levels | 16 |
| … | u16 nr, nr×(u16 start, u16 count) | ramps[].start/count | Lit colour ramps (8). (H) |
| … | u16 nt, nt×(u16 start, u16 count) | ramps[].haze_start/haze_count | Haze target of each ramp, always count 1. (H) |
| … | u16 start, u16 count, u16 start, u16 count | glow_ramp | Fire/glow ramp `0x56..0x65` with its target `0x66`. (H layout, M use) |
| ee | s16 | cloud_count | Number of cloud billboards (20). (H) |
| f0 | s16 | flat_count | Size of the decal pool (250); 0 means no pool. (M) |
| f2 | s32 | haze_offset_low | Added to the distance before the haze lookup. Applies to shade class 8 and to class 5 objects whose vfunc+0x14 (altitude?) is < 5000. (H code, L meaning) |
| f6 | s32 | haze_offset_high | Same, for class 5 objects with value ≥ 5000. |
| fa | cstr | panorama | `dba\<name>.dba`: distant mountain strips. An empty string means none. |
| | cstr | clouds | Cloud bitmaps DBA (`clouds2`). |
| | cstr | impact_palette | DPL swapped in for the hit flash (`impact1`, `0x25ed0`). |
| | cstr | ground_texture | `dba\<name>.64k` (trenches or cracks). |
| | cstr | ground_haze_dat | `dat\<name>.dat` (tex / tex_lo / tex_lo2). |

## 3. Palette

### 3.1 DPL with shade lists (H)

The layout is: header(8), u32 256, 256 × (r, g, b, flags) in 6-bit VGA. Convert with `v*4 + v/16`.

World DPLs then add a tail: u32 m (256), then m × (u16 n, n × u16 palette index). These are the **default shade slot lists**. When a palette is loaded, list i becomes shade slot i (`0x69371` → `0x691f8`, table `0x9a6f5`, 8 bytes per slot).

| slots | lists (world0) |
|---|---|
| 0 / 1 | 0x68–0x6d / 0x68–0x6f |
| 2 / 3 | 0x70–0x7f / 0x70–0x83 |
| 4 / 5 | 0x84–0x93 / 0x84–0x97 |
| 6 / 7 | 0x98–0xa7 / 0x98–0xab |
| 8 / 9 | 0xac–0xbb / 0xac–0xbf |
| 10–13 | small lists; differ per palette |
| 200 | [0] or [0xc8] |
| all others | [0xff] |

Even slots hold the lit ramp. Odd slots hold the same ramp extended by the haze colours.

Fixed palette regions in every world:
- 0x00–0x1f: UI and grey ramp
- 0x30–0x3f: HUD
- 0x56–0x66: fire/glow
- 0x68–0xcf: object ramps; the last entry of each ramp is the haze colour
- 0xd6–0xdf: sky ramp
- 0xe0–0xef: panorama colours
- 0xf0–0xff: ground ramp

### 3.2 Magenta range 0x20–0x4F (H)

This range is **not** world shading. It is the cockpit colour scheme. `0x220d6` copies the colours below from `COCKPIT.DPL`, where scheme k is the VUE object field +0x23 (its source is not traced yet):

- `COCKPIT[k*32 + 0..15]` → 0x20–0x2F
- `COCKPIT[k*32 + 16..31]` → 0x40–0x4F
- then `0x40 = COCKPIT[tab[k]]`, with `tab = {2c,25,2d,27,2d,2d,2d,28}` (`0x925dc`)

0x50–0x55 are rewritten by the HUD (`0x39619`), and other screens copy 0x20/0x40 from their own palettes (`0x57f53`).

Solid shape colours inside 0x20–0x4F are therefore cockpit or Herc-interior colours. Use `World(i, cockpit_scheme=k)`.

### 3.3 Cockpit ambient (0x40–0x4F, per frame, H)

`0x25fe4` does the following:

1. Builds a 16-step gradient from `pal[ambient_low_index]` to `pal[ambient_high_index]` (`0x283b0`, 8.8 fixed point per channel).
2. Picks entry `clamp((cam_pitch + 0x2000) >> 10, 0, 15)`. During the hit flash it uses `pal[0x62]` instead.
3. Writes a 16-step gradient from the cached `pal[0x40]` to that colour into 0x40–0x4F.

So the cockpit brightens when you look up at the sky.

## 4. Shaded polygons (H)

A 3Space colour dword is `{u16 slot, u8 intensity, u8 kind}`.
- kind 0: solid. The low byte is the palette index.
- kind 4: shaded. The palette index is `slot_list[slot][(I * n) >> 8]`, where n is the list length (`0x68ce8`, `0x690ab`, `0x6a0b7`).
- Gouraud polys do the same per vertex with u16 intensities (`0x7965c`).

Each poly has 4 colour dwords: entries 0–1 are used for the front face and entries 2–3 for the back face (`0x54163`).

**Intensity** (`0x5bc30`): the sum over the active lights in `0xbdba6`, at most 10:
- type 0, ambient: `I += k`
- type 1, directional: `I += k * (1 - n·L) / 2`, where L is the light vector pointing *into* the scene. Implemented as `-(k * ((n·L)·2048² - 2048²)/2) >> 22`.
- type 2, point light: falls off with distance.

The result is clamped to ≤ 255.

The sim creates one **sun** (`0x5a888`, called from the init at `0x5ad1f`): directional, k = 256, vector (0, 0x800, 0) rotated by euler (rx = 0xe0c0, ry = 0, rz = 0x5dc0). Assuming Rz·Ry·Rx, L ≈ (−0.536, −0.480, −0.694), so the light comes from above. A flat ground-facing-up poly gets I = 216. The sun is the same in every world: **WLD has no light direction.** Lights of type 1 and 2 are also pooled for effects (`0x52a4`, `0x537c`). Rotation order and handedness: **M**.

**Haze per object** (`0x25d44`, called per object from `0x20f7c`):
- haze level h = number of thresholds ≤ distance (0..15), using `haze_dist_terrain` for shade class 0 and `haze_dist_objects` otherwise (`0x25cb4`).
- `SHADES.DAT` then overrides some slots with a WLD ramp window for that h.

The ramp window table (`0x289e0`) gives each ramp r at level k: `start = s + (k*(((hs - s + 1) << 8) / 15) >> 8)`, `end = e + (k*(((he - e + 1) << 8) / 15) >> 8)`, with the last level equal to the haze target. The window slides along the palette toward the haze colour, so the poly fades into the fog colour with distance.

If the object flag is set, the top `n/4 + 1` entries come from the glow window instead (`0x280e4`; M, probably burning or flash).

**SHADES.DAT** (`0x25bc8`, H): u8 nclasses (10), u8 nrec, then nrec × (u8 class, u8 n, n × (u8 slot, u8 ramp)).

| class | (slot ← ramp) |
|---|---|
| 0 (terrain DGS; it uses slot 14) | 14←7 |
| 1, 5, 7 | 0←0, 2←1, 4←2, 6←3, 8←4, 12←6 |
| 3 | 12←6 |
| 6 | 8←4, 12←6 |

If no SHADES table is loaded, the fallback (`0x25e88`) points every even slot at the grey 0x10–0x1f.

**Textured polys** (`0x5410c`) are not ramp-indexed. They use one of 8 remap tables picked by `7*I/255` (`0x973f0`, built by `0x28b27` at palette load):
- for each colour c that appears in a DPL list (the last list containing it wins), scale its RGB per channel by `rgb(list[(n-1)*L/7]) / rgb(list[round((n-1)*650/1024)])`
- take the nearest palette colour (Euclidean distance)

L ≈ 4.45 is identity. `World.texture_light_tables()` reproduces this. Textures get no distance haze.

**Colourless polys are not drawn (H):** plain `TSPoly` (class 0x01/0x14, `t: "poly"` in the shape JSON) has no
colour field, and its draw methods are empty stubs (ES2 DBSIM vtable `0x4a5ea0`, `0x48dbd4..0x48dbf4`).
Shapes use it for invisible geometry: the single-triangle "destroyed" state of every cell, and plates such
as part id 13 on node 4 (RAPTOR: a 222 × 313 quad above the cockpit facing down; also MIRIMAC, RAMSES,
ROADRUNN, ES2 APOCA, OGRE, MAVERICK …) and RAPTOR's node-11 divider. `export_es1.material_of` gives them
a dummy `solid 0`; `ShapeInstance.is_drawn` skips them (they used to render as flat black plates).

**Colour recipe for a remake:**
- solid index c → `palette[c]`
- shaded slot s → `palette[list[(I*n) >> 8]]`, where the list comes from the SHADES class and the haze level, or the DPL list otherwise
- haze colour = `palette[ramps[*].haze_start]`: the same colour for all ramps, and equal to the ground ramp's horizon colour

## 5. Sky, horizon, panorama, clouds

**Bands** (`0x2650c` sky, `0x267d8` ground, H/M):
- Drawn along the rolled horizon line.
- Sky: `sky_count` bands of `sky_band_px`, colours from `sky_first + count - 1` at the horizon decreasing upward; the area above is `sky_first`.
- Ground, when untextured: the same, from `ground_first + count - 1` at the horizon down to `ground_first`.
- Thickness is in screen pixels, not world units.

**Panorama** (`0x26ac8`, M): `WORLDn.DBA` holds 4 strips of 320 × (6–15) px.
- Total width 1280 px = 360° of heading (`heading * 1280 / 65536`).
- The bottom row sits on the horizon.
- Drawn at 1:1 pixel scale, rotated with roll, colour 0 is transparent.
- Uses colours 0xe5–0xee.

**Clouds** (`0x271c0`, `0x27c00`, M):
- `cloud_count` (20) flat textured quads from the clouds DBA (3 bitmaps 120×63, 136×44, 128×64, colours 0xd7–0xdf, i.e. the sky ramp).
- Parameters are hard-coded in `0x27c1f`: altitude z = 10000, quad half-size 25000, ring spacing 25000, max radius 200000.
- Placement: random angle per cloud, random bitmap `rand(3)`.
- They drift with a random heading at speed `rand(100) + 50`.
- `CLOUDS.BND` holds similar numbers but is not what this code reads.

## 6. Ground texture (H unless noted)

`.64K` is 256×256 raw u8, rows in v. Texel values are 0xf0 + i, and only the low nibble i is used.

`0x28de8(tex, gnd, horizon_offset, ground_band_px, ground_count, ground_first)` builds 15 remap tables:
`table[j][i] = base + i + ((top - (base + i)) * j) / 14`, with `base = ground_first & 0xF0` and `top = ground_first + ground_count - 1`.
Each table is an index-space lerp toward the horizon/haze colour.

Per scanline (`0x29120`):
- row distance d = camera height × focal / row offset (`0x28fbc`)
- table `j = #{TEX[k] ≤ d}` (0..14), where `TEX.DAT` is u32 15 followed by 15 u32 distances: tex 20000..112400, tex_lo 10000..54800, tex_lo2 12000..97400
- the `horizon_offset/2` rows next to the horizon use table 14

Texture mapping uses world x and y masked to 16 bits, then `>> 8`. That gives **256 world units per texel** and a 65536-unit repeat (M; the `0xcc` span factor is ignored). The ground gets no lighting.

Textured ground is used only when horizon+0x70 is set and the detail level is high enough (`0x26806`). Otherwise the flat bands are drawn.

## 7. Terrain features (DGS grid shapes + DAT + ZONE)

**Object stream:** DGS top-level objects are **word aligned**: an odd-sized object is followed by 1 pad byte. `dts.read_file` misses this and desyncs on TEMPER, ICE and URBAN; `world.read_dgs_objects` handles it. Every terrain DGS contains 13 grid shapes.

**grid_shape (1, 0x2bc)** (`GridShape::read` `0x1ff48`, H): TSShape body, then the grid.
- TSShape body: part_list (a detail_part with 2–4 LODs), u16 ntransforms, u16 nseq, seq[nseq], transforms[ntransforms]. The terrain files always have 0, 1, [2].
- Grid fields:
  - `s16 cols, s16 rows, s16 origin_col, s16 origin_row, s16 cell_shift` (always 9, i.e. 512 units)
  - `u32 height_table[256]`: linear `k*hmax/255`, so `table[255]` is the shape's max z
  - `u8 heights[rows][cols]`
- Sample point (col, row) is at shape-local `x = (col - origin_col) << shift`, `y = (row - origin_row) << shift`, `z = height_table[h]`.
- The point → height mapping was checked visually against the LOD0 outlines (`world.grid_height` = bilinear). Use it for ground collision and Herc footing.

**`<TERRAIN>.DAT`** (`0x20360`): one 24-byte record per DGS shape, `{i32 x, y, z}` × 2. If z = −1 there is no record. The sim attaches it to the instance (+0x3b) when z ≥ 0.
- It holds two points at opposite ends of a shape, often just outside the grid, e.g. canyon ends.
- Likely AI path or pass endpoints. **L**

**`ZONE<n>.DAT`** (`0x20238`; SIMVOL0/DAT and ZONES/DAT, H):
- `u16 terrain type`. It matches the zone's terrain, but the sim uses `W.terrain`.
- `u16 n`
- n × `{u16 shape, i32 x, i32 y, i32 z, u16 rx, ry, rz}` (20 bytes)
- Positions are in world units; rotations are in 1/65536 turn and only rz is used in practice.
- Zones cover about ±150k to ±1.3M units.
- Run `python tools/world.py zone auto <n>` to dump one.

`ZONES/DAT/WORLD0..3.DAT` are an older WLD-like format (`w1dusk`, `w1dcrk`); the sim does not use them.

## 8. Not yet decoded

- Exact projection, FOV and camera height for the ground texture mapping.
- Sign and order conventions of the sun euler angles.
- Meaning of WLD 0x0e and 0x10.
- Which game object classes map to SHADES classes 1–9.
- Source of the cockpit scheme index.
- Who fills `W` (mission script).
- The use of the terrain .DAT points.
- Exact pixel geometry of the first sky/ground band offset.
