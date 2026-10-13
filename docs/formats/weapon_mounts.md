# Weapon mounts: where each original game puts a weapon model

How every Herc game hangs a weapon model on a vehicle: the frame, the offset, the orientation, the
scale and the muzzle (projectile origin). The remake follows these rules exactly for each game's own
weapons and reuses the same frames for other games' weapons.

Code:
- `game/engine/weapon_mount.gd` (`WeaponMount`): hardpoint frames, native placement, muzzles.
- `game/engine/weapon_pod_fit.gd` (`WeaponPodFit`): reference pod per hardpoint and the fit transform.
- `game/games/es1/herc_model.gd` (`HercModel`): the plan per hardpoint, building and attaching the model.
- `game/engine/weapon_lookalike.gd` (`WeaponLookalike`): which installed model a model-less weapon borrows (section 7).

Tests: `game/tests/lookalike_check.tscn` (section 7) and `game/tests/weapon_fit_check.tscn` ("native placement" compares every native pod of 11 sample
hosts with the transform computed from the raw records; "baked pod" checks a foreign pod on a
Battledrome bay; "GL mount parts" checks every ES1/ES2 gun's frame node against the shape data, cell
parts included, and the Headhunter's muzzles against its height; the line check needs geometry between
the PBEAM_CYBRID body and tip). Renders: `renders/leftover_bulldog.png`, `renders/leftover_headhunt.png`.

Axes below are the originals' (x right, y forward, z up). In Godot, y and z swap and y is negated
(`ShapeInstance.es_to_godot`).

## 1. Earthsiege 1 and 2 (3Space, DBSIM.EXE) — H

| step | ES1 (DBSIM, VA = file offset − 0x48FD) | ES2 (DBSIM, PE image base 0x400000) |
|---|---|---|
| pod shape = MECHWPNS list entry `weapon +0x22 + 2·group` (fresh copy per gun) | 0xbd70 | 0x40fab0 (only `mechwpns` is loaded, 0x40f998) |
| group push-out from `weapon +0x46/+0x48/+0x4a` | 0xbbd4, jump table 0x91240 | 0x40f904, jump table 0x40f946 |
| attach point = push-out + GL offset (`GL +16..20`) | 0xb918 | 0x40f540 |
| pod vertices translated by the attach point | 0xa308 (from gun ctor 0xa530) | 0x40dd4c (gun ctor 0x40df30) |
| `findPart(herc shape, GL +0 mount id)` → `part +4` = node; pod parts rebound to that node | 0x12c00 → 0x12b58 (vtable +0x24) | 0x4175dc → 0x417530 (vtable +0x20) |
| muzzle = node matrix · gun aim · (`weapon +0x40..+0x44` + attach point) | 0xadd4 | 0x40e788 (0x40e8cc) |

- **Frame.** The node of the Herc shape part whose id is the GL mount id. The ids 8, 9, 10, 11, 18,
  66 and 77 are locator polygons, nearly all on node 11 (the torso). The engine used to place pods
  at the locator polygon's centroid. That is wrong by up to 0.5 m: Outlaw side pods were 133 units
  too far forward, Tomahawk's 77/66 pods 0.3 m off.
- **Cell parts count.** findPart walks the whole part tree, so a damage cell (`cell_anim_part`) matches
  by its own id, before its pieces. The internal-gun mount id 5 is such a cell part on every ES1/ES2
  Herc and Cybrid: the torso cell on node 11 (Headhunter: node 12, its pitch node; Razor: no node, so
  the root). The shape export records it as `lods[].cells[].id` (`tools/export_es1.py flatten_lod`).
  Before, the remake only looked at piece ids, found no part 5 and hung those guns on node 5, an
  unrelated node: the Headhunter's internal guns fired from its feet, the Hercs' from a hip or leg.
  Every GL mount id of the 198 ES1/ES2 guns now names a part (`weapon_fit_check`).
- **Offset.** GL offset + push-out. The push-out is the pod's half extent (`+0x46` x, `+0x4a` z; y
  is forced to 0), keeping only the component that points away from the Herc:

  | mount group | push-out | pod |
  |---|---|---|
  | 0 | (0, 0, +z) | on top |
  | 1 | (0, 0, −z) | below |
  | 2 | (−x, 0, 0) | left |
  | 3 | (+x, 0, 0) | right |
  | 4 and up | (0, 0, 0) | internal: no shape (gun ctor) |

- **Orientation and scale.** No rotation, no mirroring, no scale. The rolled and mirrored looks
  are separate MECHWPNS shapes per mount group. MECHWPNS shapes have no nodes; the origin is the
  attach point, and the barrel points +y.
