# Battledrome weapons, damage model, arm pods and loadouts

Tool: `python tools/export_bd_weapons.py` (also the last step of `tools/import_disc.py` when `bd/installed/` and
`gamedata/bd/shapes/` exist). It writes:

* `gamedata/bd/gameplay/weapons_engine.json`: the 33 sold weapons plus the arena blaster turret, in the
  `weapon_schema.md` format. Each entry also has a `native` block with the raw record and class row, `hit_shapes`,
  and notes.
* `gamedata/bd/gameplay/loadouts.json`: `{<HERC shape>: [weapon per hardpoint], pods: {...}, meta: {...}}`.
* `gamedata/bd/audio/sfx/<stem>.wav`: every `SOUND/*.RAW` and `*.SFX`, as 8-bit 11025 Hz PCM.
* A `sprite` key added to the bitmap effect shapes in `gamedata/bd/shapes/`: BLASTHIT, EXPLD1/2, LSRHIT,
  PLASMBAL, RDLASER, SHIELD1, SHLDHIT2 and SHROOM. These DTS files are `cell_anim_part`s of `bitmap_part`
  frames, so `shape_to_json` exported them with no polygons.

All addresses are SIM.EXE VAs (file offset − 0x69CD). The tool checks the instruction bytes it relies on
(`EVIDENCE`) before it exports anything.

Units:
- 1 sim tick = 4 ms. Hercs charge and fire in their 100 ms update.
- Speed = units per 256 ticks (1.024 s), because positions integrate `v·dt>>8`.
- Distances use the shared world scale of 0.00215 m per unit.

## 1. Pipeline

`Herc::update` (every 100 ms) runs two steps:
1. Capacitor charge (`0x95bc`).
2. Firing (`0x970c`). This fires every mount in the active trigger group whose `canFire` (`0x98e8`) passes. For the selected weapon, a tap fires it once; after the trigger has been held for 256 ms, the selection chains to the next ready weapon.

A trigger press (event 0x65) also fires immediately.

`canFire` checks two things:
- The pod is not destroyed, and `now − lastFire[mount] > refire`. The test is strict, so the sustained rate is quantised up to the 100 ms tick.
- Energy weapons need charge ≥ `min`. Other weapons need ammo > 0.

`Herc::firePodWeapon` (`0x9bbc`) then does the following:
- A pod damaged by more than 100/256 can misfire: chance = damage/4 out of 256, and it plays sound 0.
- The amount fired is `min(per_shot, charge or ammo)`, which is subtracted from the charge or ammo.
- The class constructor is called through the jump table at `0x75200`, and the class fire sound plays.
- Pods aim at the locked target (`0x9fb0`, convergence). The mine pod does not.

### Weapon record (33 × 0x7C at `0x80BE4`, index = weapon id used in Herc configs)

| off | field |
|---|---|
| +00 | class: 0 laser, 1 blaster, 2 plasma, 3 autocannon ("CANON"), 4 missile launcher, 5 mine launcher |
| +04 | energy draw divisor d. Values: laser 10, blaster 20, plasma 40. 0 = ammo weapon |
| +08 | charge lost per update when the weapon gets no power |
| +0C | refire (ticks) |
| +10 | 5 for energy weapons, otherwise 0. Use not traced |
| +14 | minimum charge (or rounds) to fire |
| +18 | capacitor size, or ammo capacity |
| +1C | charge (or rounds) used per shot |
| +20..+44 | allowed on Herc 0..9 |
| +48/+4C/+50 | fits LIGHT / MEDIUM / HEAVY BAY |
| +54 / +58 | MINE LNCHR / MSL LNCHR |
| +5C | price |
| +60 | ammo price (cannon 30–120, launchers 1000–2500; meaning inferred) |
| +64 | mass. Always 0 (`0x44c08` adds it to the Herc mass) |
| +68 | name |

Launchers come in two records with the same name. They differ only in ammo and in the Hercs allowed, so the size of the rack depends on the Herc. The exporter keys them `NAME_<ammo>`, for example `MOSQUITO_15` and `MOSQUITO_30`.

