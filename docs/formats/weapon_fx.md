# Weapon visual effects (all packs)

How each game draws a weapon shot — projectile look, beam, trail, muzzle flash, impact explosions,
shield hit flashes, lights — where the original data lives, and how the importer exports it into the
engine weapon schema (`fx` block, `docs/formats/weapon_schema.md`) plus a pack-wide effect library
(`gamedata/<pack>/fx/effects.json`). The runtime is `game/engine/fx/` (FxLibrary, FxPlayer, ...).

Rules and layouts only: no original values tables are copied here; every value is read from the user's
disc at import time.

## 1. Engine data contract

### 1.1 Pack effect library: `gamedata/<pack>/fx/effects.json`

```json
{
  "pack": "es1",
  "source": "evidence for the library as a whole",
  "sprites": {
    "<sprite name>": {
      "frames": ["fx/sprites/<sprite name>/0.png", "..."],   // paths relative to the pack root
      "format": "indexed | rgba",      // indexed = 8-bit PNG (mode L, value = palette index)
      "palette": "<palette id>",       // indexed only: palette in this pack (palettes/<id>.json)
      "transparent_index": 0,          // indexed only: palette index drawn transparent (-1 none)
      "fps": 10.0,                     // original frame rate
      "loop": false,
      "metres_per_pixel": 0.05,        // world size of one bitmap pixel (or give "size" on the layer)
      "origins": [[6, 6], "..."],      // optional: anchor pixel (x, y from the top-left) per frame
      "blend": "alpha | additive",     // additive for glows (Darkstar/Torque translucent/additive bitmaps)
      "source": "evidence"
    }
  },
  "deaths": {"vehicle": {"steps": [...]}, "...": "section 9"},
  "effects": {
    "<effect name>": {                 // an explosion, impact spark, muzzle flash, smoke puff, shield flash
      "layers": [
        {"sprite": "<sprite name>", "size": 6.0, "duration": 0.7, "delay": 0.0,
         "offset": [0, 0, 0], "grow": 1.0, "fade": true, "color": [1, 1, 1, 1], "rise": 0.0},
        {"shape": "<pack:SHAPE>", "duration": 0.5, "spin_dps": [0, 0, 0], "grow": 1.0},
        {"flash": {"color": [1, 0.6, 0.2, 1], "size": 3.0}, "duration": 0.2, "grow": 2.0},
        {"particles": {"count": 12, "sprite": "<sprite name> | null", "color": [1, 0.8, 0.4, 1],
                       "color_end": [0.3, 0.3, 0.3, 0], "speed": 8.0, "spread_deg": 180.0,
                       "lifetime": 1.0, "size": 0.5, "size_end": 1.5, "gravity": -9.8, "drag": 0.0},
         "duration": 1.0}
      ],
      "light": {"color": [1, 0.7, 0.3], "range": 12.0, "duration": 0.4},
      "sound": "<sound stem> | null",
      "source": "evidence"
    }
  }
}
```

* `size` (m) on a sprite layer is the world height of the tallest frame; without it the sprite's
  `metres_per_pixel` is used. `duration` without `fps` frames spreads the frames over the duration;
  with neither, frames play at the sprite's `fps`.
* Effect and sprite names are pack-local; a reference may be qualified `"<pack>:<name>"`.
* `particles` is drawn on the CPU (headless-safe); the engine caps live particles per battle.

### 1.2 Per-weapon `fx` block (in `weapons_engine.json`, `weapons_infantry.json`; ES1 `weapons.json`)

```json
"fx": {
  "source": "evidence",
  "projectile": {                    // what flies (null for instant beams)
    "sprite": "<sprite name> | null",     // animated billboard (ES1/ES2 bullet bitmaps, Darkstar bulletShape .bmp)
    "shape": "<pack:SHAPE> | null",       // 3D model (missiles, shells)
    "size": 0.6,                          // m: sprite height or uniform shape scale reference (shape: 1.0 = as exported)
    "color": [1, 0.9, 0.4, 1],            // tint / colour when only a glow is known
    "spin_dps": 0.0,                      // roll about the flight axis (Darkstar rotationPeriod)
    "face": "billboard | velocity",       // sprite facing: camera, or stretched along the flight path
    "light": {"color": [1, 0.8, 0.4], "range": 6.0} // dynamic light carried by the projectile (null none)
  },
  "beam": {                          // instant beams (null otherwise)
    "texture": "fx/textures/<file>.png | null",   // the beam bitmap (ES1 BEAM.BND / Darkstar beam .bmp / T2 texture)
    "texture_format": "indexed | rgba",           // indexed: palette as in sprites
    "palette": "<palette id>",
    "color": [1, 0.2, 0.1, 1],
    "width": 0.2,                    // m
    "duration": 0.12,                // s on screen
    "style": "solid | textured | bolt",   // bolt: a short glowing segment travelling at beam speed
    "glow": true
  },
  "trail": {                         // smoke / glow trail (null none)
    "effect": "<effect name> | null",     // spawned every `interval` s along the path
    "interval": 0.05,
    "style": "puffs | ribbon",
    "color": [0.8, 0.8, 0.8, 0.6], "size": 0.6, "lifetime": 0.8
  },
  "muzzle": "<effect name> | null",
  "impact": {                        // random pick among the original variants per surface
    "miss":   ["<effect name>", "..."],   // ground / structure / nothing (ES1 fx miss)
    "shield": ["<effect name>", "..."],   // shield absorbed the hit
    "armor":  ["<effect name>", "..."],   // armour / vehicle body hit
    "water":  ["<effect name>", "..."]    // optional
  },
  "notes": "approximations"
}
```