- **Muzzle.** Record `+0x40..+0x44` in the pod frame, e.g. ATC20 (0, 750, 0): 150 units past the
  barrel end (y max 598).
- **ES2 differences.** findPart is vtable +0x20. GL +2 / +4 are aim animation threads (all −1). In
  view mode `[0x49ef5c]` the player's muzzle node is lowered by 1500 units. Group-4 guns use mount
  id 5, the torso's cell part (above). Only when findPart finds nothing or the part has no node
  (`part +4` = −1, 0x40e7c1) does the muzzle use the fallback matrix 0x6c572c; the remake then uses
  the shape root.
- **Lines.** A two-vertex polygon is a line. The particle-beam guns (MECHWPNS 2, 4 and 13) are a body
  and a tip joined only by four corner rails drawn as lines; the remake skipped polygons under three
  vertices, so the Bulldog's PBEAM_CYBRID (MECHWPNS 13: body y −1480..200, tip 1400..1880) showed its
  tip floating 4.7 m ahead of the body. Its placement was already right: GL mount id 5 = the locator
  polygon on node 20 (the gun pitch node under the turret node 19), offset (0, 150, 50), group 0
  push-out +z 250, matching the locator's extent (z 0..520). `ShapeInstance` now draws lines as thin
  tubes (`LINE_WIDTH_UNITS`), on every 3Space shape (Bulldog, Pitbull, Scarab, Skimmer, terrain wires).
- **Data.**
  - ES1: `weapons.json` `unknown_46/48/4a` and `muzzle_x/y/z`. `PackWeaponLoader._table_pod_model`
    turns them into `model.pod_extent` / `model.muzzle_units`.
  - ES2: `weapons_engine.json` `model.pod_extent` / `model.muzzle_units`, from
    `tools/export_es2_weapons.py` `pod_model`.

## 2. Battledrome (SIM.EXE 1.3.2) — H

Read with `bd_weapons.md` section 6.

- **Pods are baked into the Herc shape.** Render prep 0x7904 (loop 0x7b27–0x7c13) sets the
  state of each bay's cell slot: 0 idle, 1–4 firing, +6 damaged, 12 destroyed. Nothing checks
  which weapon is fitted, so the pod is drawn even on an empty bay. Pod cells sit on the
  logical-part node (part 11 + i), and BD node rotations are all 0.
- **Mine and missile launchers** have cell slot −1, so BD draws nothing there.
- **Muzzle** = logical-part point + (0, muzzle_y, 0). It is within −0.18..+0.42 m of the pod tip.
- **Distinct pod looks.** There are only about six: light, medium and heavy arm pods and three
  shoulder pods. Length does not grow with bay class (heavy arm 3.98 m < light arm 4.62 m <
  medium arm 5.44 m), so each hardpoint uses its own box.
- **Data.** `loadouts.json` `pods[]` has `pod_cells` and `pod_box_units {min, max}`. The box is
  around the logical-part point: the pod body only, i.e. connected groups of ≥ 3 polygons crossing
  the pod's x = 0; struts, fins and torso plates are left out. These come from
  `tools/export_bd_weapons.py` `pod_box`. The loader shifts the box into the muzzle frame
  (`PackVehicleLoader._bd_baked_pod`).
- **Remake.**
  - Native weapon on a bay: BAKED, the frame is the muzzle point.
  - Native weapon on a mine or missile launcher: nothing, as in BD. This was a stand-in pod before.
  - Another game's weapon on a bay: the bay's pod cells are hidden (`ShapeInstance.set_cell_hidden`)
    and the pod is fitted into that bay's box. Before, it was front-anchored on the muzzle with a
    borrowed box, and the baked pod stayed visible underneath.

## 3. Starsiege (Darkstar, Starsiege.exe) — H code, geometry-checked

- **newHardPoint** (handler 0x415dc9; `newHardPointExt` 0x4160c3) gives a 0x5c-byte definition:
  - `+4` size S/M/L/X
  - `+8` side T 0 / B 1 / L 2 / R 3 / I 4
  - `+0x14` node name: empty → "head0" (0x4952c1); `newHardPointExt` names it
  - `+0x34` offset in metres
  - `+0x40` / `+0x4c` aim limits
- **Frame.** 0x4bc858 mounts the weapon shape on that node of every LOD (`head0..head9`).
- **Orientation.** 0x494e34 builds the mount matrix from 0x494dd0, a roll about forward:
  - T and I: 0
  - B: 180°
  - L: −90°
  - R: +90°, so the gun's top faces outward: (x, y, z) → (z, y, −x)

  64 of 172 hardpoints are L, R or B. The remake stood them all upright, half inside the pods.
