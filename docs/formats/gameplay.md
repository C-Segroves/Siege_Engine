# Gameplay data formats (units, weapons, damage, tuning)

Decoder/exporter: `tools/units.py` (writes `extracted/gameplay/*.json`).
RE helpers: `tools/re_util.py` (whole-function disasm, callers, vtables, regex over code) and
`tools/re_fields.py` (follows a struct pointer through registers/stack and lists field offsets used).
All addresses are DBSIM.EXE virtual addresses (file offset − 0x48FD).

Confidence: **H** = seen in code doing the obvious thing, **M** = seen in code, meaning inferred,
**L** = guess from values only.

Fixed-point helpers used everywhere (good to know when reading fields):
`0x5e7f8(a,b) = a*b>>8`, `0x5e818(a,b) = a*b>>10` ("per-1024"), `0x5e838 = a*b>>14`,
`0x5e598(rate, target, &v)` = move `v` toward `target` by at most `rate` (scaled by frame time),
`0x63b3c(rng,n)` = random 0..n-1. Angles are 1/65536 turn (16384 = 90°).
Distances: world units, where 1 unit = 6 mm (cockpit readouts print units·6/1000 m, DBSIM 0x2e2a0). Hercs are 10–15 m tall. See `units.md`.

---------------------------------------------------------------------------------------------
## 1. Unit types — `SIMVOL0/DAT/<UNIT>.DAT` (192 bytes, no header)

Loader `0x19cf0` (mechsys.cpp). Names come from `NAM/MECHS.NAM`. In memory a MechType is
`0x1c4` bytes in array `[0xbc444]`: `+0 u16 index`, `+2..+0xc2 = the .DAT`, `+0xc2` HDD info,
`+0xc6` shape/GunList (DTS `<UNIT>.DTS`, GL, DMG, COL). Mech instance keeps the type at
`mech+0x188` (so code reads DAT field `X` as `[mt+2+X]`). DAMAGE model at `mech+0x19c`,
shields at `mech+0x1b8`, current speed `mech+0x224`, yaw rate `+0x222`, torso yaw/pitch `+0x22a/+0x22c`.