Runtime surface choice (`FxSurface`): no collider or not a vehicle → `miss`; a vehicle whose shield bank on
the hit side still holds charge → `shield`; otherwise `armor`. A missing list falls back to `armor` → `miss`.

## 2. Earthsiege 1

Tool: `python tools/fx_es1.py [--sheet renders/weapon_fx_es1_sprites.png]` (importer step `weapon_fx`, after
`gameplay`). Reads SIMVOL0 DTS/DBA/STR, the exported gameplay tables and DBSIM.EXE (VA = file − 0x48FD; the
instruction bytes it reads are checked first). Units: 1/256 m per unit (pack policy); timers 2560 per s.

### 2.1 Explosions (`EXPLOS.DAT`, explo.cpp)
* Loader 0x5764 loads `EXPLO0..8.DBA`; EXPLOS.DAT = `u16 n`, n × 22 words. Word 0 = EXPLOS.DTS shape,
  word 2 = which EXPLO<n>.DBA that shape's bitmap tags index (binding 0x58ff..0x5924).
* Ctor 0x5af0 / update 0x5d74: w1 = cell-anim sequence (−1 static: one frame period), w3 = frame period
  (timer units), the sequence plays once then the object dies. w4 ≠ 0: FLAT.DTS shape 1 (ground blast ring)
  with its cells advanced per frame. w5 ≠ 0: point light (0x54b0) of intensity I = low byte of word 6+frame
  (0x5e0c). Sound id = w20 + 10. w18/19 (u32 radius) and w21 (object type 8) unexplained.
* Light manager (0x55b8: 0x4da8 with 2000 / 10 → B = 62, A = 0): radius = (B << 5)·I/10 units = 198.4·I
  (0x5274, recomputed per frame by 0x4f34); brightness at distance d = I·min(255, (B << 8)/(d >> 5))/256
  (0x5015): full within 1991 units, then 1/d. The light is a scalar that raises the shade / light level of
  the polygons it reaches (their own palette ramps): **it has no colour** → exported white. Export
  (`fx_common.make_3space_light`, shared with ES2): `range` = 4 × the full radius × peak/255 (where the 1/d
  light is down to 25 %), `full_range`, `cutoff`, per-frame `energy` + `frame_s`, `range_follows_energy`.
* Export: sprite `explos_<shape>` per shape, effect `explo_<row>` per row (sprite layer of frames × period,
  optional `es1:FLAT_1` shape layer stepped per frame (`cells_per_frame`), light with a per-frame `energy`
  curve, sound stem from SOUNDS.STR).

### 2.2 Bitmap sprites
* TSBitmapPart render 0x52b90: screen px = bitmap px · project(radius·4) >> 8, i.e. one pixel = radius/64
  units; anchor = (xo, yo) (may lie outside the bitmap: smoke rises that way). Opaque palette pixels, index 0
  transparent, no blending; skipped when ≥ 200 px on screen.
* The blit path (0x52b90 → 0x67178 → 0x76884) only decompresses the bitmap (0x672cc, types 1 / 3): no shade,
  texlight or haze remap, so the indices land unchanged in the frame buffer and show in the **mission's
  WORLD<n> palette**. The fire / ricochet / smoke indices effects use (0x5a–0x66, 0xc0–0xd5) differ between
  worlds. Frames are indexed with `palette` = pack default and `palette_per_world: true`; bolt and tracer
  colours keep their `palette_index`. None of them uses the cockpit range 0x20–0x4f.

### 2.3 Impact choice (Mech::onHit 0x13fd4, terrain 0x1f603)
`fx[12]` of the projectile row = 3 groups × 4 random ids. Group 0 = the shield absorbed the whole hit (placed
on the shield sphere; sound `shield1`) → `impact.shield`; group 1 = armour hit without an integrity step, also
every terrain hit → `impact.miss` and `impact.armor_light`; group 2 = armour hit that lowered the component's
integrity step → `impact.armor`. (`gameplay/weapons.json` keeps the historical labels fx_miss / fx_shield_hit /
fx_armor_hit for groups 0 / 1 / 2.)