- **Scale.** None.
- **Weapon shapes.** No mount or muzzle node; the origin is the mount point and the barrel points
  +y. `baseA 32` is the body on wg_las / wg_hlas (10 polygons) and a flat strut elsewhere. Foreign
  pods now drop only `base*` pieces with ≤ 2 polygons; before, half of wg_las vanished.
- **Muzzle.** `weaponShot(x, y, z, t)` (handler 0x413e5d, WeaponDef +0x148, up to 3) in the gun
  frame, on the barrel tips. Origin = offset + Roll(side) · shot. The remake fired from the
  hardpoint (up to 2.9 m behind the tip).
  - Data: `weapons_engine.json` `model.muzzle_units` (first shot) and `model.fire_offsets` (all),
    from `tools/export_starsiege_gameplay.py` `pod_model`.
  - Only the first shot is used: TLAS / CLAS do not alternate barrels.
- **Head.** 0x445838 writes yaw only to head0. The remake still pitches the whole head
  (animation.md); per-hardpoint pitch is not modelled.

## 4. Tribes 2 (Torque) — M (engine source behaviour + scripts)

- **Image transform** = vehicle node `mount<mountPoint>` × image (offset) × inverse(the image
  shape's `mountPoint` node).
- **Muzzle.** `getMuzzlePoint` = image transform × the image shape's `muzzlePoint` node. The remake
  now reads the model's `muzzlePoint` node (`WeaponMount.make_local_muzzle`). Before, it fired from
  the image origin: Beowulf mortar 3.4 m behind its tip, Shrike guns 0.6 m.
- **Not done.**
  - Beowulf barrels pitch about their `mount0` / `mount1` (sequence `elevate`).
  - The tank / belly-turret activation pose.
  - The bomber bomb muzzles (`turret_muzzlepoint.dts` is not exported).

## 5. Muzzles in the remake

`HercModel.attach_weapon_model` puts a `muzzle` Marker3D on the hardpoint frame. Its position is the
pod's transform applied to the first of these that exists:
1. its `muzzlePoint` node;
2. its own game's muzzle (`model.muzzle_units`, when the model is its own). The weapon asked is the
   plan's `weapon`, i.e. the weapon whose model is drawn: a look-alike (section 7) fires from the
   borrowed model's own muzzle;
3. the front centre of the pod geometry.

`Weapon.muzzle()` uses it (`HercModel.muzzle_of`). Hardpoints without a model fire from the frame:
- Battledrome bays: the BD muzzle point.
- ES internal guns: the GL point on the mount part's node (mount id 5: the torso cell part); the `+0x40`
  muzzle is not added.

The frames were also misaligned before. `mount_nodes` skipped guns without a marker, so on Scorpion,
Mirimac, Achilles and others the pods and shots of later guns moved to the wrong hardpoint. Now
there is exactly one frame per gun.

## 6. Other games' weapons (campaign_availability.md section 4.1)

- **Frame.** The same frame and the host's native pod for that hardpoint (`frame_reference`):
  - Battledrome bay: the bay's box.
  - Earthsiege: the host's representative pod of the size and family, in the hardpoint's
    mount-group variant and push-out.
  - Starsiege: the host's pod, rolled by side.
  - None of its own: the other games' median, hung off the hardpoint.
- **Fit.** Uniform scale to the reference length (±25 % test). The back face goes on the
  reference's back face, the face toward the Herc on the reference's inner face (outward = mount
  group / side), and the pod is centred on the remaining axis.

## 7. Weapons without a model: look-alikes (WeaponLookalike)

Battledrome weapons have no models of their own: the pods are cells baked into each BD Herc (section 2).
ES2 MINE / LAEW and Starsiege EHUL have none either. On a Battledrome bay a BD weapon keeps its baked
pod (and nothing on a BD launcher), exactly as before. Anywhere else such a weapon borrows the model of
the installed weapon that is most like it. Players own any subset of the discs, so nothing is assumed:
only packs that are installed (`Assets.installed_packs`) and have their Herc weapons switched on
(`Packs.is_enabled(pack, "herc_weapons")`) are candidates. Turret-only weapons (size I) and, on
non-Cybrid hosts, Cybrid-only weapons are never borrowed.

### 7.1 Archetype (from the weapon's data, first matching row)

| # | archetype | rule (weapon schema fields) |
|---|---|---|
| 1 | drain (EMP / ELF) | `kind` emp, or `effects` emp_shield_drain / elf_leech / disable_seconds > 0 |
| 2 | mine | `kind` mine, or a proximity fuse with speed < 1 m/s |
| 3 | artillery | `kind` artillery / grenade / bomb, or projectile gravity > 0 (lobbed) |
| 4 | missile | `kind` missile, or a guided projectile (`guidance` ≠ none) that uses ammo |
| 5 | flamer | `kind` flame |
| 6 | special | `kind` ecm / other (ECM, equipment pods) |
| 7 | laser / particle beam | `kind` beam without ammo: particle beam when armour damage ≥ 0.8 × shield damage, else laser |
| 8 | autocannon / heavy cannon | ammo-fed projectile (or beam with ammo): heavy cannon when refire ≥ 1.0 s |
| 9 | blaster / plasma | energy projectile: plasma when refire ≥ 1.5 s or splash ≥ 4 m, else blaster |

Thresholds: ES1 PBEAM 1000/1000 vs LAS100 1500/600 (BD lasers 2:1); ATC 0.47 s, BD CANON 0.3–0.4 s,
Starsiege HATC 0.7 s vs BC 1.7 s, RAIL 1.2 s; BD BLASTER 0.3–0.4 s, 2.1 m vs BD PLASMA 1.7–2.9 s, 4.3 m,
ES2 PLAS 15.6 m.

| Battledrome weapons | archetype | size classes |
|---|---|---|
| LASER 1–7 | laser | S (1–3), M (4–5), L (6–7) |
| BLASTER 1–4 | blaster | S (1), M (2–3), L (4) |
| PLASMA 1–3 | plasma | M (1), L (2–3) |
| CANON 1–5 | autocannon | S (1–2), M (3–4), L (5) |
| MOSQUITO, HORNET, CHARLIE, EAGLE | missile | S |
| GATOR, BLOODHND, PITBULL | mine | S |
| ES2 MINE / LAEW, Starsiege EHUL | mine / artillery / special | M / L / I |

### 7.2 Decision tree

The first step with a candidate wins (`WeaponLookalike.RULES`). The size class is the weapon's own.

| step | rule id | candidates |
|---|---|---|
| a | `archetype_size_host` | same archetype and size, from the host Herc's pack (it looks native there) |
| b | `archetype_size_era` | same archetype and size, any available pack |
| c | `archetype_near_size` | same archetype, any size |
| d | `family_size` | same visual family (`WeaponFit.family_of`: gun / launcher / pod) and size |
| e | `host_pod` | the host game's own pod for that hardpoint (its representative weapon of that family and size) |
| f | `stand_in` | the procedural stand-in pod |

Each step ranks its candidates by one key, compared in order:
1. size distance (one class up or down before two);
2. host pack first;
3. archetype affinity (step d: blaster → plasma, laser, particle beam, autocannon; plasma → blaster,
   particle beam, drain; missile → artillery, mine; mine → missile, artillery; …, `AFFINITY`);
4. timeline distance between the weapon's pack and the candidate's (`Packs.era`);
5. stat distance: the sum of |ln(a/b)| of refire, damage per trigger (shield + armour × burst) and speed
   (beams 3000 m/s), plus half that of rounds;
6. the weapon id.

So the pick is deterministic. Choices are cached per (weapon, host pack, host side, available-pack set);
`Packs.reload` clears the cache, and switching a pack on or off changes the key.

**Placement.** The borrowed model goes through the normal fit (section 6). A look-alike from the host's
own pack and of the hardpoint's reference size is placed natively (its original offset and mount-group
variant). Any other is fitted to the host's pod at that hardpoint; on a Battledrome bay the baked pod is
hidden. The muzzle is the borrowed model's (section 5).

**Shown to the player.** The mount plan carries `lookalike` = {rule, weapon, archetype}. The armory
(`LoadoutEditor`, also on the Hangar screen) shows it as the picker tooltip, e.g. "looks like: es1
LAS200 (archetype_size_host)".

**Examples** (BD weapons on a Raptor's medium / small hardpoints, `lookalike_check`):

| installed | LASER4 | BLASTER2 | MOSQUITO | CANON1 |
|---|---|---|---|---|
| all | es1 LAS200 (a) | Starsiege BLAS (b) | es1 MLRS (a) | es1 ATC20 (a) |
| BD + ES1 | es1 LAS200 (a) | es1 LAS200 (d) | es1 MLRS (a) | es1 ATC20 (a) |
| BD + Starsiege | Starsiege HLAS (b) | Starsiege BLAS (b) | Starsiege VIP8 (b) | Starsiege ATC (b) |
| BD + ES2 | es2 LAS300 (b) | es2 LAS300 (d) | es2 MSL10 (b) | es2 ATC20 (b) |
| BD only, BD + Tribes 2 | host pod (e) | host pod (e) | host pod (e) | host pod (e) |

Tribes and Tribes 2 have no Herc-family weapons, so they never give a look-alike.