### Capacitor (energy weapons, `0x95bc`)

The reactor and weapon power are computed as follows:
- Reactor output comes from a 4-point table over power-plant damage. For example, 1.2TW gives (0,1200) (100,500) (200,400) (256,0).
- The output is split 0x58/256 to the engine, 0x54/256 to the shield and 0x54/256 to the weapons (`0x70da`). The split is stored per Herc at +0x201/+0x205/+0x209.

Each update, every weapon gains `((P_weapons / n + d/2) / d) · (256 − pod damage) / 256`. Here n is the number of non-mine weapons. The charge is capped at +18. With no power, the charge falls by +08 per update.

Damage of a shot equals the charge it spends. This means a half-charged shot does half damage.

## 2. Weapon classes (class rows indexed by weapon id)

| class | constructor | row table | row fields |
|---|---|---|---|
| laser | `0xb844` | `0x75404`+0x14·i | range, beam radius, splash radius, damage shift, – |
| blaster | `0xcc1c` | `0x7557c`+0x14·i | speed, radius, splash radius, damage shift, shape (`dts\blaster.dts`) |
| plasma | `0xd610` | `0x75658`+0x18·i | speed, radius, splash radius, damage divisor, decay per 1.024 s, shape (`plasmbal`) |
| autocannon | `0x107dc` | `0x75f90`+0x18·i | speed, radius, splash radius, **damage**, (unused), shape (`dts\canon.dts`) |
| missile | `0xe8d8` | `0x7556c`+0x3c·i | lifetime, impact mass, radius, seeker half-angle, max thrust, max lateral accel, launch speed, cruise speed, cruise altitude (+rand 1500), proximity, dive distance, shield-detonate threshold, blast radius, damage, shape |
| mine | `0xfb34` | `0x75b54`+0x2c·i | max speed, chase speed, hover height, drop speed, trigger distance, scan every N updates, detect radius, blast radius, damage, update ticks, shape |

### Projectile behaviour

All projectiles die on leaving the floor/ceiling band and fly straight with no gravity, except where noted.

| class | behaviour |
|---|---|
| Laser | Instant ray of 100 000 units (215 m). Visible for 0x1e ticks (120 ms). |
| Blaster bolt | Lives 0x400 ticks (4.1 s). |
| Canon shell | Lives 0x300 ticks (3.1 s). |
| Plasma ball | Starts with damage = charge. Loses `decay` per 1.024 s and dies at 0. Lifetime = charge·256/decay ticks. |
| Missile | Seeks the firing Herc's target (`Herc+0x17c`). See the steering rules below. |
| Mine | Ejected backwards at 16 000 u/1.024 s plus the Herc's velocity. See the mine rules below. |

Missile steering (`0xf238`):
- The missile starts at 5000 u/1.024 s plus the Herc's velocity.
- Thrust is capped at the max thrust, toward the cruise speed.
- While the target is inside ±seeker half-angle, the lateral command is `4·v·sin(angle)`, clamped to the max lateral accel. Outside that cone the missile flies straight.
- Until it is within the dive distance, it holds the cruise altitude (4500–6000 + rand(1500) units, at most 3/4 of the ceiling).
- Fuse: it detonates when closer than proximity/4, or when closer than proximity and the distance is growing.
- Lifetime is 1536 ticks (6.1 s).

Mine rules (`0x104b8`, `0x1018c`):
- After launch the mine stops, hovers at 500 units and spins.
- Every N updates it scans the detect radius for Hercs, turrets and probes of the other side.
- If one is closer than the trigger distance, the mine explodes. Otherwise a chasing mine (BLOODHND, PITBULL) steers toward the nearest one, with speed clamped to the range [chase/8, max speed]. GATOR never moves.
- The mine also explodes when shot. It has no lifetime.
- For the first 6.1 s it is shown on radar (`0xffba`).

## 3. Weapon list (`weapons_engine.json`; damage already in ES1 points, see §5)

Bays are L/M/H. "Refire" is the effective value after the 100 ms quantisation.