| off | name | conf | where / notes |
|---|---|---|---|
| 0x00 | turn_rate_max (600 all) | H | 0x12a2c. Yaw-rate target = turnInput×R>>8, R depends on speed: 0 if \|v\|<45; ramps 0→T over the first half of (vmax−45); then falls linearly to T/2 at vmax |
| 0x02 | speed_reverse_max (−155…−75) | H | 0x120b2 throttle clamp |
| 0x04 | speed_forward_max (Roadrunner 256 … Colossus 140; Gunslinger/Mongoose/Scorpion 270; Spider 300) | H | 0x120b8 |
| 0x06 | acceleration (30; Spider 25) | H | 0x12198 `approach(v, throttle, acc)` |
| 0x08 | turn_acceleration (150) | H | 0x12a6e |
| 0x0a | anim seq (5; Mongoose 10) | M | 0x18bcc |
| 0x0c | walk sequence (1; Bulldog 3, Spider 0) | H | 0x12547; `hercs.json anim_seq_stand` (old name), see animation.md |
| 0x0e | run sequence (2; Bulldog 4) | H | 0x125ba; `anim_seq_start` (old name) |
| 0x10 | anim seq walk fwd (3) | M | also used as node index at 0x115ce |
| 0x12 | anim seq walk back (4) | M | |
| 0x14 | z_offset (Colossus 400) | M | added to position z (0x131d3, 0x1e9ba) |
| 0x16 | shield_center_z (750/1000) | M | 0xfcc2 shield sphere centre |
| 0x18 | shield_radius (1500 light, 2500, Spider 1000) | M | 0xfd05; also the first hit test (projectile must enter this sphere) |
| 0x1a | torso_yaw_node (0; −1 none) | H | 0x11652, 0x14ac8 (angle>>2 applied to node) |
| 0x1c | torso_yaw_rate (1000; Spider 1500) | H | 0x149c6 |
| 0x1e | torso_yaw_accel (1000; Raptor 250) | H | 0x14a42 |
| 0x20 | torso_yaw_limit (14000 ≈ ±77°; Bulldog 32767 = free turret) | H | 0x14a87 |
| 0x22 | torso_pitch_node (5; −1) | H | 0x11682 |
| 0x24 | torso_pitch_rate (800) | H | 0x14bba |
| 0x26 | torso_pitch_accel (800; Raptor 175) | H | 0x14c36 |
| 0x28 | torso_pitch_max (6000 ≈ 33°; Roadrunner 8500) | H | 0x14c7d |
| 0x2a | torso_pitch_min (−4000; light −8000/−2000) | H | 0x14c85 |
| 0x2c | walk_seq_speed_cap (160…120; Spider 600) | M | 0x12433 speed clamp while still in the walk sequence |
| 0x2e | byte list, 0xFF-terminated (shape nodes) | M | passed with the shape to 0x19ba0 |
| 0x42 | ? (1000) | L | AI 0x18a15 |
| 0x44 | collapse sequence on death (7; Bulldog 2) | M | 0x122fc; animation.md |
| 0x46 | shape detail used in low-detail mode (2) | M | 0x19d87 |
| 0x48 | leg count (2; Bulldog 4; Spider 0) | M | 0x13007 in the mission pre-damage 0x12f20: below 20 % health a quad (component 7/8) is blown off and, with more than 2 legs, a rear quad (13/14); not an explosion id (deaths: weapon_fx.md section 9) |
| 0x4a | self_destruct (Spider 1) | H | the Spider's pilot and blast: section 2.1 below |
| 0x4c | **mass** (5000…12000; Bulldog 20000) | H | 0x1430f momentum = mass·v/1024 (collisions/ramming) |
| 0x52 | threat_value (Hercs 1024; Cybrids 500…2000; Spider 0) | M | summed per team 0x15b37; halved when crippled 0x14106; 0 → passive flag 0x115e6 |
| 0x54 | weapons_damageable (1; Bulldog 0) | M | 0x13eb7 |
| 0x56 | name char[12] | H | |
| 0x62,0x64 | eye point (y, z) (Roadrunner 200/490) | M | 0x10f04 |
| 0x66,0x68 | second view point (y, z) (0/1400…2600) | L | 0x10f14 |
| 0x6a | runtime type id (overwritten at load) | H | 0x19d5c |
| 0x6c | ? (−160…−60) | L | 0x1492c compared with −speed |
| 0x6e | collision (contact) radius, 750 all (hercs.json `unknown_6e`; catalog `collision_radius`) | H | mech vtable slot 0x60 = 0x10ec8; collisions 0x14174 (contact when centres are closer than the two radii) |
| 0x70 | byte list 0xFF-terminated: effect emitters (types from table 0xbc1d8) | L | 0x1171d |
| 0x7a | turn-in-place sequence (6; Bulldog 1) | M | node 0 rotates per frame; animation.md |
| 0x7c | 12 × 500 (all units) | L | |
| 0x94 | size class 0 light/1 medium/2 heavy/3 cybrid → texture set LIGHT/MEDIUM/HEAVY/ENEMY.DBA | H | 0x19e69 |
| 0x96, 0xaa | two small vectors (+ value) | L | |
| 0xbe | **shield_max** (3500 all; Spider 0) | H | 0x115a7 → Shields::init 0xfabc |

Sanity: max forward speed never increases with mass (Roadrunner/Gunslinger 256/270 @5000 …
Colossus 140 @12000).

## 2. Flyers — `SKIMMER.DAT` (34 bytes)
Loader 0x1c6c8 (flyersys.cpp), type struct 0x2e: DAT(0x22) + `+0x22` DMG + `+0x26` COL + `+0x2a` shape.
Words: 500 (+0 yaw-rate accel, H 0x1b6e6), 1200, 1000 (+4 copied to flyer+0x1c9, cruise value), 300,
150 (+8 pitch-rate accel), 4 (+0xa bank = −pitchrate>>4), −1, 14000 (+0xe), 1500 (+0x10). Rest L.
`HOVTANK` is in FLYERS.NAM but has no DAT; its DMG doesn't follow the DMG layout (unused).

## 3. Gun mounts — `GL/<UNIT>.GL`
Loader 0xc1d0: `u16 n`, n × 26 bytes. Gun i ↔ damage component `19+i` (H, 0x13f1a).