### 2.4 Shots
* Bullets (type 2; bullet.cpp): BULLETS.DAT[sub] = {shape, lifetime (updates), hit size, frame period,
  sound+10}. Poly shapes = a 2-point line in a palette colour → tracer (`face: velocity`, size = line
  length). Bitmap shapes (EMP balls) → looping sprite `bullets_<shape>` at the frame period. The EMP rows
  therefore fly (the remake's loader gives them a projectile block).
* Bolts (type 4; 0x88cc, visual 0x8268, render 0x87e0): instant hit; drawn one sim frame from muzzle to the
  hit (or full range) as two crossed quads of half width table[sub] in solid palette colour table[sub] (exe
  tables, copied in BEAM.BND words 4..15). The ELF sub is a zig-zag ribbon: a node every 0x400 units, inner
  nodes offset by rand&0x7f per axis (`style: lightning`). Fire sound 11.
* Missiles (type 0; rocket.cpp): ROCKETS.DAT[sub] word 0 = ROCKETS.DTS shape (exported `ROCKETS_<n>`);
  exhaust = the shape's cell animation (period word 4); no smoke trail. MLRS racks use the sub-0 row.
* No muzzle flash. GREN fires nothing in the shipping game (row 22 is out of range, hook 0x7b44 empty): the
  remake's lobbed grenade borrows the EMP ball bitmap; impacts from the first grenade row.
* Smoke (`smoke_<shape>`, SMOKE.DTS + SMOKE.DBA): one cell per 200 timer units; wreck emitters only.

## 3. Earthsiege 2

Tool: `python tools/fx_es2.py [--sheet]` (import step `weapon_fx`, after `weapons`). Reads es2/extracted/SIMVOL0
and `gameplay/weapons_raw.json`; addresses are DBSIM.EXE 1.0 VAs. Library: one sprite per bitmap shape, effects
`explo_<record>` (EXPLOS.DAT record = the ids in PROJ.DAT fx) and `smoke_<k>`; beam texture `fx/textures/beamtex.png`.

### 3.1 Explosions: EXPLOS.DAT + EXPLOS.DTS + EXPLO<d>.DBA (loader 0x407b54)
`u16 n_shapes, n_shapes × (s16 cell part, s16 DBA index d → EXPLO<d>.DBA)`, `u16 n, n × 40-byte record`:

| off | field |
|---|---|
| +0 | shape index in EXPLOS.DTS (a cell_anim_part of bitmap_parts; bmp_tag = frame in the DBA) |
| +2 | frame delay, timer units (2048/s); 1 = one frame per sim frame (0x40813c); ends when the frame wraps to 0 |
| +4 | companion object flag (unused) |
| +6 | light: 0 none, 1 point light, 2 light + near query (+0x20 radius, 0x408100; nothing visible) |
| +8..+0x1e | 12 × u16 light intensity per frame (low byte, 0..255; 0x4081d7) |
| +0x20 | u32 radius (units) for light kind 2 |
| +0x24 | sound; SOUNDS.STR id = value + 10 (0x4080c5) |
| +0x26 | large explosion flag (object kind 8 instead of 2) |

EXPLOS2.DAT + EXPLO<d>S.DBA are the reduced low-memory set (flag [0x4d2704]); the exporter uses the full set.
Light manager (0x406ee4/0x40735c/0x407125) = the ES1 code (2.1): brightness = I·min(1, 1991 u/d), cutoff
I·198 u, no colour (exported white, `fx_common.make_3space_light`).

### 3.2 Bitmap sprites (TSBitmapPart render 0x4762e8)
Screen scale = (radius·4 << focal)/depth, pixel extents = scale·px >> 8 → **radius/64 units per pixel**
(`metres_per_pixel = radius/64/256`). Anchor = (s8 xo, **u8** yo) from the top-left (0x47655d movsx, 0x47653c zero-extended: the 160-pixel base
explosion column of record 16 is anchored at its foot; ES1 reads both signed, 0x52c39 / 0x52c4a). Bitmaps are 8-bit, index 0
transparent, drawn opaque in the current WORLD<n> palette (`palette_per_world: true`; indices 0x50–0x68,
0x75–0x7f, 0xb4–0xcb and 0xf1–0xf4 of the effect bitmaps differ per world). The cockpit block 0x2A–0x41 (es2.md
3.3a) is used by no effect bitmap or beam, so the exported WORLD palettes (cockpit scheme 0 filled in) serve
as they are.

### 3.3 Impact choice
PROJ.DAT row `fx[12]` = explosion records; the hit code picks `fx[list·4 + rand&3]` (0x418b2d), list 0 miss,
1 shield fully absorbed (0x41898c), 2 armour (0x41899d). Bases use the armour list (0x405227); deaths: section 9. ES2 data has identical shield and armour lists.

### 3.4 Projectiles and beams
* Bullets (PROJ type 2): BULLETS.DAT[sub] = {shape, lifetime, hit size, **anim delay** (+6, timer units,
  0x40b13f), sound−10, jitter, falloff}. Shapes made of bitmap_parts (EMP balls) → looping billboard sprite
  `bullet_shape_<k>` at 2048/delay fps; others are 3D shapes `es2:BULLETS_<k>`.
* Missiles (type 0): `es2:ROCKETS_<ROCKETS.DAT shape>`; the flame is the shape's cell part (+0xa) cycling every
  +8 timer units (0x40a553). rocket.cpp spawns no smoke: no trail.
* Bolts (type 4): BEAM.DAT[sub] = {half width units, palette colour, texture index}. Render 0x40bc20: an instant
  camera-facing quad, half width ≥ 2 px (0x40bdc8), alive 0x38 timer units (~1 frame). **Colour + texture
  (decoded):** the quad's uv come from texture-table entry [0x4a988c] + 20·(BEAM.DAT +4): u0..u1 from muzzle
  to end, v0..v1 across (0x40bef1; BEAMTEX columns are constant, its rows are the cross profile). Poly 0x468310
  draws it in mode 0, whose span drawer 0x46ab10 copies the texels unchanged: lasers and PBCs show raw BEAMTEX
  (fire ramp 0x54–0x5f, edge 0x0b) in the world palette (`stretch: true`, colour white). BEAM.DAT +2 is
  installed as the gfx fill descriptor {type 0 = flat colour} (ctx [0x6c5ff4] + 0x22c = surface [0x4a362c] +
  0x228, the surface being ctx + 4, 0x480c46; fill dispatch 0x483e1d), which those span drawers never read.
  ELF/ELF2 (subs 1, 7) also draw 4-point stippled polygons through the generic path that fills with it
  (0x40bcb4: 0x48c964 / 0x48ce14 / 0x48d4b4; M): exported as a flat `palette_index` colour with `stipple`,
  zig-zag (`jagged`: one segment per 1024 u, inner vertices +0..127 u random, +width on z; 0x40b862..0x40b9da).
  The BEAMTEX quad the ELF loop also draws over its first segment is omitted.
* No muzzle flash; SMOKE.DTS emitters (0x40923c) are never created in DBSIM 1.0 (wreck smoke only).
* LAEW and MINE never fire in DBSIM 1.0: their impacts use the unused grenade rows (L).

## 4. Battledrome

Tool: `python tools/fx_bd.py` (import step `weapon_fx`, after `weapons`). Reads `bd/installed/DTS/<FX>.DTS` +
`<FX>.DBA`, the arena palette NRMPAL and SIM.EXE (VA = file offset − 0x69CD; instruction bytes checked first).
Writes `gamedata/bd/fx/effects.json` (indexed sprites, palette `NRMPAL`, index 0 transparent) and the `fx`
block of every weapon in `gameplay/weapons_engine.json` (and the raw `gameplay/weapons.json`).

### 4.1 Effect bitmaps
* Each effect DTS is a `cell_anim_part` of `bitmap_part`s: frame i = bitmap `bmp_tag` of the DBA, hotspot
  `(xo, yo)` (signed bytes) on the part centre, `radius` in units.
* TSBitmapPart render (0x30c4c): one bitmap pixel = `radius / 64` units → the sprite's
  `frame_metres_per_pixel[i]` (varies per frame; `metres_per_pixel` = the largest-frame value).
* Opaque 8-bit blit, palette index 0 transparent, no blending (`blend: alpha` = cutout).
* PLASMBAL: 21 frames = 3 phases × 7; frame = (t/100 ms) % 7 + 7·min(2, ⌊3t/lifetime⌋) (0xdd81;
  sprite `phases` / `phase_frames`).

### 4.2 Explosions (table 0x762a8, 0x2c bytes per type)
`{sound id, light intensity, light inner radius, light outer radius, shape count, shape-name list}`.
* Ctor 0x11358 picks one shape at random (0x114d9); one frame per 25 ticks = 100 ms (0x1173e); the explosion
  dies after its last frame.
* Light (only explosions emit light): intensity fades linearly as 127·(n−f)/n; full inside the inner radius,
  zero at the outer one.
* Effects `expl<type>_<SHAPE>`: one per (type, shape); an impact list holds the variants.

| caller | type | used for |
|---|---|---|
| laser 0xc061 / 0xc485 | 4 | beam end (hit or not) |
| blaster 0xd4f2 / 0xd553 | 5 | bolt hit / expiry |
| canon 0x1123e / 0x1129b | 6 | shell hit (laser hit sprites) |
| plasma 0xe035, missile 0xfa65 | 1 | ball / missile detonation |
| missile 0xfa65 (altitude ≤ 0), mine 0x1064c | 7 | floor blast (SHROOM) |
| Herc shield absorb 0x80cc | 3 | shield flash (SHLDHIT2) |

Types 0 and 2 are not spawned. The explosion sits at the collision point (record +0x1c), or at the projectile
position when nothing was hit.

### 4.3 Shield hits
Event 0x68 → 0x80cc(hit point): when the shield lost > 15 points (0x8125), a type 3 explosion is spawned at the
hit point. The projectile's own explosion still plays → `shield_<expl effect>` = SHLDHIT2 layer + the class
explosion. Mines bypass shields (their shield list = armour list).

### 4.4 Laser beam (render 0xc738)
Flat screen-space quad from muzzle to beam end. Half width = class row beam radius (units), projected and capped
at that many pixels (`max_half_width_px`). Detail ≥ 2 (0xc9be): half-width core in the palette colour at 0xcb74
(`core_color`, `core_width_ratio`), plus full-width side strips in the colour at 0xca4c; low detail: one quad in
the colour at 0xc9ce. Visible 0x1e ticks (120 ms). No texture. The beams are green.

### 4.5 Projectiles, muzzle, trail
* Blaster / canon / missile / mine fly their polygon shapes (`bd:BLASTER`, `bd:CANON`, `bd:MISSILE`, `bd:MINE`);
  plasma is the PLASMBAL billboard.
* The mine spins about the vertical axis: +0x200 / 65536 turn per mine update (0x1044a; `spin_dps` [0, y, 0]).
* No trails, no projectile lights, no muzzle flashes.
* Pod firing feedback = the pod cell state: 0 idle, 1–4 one per 100 ms after a shot, +6 damaged, 12 destroyed
  (0x7904; `fx.pod_cell_states`, played by `FxPodCells`).

## 5. Starsiege

Exporter: `tools/fx_starsiege.py` (shared Darkstar logic `tools/fx_darkstar.py`), importer step `weapon_fx`.

**Sources** (`starsiege/extracted`): `scripts/datProjectile.cs` tables `newBullet / newMissile / NewEnergy /
NewBeam / newMine / newBomb` (columns per the header comment above each table: Shape, Transparent Shape, Glow
Range + RGB, energy Face Camera, beam Length / Seg Length / Jitter / Velocity / Near + Far Width / Bitmap + Trans
Bitmap / Glow RGB / Alpha, ImpactId, Shield ImpactId, TerrainImpactId); `scripts/datWeapon.cs`
`weaponMuzzle(shape, trans shape, face camera, flash RGB, flash range)` and `weaponEnergy/weaponAmmo` (projectile
id); `scripts/Sim.Strings.cs` `IDDTS_<X> = id, "<file>.dts"` (`IDDTS_<X>_T` = translucent variant);
`gameObjects/*.dts|*.bmp`; palette world `Mars.Sim/Mars.d.ppl`.

**Effect shapes → sprites.** Every impact / explosion / shield flash / muzzle / smoke is a 3Space shape (quads,
discs, domes) animated by its first sequence (Darkstar shape rules: §6). The exporter evaluates the sequence at
its keyframe rate (≤ 40 frames), rasterises it face-on (looking along the shape's thinnest axis) into RGBA frames
(`fx/sprites/<dts stem>/`), `fps` = frames / sequence duration, `metres_per_pixel` from the geometry (1 unit =
1 m). The translucent `*T.dts` variant is drawn. Effect names = IDDTS tag without `IDDTS_`, lower case
(`imp_sm`, `shield_eng`, `exp_l`, `smoke_tr`, `dust`); muzzles `muzzle_<dts>_<rrggbb>`.

**Per weapon** (`ss_id` → datWeapon id → projectile id):

| projectile class | fx |
|---|---|
| bullet, missile, mine, bomb, energy with Face Camera F | `projectile.shape` = `starsiege:<trans shape stem>`, face `velocity` |
| energy with Face Camera T | `projectile.sprite` = flipbook of the trans shape, face `billboard`, loops |
| beam | `beam`: texture = Trans Bitmap (`fx/textures/beam_<abbr>.png`, length along V), `color` = glow RGB + Alpha, `width` / `width_far` = near / far width, `length`, `speed`, `segment_length`, `jitter`, style `bolt` (`lightning` when jitter > 0) |

* `projectile.light` = glow range + colour (none when range 0 or black). Missiles: `trail` puffs of `smoke_tr`.
* `muzzle` = weaponMuzzle shape flipbook + light (flash colour / range, sequence duration).
* `impact.armor` = ImpactId, `impact.shield` = Shield ImpactId, `impact.miss` = TerrainImpactId when present,
  `dust` (fx_dust puff) when it is `none`, else ImpactId.
* Stand-ins: `IDDTS_IMP_BULLET` names no file → `imp_tn` art; a missing shape (`fx_imp_lg`) falls back to the next
  smaller size of its family drawn ×1.5 (layer `size`). Both are recorded in the effect `source`.

## 6. Tribes

Exporter: `tools/fx_tribes.py` (+ `tools/fx_darkstar.py`), importer step `weapon_fx`. Sources (`tribes/extracted`):
`scripts/baseProjData.cs`, `scripts/baseExpData.cs`, `scripts/item.cs`, `scripts/nsound.cs`, `Entities/*.dts|*.bmp`,
palette world `lushWorld/lush.day.ppl` (entity palette ids are shared by all worlds).

**Darkstar effect shapes** (also Starsiege). Sequence 0 animates: IFL subsequences (`first_ifl .. +n_ifl`; key
value = material index replacing material slot `mat & 0xFFF`), object subsequences (key value = mesh frame), node
subsequences (key value = transform). Keyframe flag nibble = top 4 bits of the material word (v7 u32, v8 u16): 0x1
frame matters, 0x4 visibility matters, 0x8 visible. Bitmap blend = type of the palette its PiDX selects in the PPL:
5/6 additive, 2 translucent (4th palette byte = alpha), 7/8 subtractive (dark alpha), other opaque with index 0
transparent. Additive sprites/textures are stored straight-alpha with alpha = brightest channel, so rgb × alpha =
the light the original adds.

**Library.** One effect per ExplosionData (name kept, e.g. `rocketExp`): layer = flipbook of `shapeName`, `duration`
= sequence duration × `timeScale`, `face` camera/surface (`faceCamera`), `random_spin`, `shift_toward_camera`
(`shiftPosition`); `light` (if `hasLight`): `curve` keys colors[0] at 0, colors[1] at `timeZero`, colors[2] at
`timeOne` with range `lightRange × radFactors[i]`; `color` / `range` = the peak key. `sound` = soundId → nsound.cs
wavFileName. `<exp>_shielded` = the explosion + the ShieldPack flash (`shield.dts`, GameBase::activateShield).

**Per weapon:**

| class | fx |
|---|---|
| BulletData isVisible | `projectile.sprite` = bulletShapeName flipbook, billboard, `spin_dps` = 360 / rotationPeriod |
| BulletData not visible | `projectile.shape` `tribes:tracer`, face velocity, `tracer_length` = tracerLength |
| RocketData / GrenadeData | `projectile.shape` = `tribes:<bulletShapeName stem>` |
| LaserData | `beam` textured: laserBitmapName (length along U), duration beamTime; impact = hitName flipbook |
| LightningData | `beam` style `lightning`: bitmapName (length along V), width beamWidth, `length` boltLength, `lightning {cone_deg, segments, divisions, update_s, skip, displace}` |

* `projectile.light` = lightRange / lightColor. Impacts: explosionTag; with `expRandCycle` n the tag's trailing digit
  runs 0..n-1 (random pick). miss = armor = the explosions; shield = `<exp>_shielded`.
* Trails: trailType 2 → puffs of `trailString` every smokeDist / speed s; GrenadeData → puffs of `smokeName` every
  `projSpecialTime` s; trailType 1 → `ribbon` (width trailWidth, lifetime trailLength / speed, light colour).
* Muzzle: ItemImageData lightType 3 → `muzzle_<image>` light-only flash (lightRadius / lightColor).

## 7. Tribes 2

Source: TorqueScript datablocks (`scripts/weapons/*.cs`, `scripts/vehicles/*.cs`), bitmaps (`textures/<name>.png`),
IFL frame lists, shapes (explosion / bolt / weapon shapes). Exporter: `tools/fx_tribes2.py` (+ `fx_tribes2_effects.py`,
`fx_tribes2_torque.py`). Names: effects = datablock name (`DiscExplosion`, `<Image>_MUZZLE`, `<Projectile>_IMPACT`,
`<effect>_SHIELDED`, `<Emitter>_<n>ms`); sprites = texture base name, `_alpha` suffix when alpha-blended.

### 7.1 Weapon → look
Image datablock (`projectile`) → projectile class:

| class | fx block |
|---|---|
| TracerProjectileData | projectile.sprite = tracerTex[0], size = tracerWidth, `length` = tracerLength, `min_pixels`, `cross` {sprite tracerTex[1], size crossSize, view_cos crossViewAng}, face velocity |
| EnergyProjectileData | sprite texture[0], size = scale.x, length = scale.y, `cross` (texture[1]); trail ribbon = blurColor/blurWidth/blurLifetime |
| LinearFlareProjectileData | sprite flareBaseTexture, size = 2·size[0], color flareColor, `flare` {base, mod, count numFlares, sizes size[], color}; an IFL-textured bolt shape replaces the sprite |
| Linear / Grenade / Seeker / Bomb | shape `tribes2:<projectileShapeName>` (grenade / mortar DTS v18, missile v19, disc, bomb) with `sequences: cyclic` (the shell's cyclic `ambient` spin / wobble loops in flight); trail = baseEmitter puffs |
| Sniper / ShockLance / ELF | projectile null; `beam` (7.3) |

`projectile.light` = hasLight ? {lightColor, lightRadius} : null.

### 7.2 Effects
* ParticleEmitter + ParticleData → `particles` layer: count = burst (particleDensity) or emit time / ejectionPeriodMS
  (cap 250); speed/speed_variance = ejectionVelocity/velocityVariance; spread_deg/theta_min_deg = thetaMax/thetaMin;
  offset = ejectionOffset; radius = particleRadius; lifetime(+_variance); size/color = key 0, size_end/color_end =
  value at t = 1; full `keys` {times, colors, sizes}; gravity = −9.81 × gravityCoefficient; drag = dragCoefficient;
  accel = constantAcceleration; spin_dps [min, max]; orient = orientParticles; emit_time (0 = burst); blend additive
  unless useInvAlpha.
* ExplosionData → layers: explosion shape as an IFL sprite (size = fireball frame-0 extent × sizes[0] ×
  explosionScale, grow = mesh growth × sizes[last]/sizes[0], duration = ambient sequence / playSpeed, face
  camera|normal, offset_random); particleEmitter burst; emitter[]; debris → particles of the debris trail emitter;
  shockwave → `ring` {radius_start, velocity, acceleration, width, height, segments = numSegments, tex_wrap =
  texWrap, times, colors, orient_to_normal} (+ a `flash` for engines without rings); subExplosion[] flattened
  with delay = delayMS. Explosion shapes of every DTS version on the disc are read (disc_explosion is v18): the
  fireball size and growth come from its mesh frames. `sound` = soundProfile wav;
  `shake` {frequency, amplitude, duration, radius}. IFL unit = 1/30 s.
* SplashData → emitter layers + ring (+ its explosion). ShieldImpactData → sprite `shieldenvmap` with `shell`
  {scale_start, scale_end}, duration lifetimeMS.

### 7.3 Beams
* Sniper: texture = textureName[1], `frames` [2..n−2], `ramp` last, `flare` {textureName[0], angle, min/max size},
  width → width_end, pulse_*, duration = fadeTime, light.
* Shock lance: texture[0..2] lightning `frames`, `core_texture` texture[3], width/width_end, length boltLength,
  bolt_speed, tex_wrap, `lightning`; duration zapDuration.
* ELF: texture textures[0], lightning_texture textures[1], `continuous`, range, scroll_speed, repeat,
  control_points, physics; impact sprite textures[2].

### 7.4 Impacts / muzzle
miss = armor = [explosion] (beams without one: `<proj>_IMPACT`); shield = [`<hit>_SHIELDED`] (hit + shield flash);
water = [splash] else underwaterExplosion. Muzzle = the weapon shape's flash meshes (front flash material / IFL,
size = flash mesh extent, duration Fire_Vis/Fire sequence) or the missile exhaustEmitter for exhaustTimeMs.

## 8. Engine (game/engine/fx)

| script | role |
|---|---|
| `FxLibrary` | loads `fx/effects.json` per pack; sprite frames to textures (indexed frames expanded through their palette with the remake's CRT gamma, `DisplaySettings`, cached per palette and gamma); the battle's world palette per pack (`set_world_palette`, from Battle `_build_world`): `palette_per_world` sprites / beams and every `palette_index` colour use it; beam textures; the weapon's `fx` block (`weapon_fx`), or a generic look marked `fallback` for data-less weapons |
| `FxPlayer` (`Effects.fx`) | plays library effects (sprite / particles / flash / shape layers, light, sound), random impact variant per surface, beams, muzzle flashes, trail puffs; pools sprites, caps live sprites / particle bursts / lights for 24-player battles |
| `FxSprite` | animated camera-facing bitmap, anchored at the frame's origin pixel, sized by `metres_per_pixel` or the layer `size`, alpha or additive, grow / rise / fade |
| `FxBeam` | beam strip turned about its axis toward the camera: original bitmap (repeated along), soft core, or a travelling bolt |
| `FxParticles` | CPU particle burst (headless-safe) from a `particles` block |
| `FxProjectileLook` | the projectile in flight: shape (with roll; `sequences: cyclic` loops the shape's cyclic sequences), looping sprite, velocity streak or glow, carried light, trail |
| `FxRing` | Torque shockwave / splash ring: an expanding textured band of `segments` quads, colours keyed over its life, additive |
| `FxPodCells` | Battledrome pod firing cell states (`pod_cells` of the hardpoint) after a shot |
| `FxSurface` | picks `miss` / `shield` / `armor` from the collider before the damage lands (`shield_bank_at`) |
| `DeathFx` | plays a pack's death entry (section 9) for a unit, component, structure, turret or soldier; the generic explosion (`Effects.explosion`, counted in `Effects.fx.generic_explosions`) only for an import without the `deaths` block |

* **Where effects are triggered.** `Weapon` (all vehicle, turret and infantry weapons) sends beams through the
  battle fx channel with the weapon id and the surface hit (`BattleFx`: beam, muzzle and impact play on every
  peer); projectiles go through the existing `projectile` fx message, on which every peer plays the muzzle
  flash and clients spawn their visual copy. Each peer's projectile copy plays its own impact (no extra traffic).
* **Cross-game weapons** keep their own game's look: names resolve in the weapon's own pack
  (`FxLibrary.weapon_pack`), whatever Herc carries it.
* **Sounds**: an impact effect with a sound of its own replaces the weapon's generic `sounds.hit`.
* Tests: `tests/weapon_fx_check.tscn` (headless: data, variants, spawning, caps) and
  `tests/weapon_fx_sheet.tscn` (window: contact sheets `renders/weapon_fx_<pack>_*.png`); deaths:
  `tests/death_fx_check.tscn` (headless) and `tests/death_fx_sheet.tscn` (window: `renders/death_fx_<pack>.png`).
* **Sprite facing.** `face: ground` lies flat on the ground (a shape whose thinnest axis is up, Darkstar
  `Flipbook.is_ground_flat`: Starsiege fx_shock_md); `face: surface` (Darkstar ExplosionData faceCamera false: the
  Tribes Shockwave rings) lies across the impact normal (up for deaths). Other faces are camera-facing.

**Data keys the engine honours beyond 1.1/1.2**: sprite `frame_metres_per_pixel`, `phases` / `phase_frames`
(BD plasma ball, phase from the projectile lifetime); light `energy` + `frame_s` (ES1 per-frame intensity);
shape layer `cells_per_frame`; layer `offset_random`; particle `speed_variance`, `lifetime_variance`, `radius`,
`spin_dps` [min, max], `emit_time`, `keys`; projectile `spin_dps` as [x, y, z] (BD mine yaw), `length` + `cross`
(Torque tracers / energy bolts: textured streak, cross bitmap when seen end-on); beam `core_color` /
`core_width_ratio` / `max_half_width_px` (BD), `jagged` / `style: lightning` (ES1/ES2/Starsiege/Tribes zig-zag,
re-randomised per shot), `texture_axis: across` / `texture_length_axis: V`, `width_end` / `width_far`,
`length` + `speed` (Starsiege travelling bolt), `blend`, `fade`.

Also honoured: light `range_follows_energy` (ES1/ES2 radius ∝ intensity); layer `ring` (FxRing); beam `frames`
(T2 shock lance lightning frames replace the texture; sniper laser rips play on an additive overlay strip; each
frame once over the beam's life), `bolt_speed[0]` (texture scroll), `stretch` (ES2 BEAMTEX once along the beam),
`stipple` (ES2 ELF, half alpha); projectile `sequences: cyclic`.

**Approximations in the engine**: `face: normal/muzzle` layers are drawn camera-facing; Torque `shell`
(T2 draws the hit object's own shape scaled up with the shield env-map; the effect only knows the hit point, so a
billboard), `shake`, `flare.mod` quads (the plasma bolt's 35 rotating mod flares: their rotation and size rules
are engine code, not data), ELF control-point physics (spring factors exported, beam drawn straight), sniper
`ramp` (role unknown), shock lance `boltSpeed[1]` and per-bolt widths, ring `verticalCurve` / `numVertSegments`,
Tribes `light.curve` and BD light `inner_range` fall back to the simpler keys; ES1/ES2 light falloff is Godot's
omni attenuation over `range` instead of the original 1/d; ribbon trails are dense puffs; ES1 `armor_light` (armour hit without an
integrity step) plays the `armor` list; theta_min of particle cones is ignored; BD missiles pick SHROOM or the
airburst at random instead of by altitude; pod cell states play only where the weapon is simulated (host).

## 9. Death effects (all packs)

Exporter: `tools/fx_deaths.py`, called by each `fx_<pack>.py` after its library is built; the steps name the pack's
own effects (the exporter fails on an unknown one). Engine: `DeathFx` (`game/engine/fx/death_fx.gd`), looked up by
`FxLibrary.death(pack, kind, keys)`: the kind's per-key map (`vehicles`: vehicle id, then class), else its default.

```json
"deaths": {
  "vehicle": {"steps": [step], "source": "evidence"},   "vehicles": {"<vehicle id or class>": {...}},
  "component": {...}, "component_big": {...},           "structure": {...}, "structures": {"<tag>": {...}},
  "turret": {...},    "infantry": {...}
}
step = {"effects": ["<effect>", "..."],  // one picked at random per count
        "delay": 0.0, "count": 1, "interval": 0.0,   // s
        "scatter": 0.0,   // 0..1 of the body's half width (random point; up to half the height above `height`)
        "height": 0.5}    // 0..1 of the body height above its feet / base
```

| pack | unit | component | structure | turret | soldier |
|---|---|---|---|---|---|
| ES1 | explo_17 | explo_10; explo_17 for DMG flag 4 | 6 x explo_15 at random points every 0x12c timer units, then explo_16 | - | - |
| ES2 | explo_17 | explo_10; explo_17 for flag 4 | explo_16 at the base's foot (table 0x4973fc[class 0]) | - | - |
| Battledrome | explodePart: expl1 (EXPLD1 / EXPLD2) + 2 more around it | expl1 | (no destructible obstacles) | expl1 | - |
| Starsiege | exp_l + shock_m (on the ground) + 3 debris exp_l | - | the record's explosion tag (`structures`: IDDTS_EXP_S / M / L) | the record's tag | - |
| Tribes | FlierData explosionId flashExpLarge + 3 flashDebrisLarge spawnedExplosionID | - | Generator: flashExpLarge + debris | PlasmaTurret: LargeShockwave + debrisExpMedium | nothing |
| Tribes 2 | VehicleData `explosion`: Shrike / Wildcat VehicleExplosion, Havoc / Thundersword LargeAirVehicleExplosion, Beowulf / Jericho LargeGroundVehicleExplosion | - | GeneratorLarge ShapeExplosion | TurretBaseLarge TurretExplosion | nothing |

**Earthsiege 1 (DBSIM).** No explosion belongs to the unit itself: a mech dies when a cockpit component is destroyed
(0x13824), and damage.cpp 0x9cd4 spawns, for every component the hit destroys, its debris (flag 2) and explosion 10 at
the part (0x9e40), or explosion 17 when the component has flag 4 (0x9e59; the cockpits: DMG flags 7). After a big one
the global 0xaf140 silences the rest of that damage application (reset per hit at 0x9ff2). The remake plays
`component` / `component_big` when an engine component reaches 0 hp (host, and puppets from the damage block), and
the `vehicle` entry on death unless a big component blast already played in that hit. Bases (base.cpp 0x2df8): the
counter set to 8 at destruction (0x3a43) counts down on a timer: explosion 15 at a random point of the BASES.DAT
extents every 0x12c units while above 1, explosion 16 at the centre at 1, the hulk shape 0x7d0 units later (the
remake swaps the shape at once). Unit field 0x48 is the leg count (pre-damage, gameplay.md), not an explosion class.

**Earthsiege 2 (DBSIM 1.0).** The same component rule (0x40d6e2: 10, flag 4 -> 17, global 0x4a98b0). Bases
(0x4036c0) explode with table 0x4973fc[class] = 16 / 21; the base record class (+0x10) is not exported, class 0 used.

**Battledrome (SIM).** Herc::explodePart (herc.cpp 0xad8c, cascade 0xabf4) throws a part's debris and spawns an
explosion of type 1 (0xaf3b, EXPLD1 / EXPLD2 at random) with sound 6; a destroyed turret (turret.cpp 0x1537e) a type 1
explosion with sound 7. The engine catalog has no BD components, so a death plays three part explosions. The SHROOM
(type 7) is a missile floor hit / mine blast only (section 4.2), never a death.

**Starsiege (Starsiege.exe).** The Herc death code (0x472f80) blows the vehicle into debris pieces (tables
IDDEF_HERC_*_DEBRIS at 0x6c5b20..) that carry explosion tag IDDTS_EXP_L (0x47303b) or IDDTS_SHOCK_M (+0x4f) - chosen by
a flag (vehicle data +0x111 or the controlled object) not decoded, so both play; the quick death path (0x4739bc) uses
IDDTS_SHOCK_M. Static shapes and turrets carry their own explosion tag in the mission record (starsiege_mis.py
`explosion_tag`: EXP_L 761, EXP_S 83, EXP_M 54 records), keyed in `structures` by tag id.

**Tribes.** Vehicle.cs FlierData `explosionId` / `debrisId` (the debris pieces explode their `spawnedExplosionID`
when they come to rest: played around the wreck), turret.cs / staticshape.cs / station.cs the same per datablock.
**Tribes 2.** VehicleData / TurretData / StaticShapeData `explosion`. Soldiers: section 6 of tribes_infantry.md.

Approximations: debris pieces are not simulated (their explosions play around the wreck, `scatter`); one entry per
kind for structures / turrets of Tribes and Tribes 2 (the remake builds none of their static shapes in battle yet);
the ES1 base blast scatters over the shape's bounds, not the BASES.DAT extents.