| weapon | bays | price | dmg/shot (BD) | ES1 shield / armour | refire s | speed m/s | range m | capacitor min / per shot / cap | ammo |
|---|---|---|---|---|---|---|---|---|---|
| LASER 1–3 | L M H | 10–12k | 100/125/140 | =dmg / dmg·0.5 | 0.5 | beam | 215 | 20–50 / 100–140 / 200–400 | – |
| CANON 1–2 / 3–4 / 5 | LMH / MH / H | 10–14k | 100/130/170/200/230 | dmg/4 / dmg·0.5 | 0.3 (C5 0.4) | 210 | 645 | – | 200/180/160/140/120 |
| MOSQUITO | MSL | 20k | 250 area | 125 / 125 | 1.3 | 189 | 1161 | turn 6°/s, seeker ±77° | 15 or 30 |

Example rows only. The full table for every weapon is written at import by `tools/export_bd_weapons.py` to
`gamedata/bd/gameplay/weapons_engine.json` (fields per weapon_schema.md; the BD values are kept in each
weapon's `native` block).

Each missile has a cruise speed and a lateral-accel cap (MOSQUITO: 90 000 u/1.024 s and 10 000). The missile "range" is speed × lifetime. Arenas are only 140–430 m across at this scale.

Splash radii:

| weapon | splash radius |
|---|---|
| blaster | 1000 u (2.2 m) |
| missile | 7000 u (15 m) |

Example rows; every weapon's splash radius is in the same `weapons_engine.json` (`tools/export_bd_weapons.py`).

The blaster turret (`turret.cpp`, `0x15b34`) fires two BLASTER 2 bolts with charge 200 every 7 updates. It runs in on-phases that toggle every 20–39 updates. Its bolts have no owner side. Arenas place turrets as hazards.

There is no heat model, no EMP, no ECM and no ELF in Battledrome. Ammo weapons have no mass; ammo is bought in the hangar.

## 4. Damage model (Herc events, `0x7294` table `0x750c0`)

### Shield (Herc+0x2bf)

Projectiles that enter the shield sphere get event 0x68 with the shield value S. The result depends on the class:

| class | shield interaction |
|---|---|
| laser | Shield absorbs min(S, d) at 1:1. The beam stops if the shield holds. |
| blaster | Shield absorbs min(S, ¾d) at 1:1. At least ¼ always leaks through. |
| canon | Shield absorbs min(⅞d, 4S) and loses 1 point per 4 damage absorbed. At least ⅛ always gets through. |
| plasma | Shield absorbs min(S, d) at 1:1. |
| missile | If S > 200, the missile detonates on the shield at half damage and drains dmg/8. |
| area damage (part −1) | Shield absorbs 2 damage per point (`0x80cb`). |
| mine damage (part −2) | Bypasses the shield. |

Shield regeneration follows a 4-point table of shield power. Shield power = reactor × 0x54/256. For SG I the table is (0,0) (500,4) (1000,12) (5000,30) points per 100 ms, and the shield is capped at SG points (3000…5500).

### Direct hit on a logical part (event 0x67 with part ≥ 0)

- ¾ of the damage goes to that part (`0xa907`).
- ¼ is spread over every installed logical part within the splash radius, with linear falloff (`0xa76d` → `0xa89b`).

Area damage (plasma remainder, missiles, mines) uses only the radial spread, with the full damage applied **to every part** in range. A missile therefore damages most of a Herc's parts at once.

Part armour comes from the ARMOR record. ARMOR1–12 give 400…4800 per part, with 0 for parts that have no armour.

When a part's armour overflows, the excess passes to its internal links (`0xabf3`, Herc record +0x140/+0x144 tables). Logical part 0 or 3 gone sets Herc+0x173 (`0xb4f4`, most likely the destroyed flag).

Pods (parts 11–17) can be destroyed. A destroyed pod's cell shows state 12. Pod damage also scales charging and causes misfires.

Herc logical parts (26 slots):
- The SIM name table at `0x80648` is offset by 3: TORSO = 3 … POD 1–4 = 11–14, MINE POD 15, MISSILE P1/P2 16/17, ENGINE 19, (20 = cfg+0xdc), SHIELD 21, POWER PLANT 22.
- The DCS logical-part table (§6) uses the same indices.

## 5. Damage conversion to the Earthsiege scale

Battledrome armour is per logical part: ARMOR1–12 give 400–4800 points per part. ES1 components have 300–2500 hp.

Battledrome shields have 3000–5500 points (SG I–VI), and area damage costs 1 shield point per 2 damage. The ES1 Herc shield is 3500.

A single factor keeps every BD time-to-kill ratio:

* **armour damage = BD damage × 0.5**, with BD part armour × 0.5 (200–2400 ≈ ES1 component range).
* **shield points map 1:1** (SG points = ES1 shield points). `damage.shield` is the number of shield points one hit removes from a shield that is not saturated:

  | weapon | `damage.shield` |
  |---|---|
  | laser, blaster, plasma | d |
  | canon | d/4 |
  | missile (area 2:1) | d/2 |
  | mine | 0 |

  The pattern matches ES1's own profiles: lasers do high shield damage and moderate armour damage, while the ATC does low shield damage and high armour damage.

Example: a Talon with ARMOR6 (2400/part, 1200 ES1) and SG IV (4500) hit by LASER 5:
- The shield takes 170 per shot, so it falls in 27 shots (≈16 s at the 0.6 s refire, if charge allows).
- A part then takes 85 ES1 points per hit (BD 170 vs 2400): about 14 more hits.

The ratios are identical in both scales. Behaviour that the ES1 rules cannot express (shield leaks, area damage to every part) is kept in each weapon's notes and its `native` block.

## 6. Arm pods, hardpoints and muzzles

Herc record (`0x82ffc` + 0x364·k), mounts at **+0x68: 7 × {bay, cell slot, muzzle x, y, z}**:
- Slots are POD 1, POD 2, POD 3, POD 4, MINE POD, MISSILE P1, MISSILE P2.
- Bay values: 0 LIGHT BAY, 1 MEDIUM BAY, 2 HEAVY BAY, 3 MINE LNCHR, 4 MSL LNCHR, −1 none.

The muzzle is computed as follows (`0x9fb0`, `0x43f78`):
- Muzzle position = logical-part transform × (0, y, 0). The forward offset y is 500–1700 units.
- The logical part comes from the DCS trailer. `DCShape::read` (`0x44848`) reads, after the collision table and the shape:
  - `i32 sphere[4], i32 (0/5000)`
  - `u32 nA, nB, nC, nL`, `u16 nE`
  - `nA×u32`, `nA×u16`, `nB×u32`
  - `nC×{u16,u16,u16}` cell sequence rows
  - **`nL × {i32 ?, i32 node, i32 x, y, z}` logical parts**
  - `nE×u16`
- The table parses with 0 bytes left over for all Hercs.
- Hardpoint i uses logical part 11 + i. Default node rotations are 0, so the hardpoint position is node origin + offset.

**Pod cells.** The Herc shapes have no per-weapon models. Each bay hardpoint names a cell anim slot (0–3). That slot's cell_anim_parts have 13 states, selected in render prep (`0x7904`):
- state 0: idle
- states 1–4: firing animation, one frame per 100 ms after a shot
- state +6: the same frames for a damaged pod (armour overflowed)
- state 12: pod destroyed

So the pod looks the same whatever weapon is fitted. Light, medium and heavy bays are different geometry baked into each Herc (textures 48–55). The earlier "12 weapon looks" reading was wrong.

The remake should:
- set the slot's state from the weapon state (0 at rest, 1→4 after each shot), not from the weapon type;
- add 6 when the pod is damaged;
- use 12 when the pod is destroyed.

Pod cells and the pod body box per hardpoint: `loadouts.json` `pods[].pod_cells`, `pod_box_units`; mine and missile launchers have no cell slot, so BD draws nothing there (render prep loop 0x7b27–0x7c13; `weapon_mounts.md` section 2).

Per-Herc tables are in `loadouts.json` → `pods` (side, node, mount/muzzle in units and metres, `hardpoint_mask` 7/15/31).

| Herc | POD 1 (left, slot 0) | POD 2 (right, slot 1) | POD 3 / POD 4 (slot 2 / 3) | mine | missile |
|---|---|---|---|---|---|
| Stryder | LIGHT | LIGHT | – | – | P1 |
| Talon | MEDIUM | MEDIUM | LIGHT / LIGHT (right shoulder) | – | P1 |
| Judicator | HEAVY | HEAVY | MEDIUM / MEDIUM (left/right) | – | P1, P2 |

Example rows; every Herc's bays are in `loadouts.json` `pods`.

Left and right assume +x = starboard. POD 1 always has x < 0.

## 7. Loadouts

There is no stock loadout:
- A bought Herc is bare. SHELL `0x1f7ac` copies only the bay types.
- A new pilot starts in a Stryder with LASER 1 ×2 and MOSQUITO (15), with a 1250 SL engine and the first compatible shield, armour and reactor (SHELL `0x11b28`, `0x1f960`).

The AI's Hercs are in the shipped ladder file `DATA/NETDATA.DAT`:
- It holds 698-byte records. The pilot name is at +0x1C, and the Herc config is at +0x11A in the SIM layout: `herc, armor, 26×part damage, …, +0xd8 engine, +0xdc ?, +0xe0 shield, +0xe4 reactor, +0xe8 7×{bay, weapon, ammo}`.
- That gives 59 pilots, REBEL … SWEEP. Record 59 is not a valid config.

`loadouts.json` gives, per Herc, the most common AI loadout (`meta.hercs` has the components and the count), plus all 59 pilots under `meta.ai_pilots`:

| Herc | AI default (POD1, POD2, POD3, POD4, MINE, MSL1, MSL2) | components |
|---|---|---|
| Stryder | LASER3, BLASTER1, –, –, –, MOSQUITO_15 | ARMOR1, 500 DL, SG II, 2.0TW |
| Talon | BLASTER4 ×2, BLASTER1 ×2, –, MOSQUITO_30 | ARMOR6, 1750 SL, SG IV, 3.3TW |

Example rows only; the rest are in `gamedata/bd/gameplay/loadouts.json` (written by
`tools/export_bd_weapons.py` from the user's `NETDATA.DAT`).

## 8. Sounds and effects

Sound ids index the list at `0x78648`:

| id | sound |
|---|---|
| 0 | footfall (also the misfire sound) |
| 1 | laser3h |
| 2 | laser2h |
| 3 | 1plasma1 |
| 4 | missle1 |
| 5 | 1mine2 |
| 6 | shield1 |
| 7 | lhit2 |
| 8 | 1explo |
| 9 | explo3 |

Fire sounds by class (pushes at `0x9d24`…`0x9ea5`):

| class | fire sound |
|---|---|
| laser | 1 |
| blaster | 2 |
| canon | 2 |
| plasma | 3 |
| missile | 4 |
| mine | 5 |

Explosion types use the table at `0x762a8` (11 dwords per row: sound id, light, light radius, nShapes, shape list). The frame advance is 100 ms.

| type | sound | shapes | used by |
|---|---|---|---|
| 0, 1 | explo3 | EXPLD1/EXPLD2 | plasma, missile |
| 2 | shield1 | SHIELD1 | – |
| 3 | shield1 | SHLDHIT2 | shield hit |
| 4 | lhit2 | RDLASER/LSRHIT | laser hit |
| 5 | 1explo | BLASTHIT | blaster hit |
| 6 | lhit2 | RDLASER/LSRHIT | canon hit |
| 7 | explo3 | SHROOM | mine, missile on the ground |

`BULLET.DTS` and `BLAMMO.DTS` are not referenced by SIM.EXE (unused).

## 9. Open points

* The laser beam colour and width as drawn. The ray radius is 40 units; the colour is assumed red.
* Record +0x10 and +0x60, and the purpose of armour +0.
* The turret update period (assumed 100 ms) and its targeting.
* The AI's firing range and weapon choice.