| off | field | conf |
|---|---|---|
| 0 | u16 mount id: the Herc shape **part** with this id (locator polygon 8/9/10/11/18/66/77); the pod hangs on that part's node (findPart, 0x12c00) | H (0xadd4, weapon_mounts.md) |
| 2,4 | s16 aux nodes (−1) | M (0xa688) |
| 6 | u8 mount group 0..3 → weapon shape variant `wpn.shape_group[g]` and push-out side 0 up / 1 down / 2 left / 3 right (>3 → none) | H (0xa542, 0xbd70, 0xbbd4) |
| 7 | u8 display index | L |
| 8,10 | s16 yaw min/max (±5000 ≈ ±27°) | M |
| 12,14 | s16 pitch min/max (−8000/16000) | M |
| 16..20 | s16 x,y,z attach point of the pod in the part's node frame (pod origin = this + push-out) | H (0xb918, 0xa308) |
| 22 | s8 side (1 left, −1 right, 0 centre) | M |
| 23 | u8 loadout slot (index into weapon/missile-type arrays from player.mec / mission) | H (0xc3b1) |
| 24 | u8 HUD y (64/160/208) | L |
| 25 | u8 hardpoint mask 31/15/7 (large/medium/small) | L |

## 4. Weapons — `WEAPONS.DAT` (2772 bytes)
Loader 0xbf48 (gunlist.cpp): 17 records, each read into a 0x58-byte object, then a 684-byte
projectile table. Record = **[DMG component record] [COL part] [0x30 bytes params]**:
`u16 hp, u8, s8 shape_part, s8 parent, u8 flags, u16 nlinks, nlinks×(s16 weight, s16 system)`
(same as DMG, weapon hp 500…2500, Cybrid 15000; link (20, system 12)), then
`u16 node(19), u16 n, n×(x,y,z,r)` collision spheres, then:

| obj off | field | conf / where |
|---|---|---|
| 0x22..0x28 | shape index per mount group 0..3 (into MECHWPNS/MECHWPN2 DTS lists) | H 0xbd70 |
| 0x2a,0x2c | ? (500/15000; GREN 15000) | L |
| 0x30 | u32 **range** (e.g. LAS 50000) | M passed to bolt spawn 0xb09e |
| 0x34 | AI cost/penalty in weapon choice | M 0x1902d (score = rating·100/1024 − cost·1000/1024 + noise²) |
| 0x36 | beam: minimum charge to fire | H 0xb28c |
| 0x38 | beam: charge per full shot; gun: ammo per shot (ATC 5, MLRS 1) | H 0xaf5f, 0xb070 |
| 0x3a | ammo capacity (e.g. ATC 1000 → 200 bursts at 5 per shot) | H 0xaa1b |
| 0x3c | beams: 3 = triple beam (centre + ±muzzle_x) | H 0xb0f5 |
| 0x3e | projectile row (0..18); 20 = none (ECM); 21 = missile rack (row = type 0, sub = loadout missile type, 5→0); 22 = grenade | H 0xc3fb |
| 0x40..0x44 | muzzle offset x,y,z in the pod frame (weapon_mounts.md) | H 0xaea4 |
| 0x46,0x48,0x4a | pod half extent x, (y unused), z: pushed out per mount group (0xbbd4) | H |
| 0x4c | **refire delay** (cooldown; e.g. LAS 1200) | H 0xaf11 |
| 0x4e | ? (mech code 0x18a74, scaled by (256−x)/256) | L |
| 0x50 | HUD icon index | M 0x30644 |
| 0x52/0x56 | runtime: name ptr (table 0x911fc) / index | H |

Weapon list (index, class from ctor jump table 0x913e8): 0 ATC20, 1 ATC35, 2 ATC50 (projectile
guns), 3 ELF (beam subclass), 4 EMP, 6–8 LAS100/200/300, 12 PBEAM (beams/bolts), 5 GREN
(grenade), 9–11 missile racks "6","8","10" (MLRS), 13 ECM, 14–16 Cybrid EMP/PBEAM/MISSL.

