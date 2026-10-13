# Earth Siege 1 — reverse engineering notes

Project: native Godot 4 rebuild of *Metaltech: Earthsiege* (Dynamix, 1994).
Original disc contents: `original/` (extracted from `<iso dir>\earth_siege.iso`).
VOL archives extracted into `extracted/<VOLNAME>/<DIR>/<FILE>` by `tools/vol.py`.

## Executables
- `GO.EXE` = front-end "shell" (menus, briefings, campaign). `DBSIM.EXE` = 3D simulation.
  The shell writes `data\script.dat`, `data\mission.var`, `data\player.mec` for the sim, which
  writes `data\results.dat` back.
- Both are FlashTek X-32VM DOS-extended, flat-model 32-bit code (probably Symantec/Zortech C++).
  Source paths like `C:\P\M\s\c\terrain.cpp` appear in assert strings with line numbers.
- **DBSIM.EXE: virtual address = file offset − 0x48FD.** Use `tools/exe.py`:
  - `python tools/exe.py str <text>` → string VA + code locations that push it
  - `python tools/exe.py func <va-hex> [n]` → disassemble from the enclosing function prologue
  - `python tools/exe.py dis <va-hex> [n]`
  Disassembly annotates immediates that point at strings.
- Resource lookup: `call 0x60698` with (name, ext) builds a file name; `call 0x567cc` opens a stream;
  stream reads are `call [vtbl+0x1c]` with (stream, dst, size) and `call 0x56d70` (stream, dst, size).
- GO.EXE base = 0x48FD as well (same technique; `IMAGES['GO']` in tools/exe.py). GO functions often
  begin with `enter N,0`, which `func_start` does not recognise.

## VOL archive (`VOLN`)
`"VOLN"`, u32 flags, u8 ?, u8 ndirs, u16 dirStrLen, dir strings (NUL-terminated, e.g. `"DTS\"`),
u16 count, u32 indexSize, then `count` × {char name[13], u8 dirIndex, u32 absOffset}.
Each file at offset: u8 0x02, u32 size, u32 DOS date/time, data[size], 1 pad byte. Uncompressed.

## Dynamix object header
Most binary resources start with u16 type, u16 class, u32 size (size excludes the 8-byte header).
- class 0x28 = graphics library: 0x01 DBA (bitmap array), 0x0e DBM (bitmap), 0x0b DCI (cursor),
  0x0f DPL (palette), 0x0c rectangle region, 0x0d edge table.
- class 0x14 = 3Space shape parts (TS*), class 0x1e = animation (AN*), class 0x2bc = grid shape.

## Palettes (DPL)
header, u32 count(256), count × (r,g,b,flags) with 6-bit VGA components. Indices 0x20–0x4F are
magenta placeholders in every world palette (filled at runtime with shade ramps — TBD).

## Bitmaps (DBM/DBA) — `tools/gfx.py`
DBA: header, u32 count, then DBMs, each word aligned. DBM: header(8), u16 height?, u16 width?
(as used in gfx.py — verified visually), u8 bpp, u8, u8, u32 imageSize, u16 extra, pixels.
Index 0 = transparent.

## Shapes (DTS / DGS) — `tools/dts.py`, `tools/dts_mesh.py`
Structure from open-siege/siege-studio (MIT). Fixes: detail_part = part_list + s16 size per part;
grid_shape (1,0x2bc) = part_list followed by a collision/height grid (not yet decoded).
- Files contain several top-level `an_shape`s = detail levels (LODs).
- group: points include both vertices and unit normals (length 2048). poly.vlist indexes
  group.indexes[], which index group.points[]. poly.normal / poly.center index points too.
- group.transform = node index. Points are node-local. Node hierarchy from an_anim_list.relations
  (parent, dest); node local transform = transforms[default_transforms[node]];
  transform = (rx, ry, rz in 1/65536 turns, tx, ty, tz). Units: Herc ~2500 tall.
- cell_anim_part children = alternative states (intact / damaged / destroyed stub).
- Colours: each poly.color indexes 4 consecutive group.colors (u32). Entry 0 is primary.
  - texture_for_poly ("TSTexture4Poly"): byte0 = texture index into the object's texture set;
    UVs are the 4 quad corners. Sets: Hercs = LIGHT/MEDIUM/HEAVY DBA, Cybrids = ENEMY.DBA,
    bases = BASETEX.DBA, weapons = WPNTEX.DBA.
  - shaded/gouraud: byte0 = shade ramp index (0..15), byte3 = 4.
  - solid: byte0 = palette index (some in dynamic 0x20–0x4F range).
  - plain `poly` (class 0x01): no colour at all, never drawn (invisible stubs/plates, world.md §4).

## Worlds
`SIMVOL0/WLD/WORLDn.WLD` lists palette name, clouds DBA, impact palette, ground texture (.64K, 256×256),
and `tex` (TEX.DAT). Terrain features (mountains) are grid shapes in DESERT/TEMPER/ICE/URBAN.DGS.
Loader: DBSIM `0x251c4` (reads WLD fields).

## Missions
`ZONES/MSN/*.MSN` (compiled mission script, MC version 5) + `*.ENG` (text chunks `BRF:`, `OBJ:`, `DEB:`).
Fully specified in `docs/formats/mission.md`; tool `tools/mission.py` (MSN → JSON, shell-compiler emulation,
script.dat writer, ENG/campaign readers, demo-tape reader). GO.EXE base is also 0x48FD (`Exe('GO')`).

## Cockpit
- `SIMVOL0/DB0|DB1|DB2/<HERC>.DB?` = 320x200 cockpit overlays (front / look-down panel / side), palette COCKPIT.DPL, index 0 transparent.
- `VUE/<HERC>.VUE`: u32 count (4) + 4 x 8 int32 per view: (x, y, w, h, centreX(neg), centreY(neg), a, b).
  Front view: 320x151 window, projection centre (160,72). Views 2/3 have a=±320 (look left/right).
- GAU/ED*/EDG/PDG/OFS: under investigation (docs/formats/cockpit.md).

## Shape animation sequences (Hercs and bipedal Cybrids share the layout)
seq0 torso twist (node 4 z-rot, frames span ±175°), seq1 walk (800 ticks/cycle), seq2 run,
seq3/4 short transitions, seq5 torso pitch (node 11 x-rot), seq6 turn in place (node 0 z-rot), seq7 death collapse.
Per-game gait tables (BD, ES2, Starsiege, Bulldog/Spider layouts): docs/formats/animation.md.
Node 0 = ground-movement tracker (no geometry), node 1 = hips, 2/3 thighs, 9/10 shins, 5-8 feet,
4 = torso yaw, 11 = cockpit/torso pitch. Part ids 8,9,10,11,18 (hardpoints) and 66,77 are invisible
single-polygon locators.

## Gameplay data
See `docs/formats/gameplay.md` (unit DAT, GL, DMG, COL, WEAPONS.DAT, damage pipeline, BND blocks).
Exporter: `python tools/units.py` → `extracted/gameplay/*.json`. Helpers: `tools/re_util.py`,
`tools/re_fields.py`. Note: `.BND` files are not read by the shipping DBSIM (values compiled in).

## Open follow-ups
- Battledrome Herc scale (user feedback): currently height-matched to the Earthsiege average
  (WORLD_SCALE bd = 0.00215). They look too big; find official BD sizes (manual/box) and re-derive.