**Beam capacitor** (0xb4d8): charge `+0x7d` grows toward cap `+0x7b` (=960 at spawn) by 20/update
(60 in fast mode; BEAM.BND w7/w4); a beam can fire when cooldown = 0 and charge ≥ min_charge;
it consumes `per_shot`; if charge < per_shot it fires with the whole charge and damage is scaled
by charge/1024 (bolt+0x50, 0x80a4). EMP/PBEAM have per_shot 10000 → always "dump the capacitor".

### Projectile / impact table (19 × 36 bytes after the records, `[0xbc2ce]`, lookup 0xc2d0)
`s16 type, sub, shield_damage, armor_damage, splash_per1024, d, fx[12]`
- type 0 missile (sub 0..3 = SARH/ARH/ARM/EO, 4 Cybrid), 2 bullet, 3 grenade, 4 bolt (lasers/PBEAM/ELF).
- shield_damage → hit+6, armor_damage → hit+4, splash → hit+8 (H, bolt hit 0x8082..0x80ea).
- d: 5000 ATC, 2000 EMP, 6000 missiles; bolt+0x4c = d (speed/limit, L).
- fx: 3 groups × 4 random impact explosion ids (H, Mech::onHit 0x13fd4): shield absorbed the whole hit / armour
  hit without an integrity step (also terrain hits, 0x1f603) / armour hit that lowered the integrity step
  (exported as fx_miss / fx_shield_hit / fx_armor_hit; weapon_fx.md section 2.3).

| weapon | shield dmg | armour dmg |
|---|---|---|
| LAS100 | 1500 | 600 |
| missiles (all 4) | 400 | 1600 (splash 500/1024) |

(Example rows. The importer writes the full table to `gameplay/weapons.json`, `tools/units.py`.)

## 2.1 The Spider / Arachnitron (self_destruct units) and the spider mines

Read at import by `tools/self_destruct_rules.py` (with byte evidence) into hercs.json `self_destruct_rules`; the
loader turns them into the catalog `self_destruct` block; runtime `SelfDestructCharge`. Test: `spider_check`.

| rule | Earthsiege 1 (DBSIM.EXE) | Earthsiege 2 (DBSIM.EXE 1.0) |
|---|---|---|
| pilot class | think 0x18320, move step 0x18278 (table 0x10407) | think 0x41e570, move 0x41e488 |
| target | re-picked every 0x2710 ms (0x18395) by the target scorer 0xddf4 (flags 6, not decoded: the remake picks the nearest enemy); steers straight at it, full throttle (0x12038), no pathing | same, 0x41e5df / 0x411fa0 |
| walk / lunge | walk rand(4000)+8000 ms (0x1849a, 0x184ab), lunge rand(1500)+3000 ms (0x184dc, 0x184ed); a lunge calls the move step twice more per tick (0x183f7, 0x1843a): 3x pace; the first think starts a lunge | same (0x41e6e3 ... 0x41e72f) |
| trigger | every move step: contact 0x14174 (another unit closer than both DAT 0x6e radii, 750 units each; or a base, 0x375c) or a unit ran into it (flag +0xab, vtable slot 0x6c 0x118e4); no arming delay, no timer | same (0x418f74, slot 0x5c = contact radius) |
| blast | 0x1f75c(2000, 3000 units, centre): every unit with its centre within 3000 units, the Spider included | 0x426a20: skips the Spider; reach = centre distance minus the unit's contact radius |
| shields | not asked (0x13a7c straight to components) | the bank facing the blast absorbs first (0x4187d0 -> 0x413c68), the rest splashes |
| splash | each existing component (28 / 29) with chance 0x802/0x1000 (0x13acd): damage x (3000 - d) / 3000, d = blast centre to the component's point (slot 0x5c 0x15990: its COL sphere in its part, else the unit centre); damage type: component damage 0x13250 (systems, cascade) | same (0x41885a, slot 0x74) |
| self | 32000 on each own component (0x182e3) | same (0x41e52e) |
| killed otherwise | no blast: 0x13919 only switches its pilot to the dead state 0xaf514 (no chain blasts; other Spiders in a blast take component damage and die without blasting) | same |
| stats | DAT: shields 0, mass 0 (no ramming momentum), torso nodes -1, speed 300 / reverse -200, hp per DMG (cockpit 500) | DAT: speed 242 / reverse -80, walk cap 121, otherwise the ES1 values |
| deaths / fx | the ordinary unit death (DeathFx "vehicle": cockpit explosion 17) | same |
| missions / radar | placed as ordinary units in mission records (ES1 type 15, ES2 SPIDER), shown on radar and targetable like any unit, threat value 0 | same |

The remake credits the Spider with the kills of its blast (ES1 passes no attacker).

**Starsiege ARAC (Arachnitron 6/10/14-Pack Mine)**: a mine weapon (datWeapon.cs 131-133), not a unit. `newMine(ARAC)`
(datProjectile.cs; read at import by `tools/export_starsiege_gameplay.py`): a 30 s duration and proximity 0, among
the usual speed / damage / blast / turn-rate fields (damage x3 remake scale). It is a
tracking, accelerating mine: the remake (`MineRunner`) crawls it at the launcher's target, else the nearest enemy in
the weapon's 150 m range, and sets it off on contact (proximity 0); it expires (goes off) after 30 s. The
Starsiege.exe mine code is not decoded (target choice, cruise envelope: L).

**Battledrome GATOR / BLOODHND / PITBULL** (bd_weapons.md mine rules, SIM 0x104b8 / 0x1018c): hover at their height,
scan every N updates (the arm delay), go off when an enemy is within the trigger distance; BLOODHND and PITBULL chase
the nearest enemy within the detect radius; any hit sets them off (`MineBody`); no lifetime. Tribes 1 / 2 have no
spiders (the Tribes 2 "Spider Clamp" is a deployable turret barrel).

## 5. Damage model
### `DMG/<UNIT>.DMG` (loader 0x9a2c, damage.cpp)
`u16 nSys, nSys × s16 system threshold, u16 nComp, nComp × component`. Component (18 bytes in
memory) = `u16 hp, u8 ?, s8 shape_part (node switched to damaged state), s8 parent, u8 flags,
u16 nLinks, nLinks × (s16 weight, s16 system)`. flags: 1 fatal, 2 spawn debris/explosion on
destruction, 4 big explosion (0x9d74, 0x9e4c).
Components: 0 FRONT_COCKPIT, 1 REAR_COCKPIT, 2/3 L/R BRACKET, 4/5 L/R SHOULDER, 6 CROTCH,
7/8 QUAD, 9/10 SHIN, 11/12 FOOT (names from debug table 0x95e88), 13..18 extra parts (Bulldog legs),
19+i = weapon i. The layout is the same for every unit, Herc or Cybrid, so the exporters name every
row by index (13..18 REAR_LEFT/RIGHT_QUAD/SHIN/FOOT, 19+i "WEAPON i+1"); rows a unit does not use
keep 1 hp (placeholders; the game's leg speed cap ignores them). Systems (thresholds e.g. Achilles 2500,2500,800,800,500×5,50):
0/1 L/R LEG_ACTUATOR, 2/3 L/R ARM_ACTUATOR, 4 SENSORS, 5 ENGINE, 6 HYDRAULICS, 7 GYROS,
8 LIFE_SUPPORT, 9 PILOT. Example links: front cockpit → (20 sensors, 20 gyros, 1 pilot).

### `COL/<UNIT>.COL` (loader 0x9580, collide.cpp)
`u16 n, n × { s16 shape_node, u16 m, m × { s16 component, u16 k, k × (x,y,z,radius) } }` —
spheres are node-local; each sphere set maps to the damage component it belongs to. Weapon
components have no spheres here (they carry their own in WEAPONS.DAT).

### Hit pipeline (Mech::onHit 0x13b44)
1. Hit struct: `+0 ray, +4 armour dmg, +6 shield dmg, +8 splash/1024, +0xa fx ptr, +0xe attacker,
   +0x12 kind` (5 = bolt; 2 = EMP-kind: shields off & `mech+0x201`=6000 timer).
2. AI-fired damage (attacker record +0x14 byte = 0) is scaled by 0x1f82c: both the armour and the shield damage word `x = x * T[i] >> 10`, T = word table 0x922c4 = {2800, 2000, 1400, 1000}, i = header difficulty (word 7) in a single mission, 3 in a campaign (header mode word 2 != 0). Remake: `EsDamageModel.make_ai_damage_scale` / `make_hit_scaled` (H).
3. Shields (0xfca8): projectile must enter the shield sphere (DAT 0x16/0x18) else miss. Two banks
   front/rear (each max/2, chosen by hit side); bank absorbs min(shield dmg, bank). If the shield
   damage is fully absorbed → ricochet effect, **no armour damage**.
4. Otherwise the COL spheres pick a component (0x9064; components without spheres - the placeholder rows, the
   brackets, the weapon rows here - are never struck directly: the remake marks them `hittable` false from the
   catalog `component_points`; the shield bank of step 3 is the side the shot comes from, the remake uses the
   attacker's side, `Herc.is_front_hit`); armour damage A: splash part
   S = A·splash/1024 goes to nearby components (0x13a7c, radius 500), A−S to the hit component.
5. Component (0x9f7c): `acc += dmg`; when `acc ≥ hp` the component is destroyed and the overflow
   is passed to linked systems (0x979c): a link is picked at random weighted by `weight`, its
   threshold accumulator takes the overflow, repeating while systems die. If no live linked
   system remains and the component is **fatal** (flag 1) the component cascade (0x9cd4) destroys
   it and all children (`parent` == it). Weapon components (≥19) may be knocked out (chance
   41·10/4096 ≈ 10% if the attacker is the player, 41·3/4096 ≈ 3% otherwise; 0x13ed0) when
   `weapons_damageable` and the component is still alive.
6. Legs: leg-damage fractions >128/256 → speed ×750/1024, >192/256 → ×400/1024 (0x137c6, 0x1212e).
7. Death check (0x13824): component 0 or 1 (cockpits) destroyed → unit destroyed (M).
`MECHDMG` weights (exe 0x918e8, 0x91910) give the overall integrity % (0x10c38).

### Mission pre-damage (record `health` < 100; ES1 0x12f20 + 0x13078 (H); ES2 0x4178e8 identical thresholds, quads and call of 0x417a04 (H), its spread assumed the same as 0x13078 (M))
Called when a mission unit spawns with its record health h. Damage level L: h < 0 or h ≥ 80 → 0 (none);
60–79 → 50; 40–59 → 80; 20–39 → 120 (also writes one word of the component list's +0xc block through
fixmul(x, 0x100) and sets unit +0x8c+0x21; meaning L); h < 20 → 150: a front quad, component 7 or 8 (rand & 1),
takes 0x7d00 = 32000 via 0x13250 (blown off), and when the DAT leg count (0x48) > 2 a rear quad 13 or 14 too; flags
+0x8c+0x12/+0x21/+0x22 set (L: damaged-state markers). Then 0x13078(unit, L + 25, L): for each of the 28 component
slots that exists, if `(rand & 0xff) < L + 25` the component takes `hp × (rand % L + L/2) / 256` (fixmul 8 bits,
0x5e7f8; hp from the DMG record via 0xa24c) through 0x13250. Not random hits and not armour only: every component
may be wounded, by at most (L − 1 + L/2)/256 ≤ 224/256 (87.5 %) of its hit points, so only the blown-off quads are ever
destroyed. No death check runs; cockpits (the death components, 0x13824) are never destroyed, so a unit never
starts dead. Remake: `Herc.apply_start_health` / `HercDamage.make_start_level` (rear quads when the unit has real
rear-leg rows, standing in for the leg count); test `tests/fix_b_check.tscn` (health 10 Scorpions).

## 6. Other DAT files
- `BULLETS.DAT`: `u16 n`, n × {shape, lifetime ticks (17/50/30), hit size (100/200), flags (0/0x100), sound (+10)} (bullet.cpp 0x7bb0, 0x7f90).
- `ROCKETS.DAT`: `u16 n`, n × 14 bytes (word 0 = shape) (rocket.cpp 0x73d0).
- `DEBRIS.DAT`: `u16 n`, n × {s16 a, u16 k, k × (piece, 20)}.
- `EXPLOS.DAT`: `u16 18`, 18 × 44 bytes (shape, frames 7, size 200, …, sound) — raw in JSON.
- `MFORMS.DAT`: `u16 5`, 5 × 7 × (s16 x, s16 y) wingman slots. `FFORMS.DAT`: 5 × 3 × (x,y,z).
  `BFORMS.DAT`: 5 × 7 × (s32 x, s32 y). `BASES.DAT`: `u16 9`, 9 × 54 bytes (base.cpp 0x46ac);
  `BASECOL.DAT` raw.

## 7. BND tuning blocks (`SIMVOL0/BND`, `SHELL0/BND`)
Format: `u32 unix timestamp` (1994-06…10, the tuning save time) + packed s16 values (32-bit
values as two words). **The shipping DBSIM never opens them**: the `bnd` extension pointer
(0x980c0) has no code references, and the values appear in the exe as immediates or as aligned
static tables (e.g. MECHDMG ≈ table 0x918e6 with alignment padding; MECHSYS = 0x91dac). Order
follows declaration order in the module, so value matches + code order locate them. Identified:

| block | word | value | meaning | exe |
|---|---|---|---|---|
| SHIELDS | 0 | 102 | front/rear balance step (/1024) | 0xfaf0 |
| SHIELDS | 1 | 4 | max shield recharge per update | 0xfb51 |
| SHIELDS | 2 | 65 | rate banks follow the balance | 0xfb94 |
| SHIELDS | 3 | 1000 | shield drain scale (/1024) | 0xfc85 |
| BEAM | 4 / 7 | 60 / 20 | capacitor charge rate fast / normal | 0xb52a/0xb531 |
| MECH | 7 | 6000 | EMP shield-down time | 0x13c39 |
| MECH | 32/33 | 128/192 | leg damage thresholds | 0x137eb/0x137c6 |
| MECH | 34/35 | 400/750 | speed scale crippled/damaged leg (/1024) | 0x1212e/0x12153 |
| MECH | 47/48 | 45/60 | min speed to turn / min anim rate | 0x1299c/0x12458 |
| MECH | 14,16,18 | 45000/50000/35000 (u32) | distance thresholds | 0x15b0d/0x1001c/0x15ce0 |
| MECHIQ | 90/91 | 35/30 | AI weapon-choice noise (vs player / others) | 0x18ed2 |
| MECHIQ | 92/93 | 150/−100 | AI skill lerp | 0x18e67 |
| MECHDMG | 1..19, 20..31 | | component / system integrity weights | 0x918e8/0x91910 |
| MECHSYS | | 75,60,45,25,18,12,6 | u32 table attached to every mech shape (LOD thresholds?) | 0x91dac |

Everything else (MECHIQ, FLYERIQ, PMISSILE, PHUD, PRADAR, CAM, ROCKET, FLYER, GUNLIST, PROJECTL …) is
exported as raw words; candidate code sites for each value can be found with the immediate-search
approach (value + module code range), e.g. ROCKET 1280/3072 → 0x7085/0x7032, FLYER 15000 → 0x1b132,
CAM 2500 → 0x1d721. The BND values may differ slightly from the compiled ones (MECHDMG w0 150 vs 100).

## 8. Shell `SHELL0/CFG/*.DAT` (GO.EXE, partly reversed)
`ROAD/GUNS/RAPT/TOMA/PATR/PANT/HERC/COLO.DAT` = per-Herc hangar weapon-piece art layout and `HOTSPOT.DAT`
= hardpoint click areas (decoded: shell.md §7b; `GUNS.DAT` is the Gunslinger's); `*DMG1.DAT` =
repair-screen damage-diagram regions; `DAMAGE.DAT` (36 words) = repair cost weights (GO 0x387ac,
campaign_availability.md section 7);
`CONFIG.DAT` (21600 bytes) not examined. Exported raw.

## Unknown / TODO
- Speed units → m/s: solved in `docs/formats/units.md`. Speed is an animation rate (256 = authored stride), 1 unit = 6 mm.
  DAT 0x0c/0x0e are actually the walk/run sequence ids (0x12547/0x125ba).
- WEAPONS 0x2a/0x2c/0x46/0x48/0x4a/0x4e; projectile row field `d`; ROCKETS/EXPLOS fields.
- Most BND constants (only the table above is named); AI (MECHIQ/FLYERIQ) logic.
- Energy budget: what feeds beam capacitors & shields per update (mech update path).
