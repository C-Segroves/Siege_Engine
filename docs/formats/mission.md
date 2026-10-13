# Missions: MSN, script.dat, ENG, campaign files

Tool: `tools/mission.py` (parser, shell-compiler emulation, script.dat writer/reader, ENG reader,
campaign tables, JSON export, matplotlib plot). Run `python tools/mission.py all` to convert every MSN to
`out/missions/*.json`.

Runtime: `tools/export_missions.py` writes the parsed (unevaluated) MSN records, ENG chunks, campaign
tables and zones to `gamedata/es1/missions/`; `game/games/es1/mission/mission_compiler.gd`
(`MissionCompiler.load_mission`) is a bit-exact GDScript port of the compiler + `mission_json()`
(including CPython's MT19937 `random.Random`), `campaign.gd` (`Campaign`) the progression helper.
Parity test: `python tools/tests/test_mission_port.py`.

Confidence: **H** = read directly from code and checked against data, **M** = consistent with code and data
but semantics partly inferred, **L** = guess.

Addresses: `GO@x` = GO.EXE (shell) VA, `SIM@x` = DBSIM.EXE VA. Both use VA = file offset − 0x48FD
(GO base found the same way as DBSIM: 247 string-push hits at delta 0x48FD; added to `tools/exe.py`).
GO.EXE functions often start with `enter`, not `push ebp`, so `exe.py func` may not find their start.

All integers little-endian. `s16` signed 16-bit, `i32` signed 32-bit. `-1` = "none / not set" everywhere.

---------------------------------------------------------------------------------------------------------

## 1. Data flow (H)

```
 shell (GO.EXE)                                                  sim (DBSIM.EXE)
 bst\batlsets.bin -> bst\btlset_N.dat -> slot -> msn\X.MSN         data\script.dat   SIM@1d850 (preload)
 (single missions: msn\sing_msn.dat)                               data\mission.var  SIM@1e638 (create)
 GO@35873: read MSN, check MC version == 5                         data\player.mec
 GO@3276c: "compile" (conditions, random picks, overrides)   ==>   ...
 GO@3445b: write data\script.dat                                   writes data\results.dat, mission.var
 GO@35b7a: write data\mission.var (100 x s16)                      back (SIM@1d698)
 ENG text: msn\X.ENG (briefing/objectives/debriefing)
```

File names come from `SHELL0/CFG/FILENAME.BIN` (a string table, GO `Text::getString` @18717 with object
0x9afb8): 0 exit.cfg, 1/2 joy*.cal, 3 script.dat, 4 player.mec, 5 mission.var, 6 object.str,
7 results.dat, 8 restore.dat, 9 sm_play.gam, 10 sm_play.mec, 11 temp.car, 12 temp.mec, 13 names.log.

The MSN is a *compiled mission script* with conditional/random records ("MC" = mission compiler; error
string `ERROR: Script must be compiled with MC Version %d.`). The shell evaluates it once per play and
writes the flat, resolved `script.dat`. **script.dat is exactly the MSN after evaluation with the
first 6–8 bytes (id/cond/pick) of every record stripped and id references replaced by indices.**
Verified against the 4 demo tapes (they embed a script.dat, see §6): all deterministic sections
(points, paths, areas, regions, flyers, groups) of SM_SCR01 / SM_PTL01 / SM_RAD01 compiled by
`tools/mission.py` are byte-identical to the tape copies; only randomly picked values differ.

---------------------------------------------------------------------------------------------------------

## 2. MSN file (GO@3276c reader, H for layout)

```
s16 version            = 5 (checked GO@359b5)
section cond[]         s16 n, n x 14 bytes
section header[]       s16 n, n x 22 bytes
section point[]        s16 n, n x 22 bytes
section heading[]      s16 n, n x 10 bytes
section path[]         s16 n, n x (10 bytes + 2*count)
section area[]         s16 n, n x 12 bytes
section region[]       s16 n, n x 30 bytes
section herc[]         s16 n, n x 106 bytes   ("object A", hercs incl. cybrid walkers)
section flyer[]        s16 n, n x 64 bytes    ("object B", skimmers / hover tanks)
section struct[]       s16 n, n x 24 bytes    ("object C", bases / buildings / turrets)
section group[]        s16 n, n x 88 bytes
```
All 77 version-5 files parse exactly to EOF. **Legacy variant** (B0_C1_20, B0_C1_30 only; not referenced by
any battle set): no header section but a fixed 20-byte script header right after the version word, and
88-byte herc records (no ammo block, see below). Parsed as `legacy` by the tool.

### 2.1 Common record prefix and evaluation rules (H)
Every record (except cond/header) starts with `s16 id, s16 cond, s16 pick`.

* **id** – global id namespace shared by all sections (the MC compiler's symbol numbers). `-1` =
  anonymous: kept in the shell's working arrays but never written to script.dat.
* **cond** – id of a condition record; the record exists only if that condition was kept (§2.2).
  `-1` = unconditional. Lookup GO@32711.
* **pick** – random-variant selection (GO@318d5 + per-section helpers 319fc/31a67/31ad4/31b41/31bac/31c19):
  if != -1 it is a *key*: find kept cond of kind 3 with `a == key`, roll `random(c)`, find its kind-2
  child whose `[a..b]` contains the roll; then copy the data of the first earlier record of the same
  section whose `cond` == that child's id. Used e.g. for "player starts on one of 3 routes", random enemy
  loadouts (key 10 used 1467 times in campaign files = loadout table).
* **duplicate id** – a later record with an id already present *patches* the earlier one:
  points/headings/paths/areas: whole record replaced; regions/objects/groups: only fields that are not
  the "unset" value are copied (GO@31d67, 31e7b, 320f9, 322b6, 3242a). Unset = -1, except: herc block
  0, herc ammo 5, herc f62 2, health 100, group block 0.
* **references** are converted to *script indices* = rank among records with id != -1 (GO@313f1 etc.).
  Faithful quirk: duplicate detection in point/heading/path/area/region also uses script indices, so an
  anonymous record before a duplicate would shift the patch target (never happens in shipped data).

### 2.2 cond (14 bytes) (H)
| off | field | |
|---|---|---|
|0|id||
|2|parent|cond that must be kept first (-1 none). For kind 2: the random cond it tests|
|4|kind|0 compare, 1 random, 2 case, 3 pick-group|
|6|a|kind0: mission.var index; kind1: n; kind2: lo; kind3: pick key|
|8|b|kind0: operator 0x114 `==`, 0x115 `!=`, 0x116 `<`, 0x117 `>`; kind1: result `random(n)` stored here; kind2: hi|
|10|c|kind0: compare value; kind3: n for `random(n)`|
|12|d|kind3: runtime roll|

Evaluation in file order, building the kept list K (GO@327c6):
kind 0: kept if parent ok and `var[a] op c`. kind 1: if parent ok, `b = random(a)`, kept.
kind 2: v = value of parent (kind1 → its roll, kind3 → -99, missing → -1); kept if v == -99 or
`lo <= v <= hi` (unsigned compare). kind 3: kept if parent ok.

Mission variables tested by campaign/single files: var1 (campaign index 0–7, 99 = single mission;
used to vary loadouts/terrain per campaign), var3 (time of day), var15–var93 (results of earlier
campaign missions), var69/var30 (misc).

### 2.3 header (22 bytes) (H layout, M semantics)
`s16 cond, s16 f[10]`. For each kept record: `f[0]` applied if != 1, `f[1..9]` applied if != 0
(GO@31c84). Defaults: f[0]=1, others 0. After compiling the shell overrides (GO@35ad1), then writes
the 10 words as the **script header** (GO@3445b), word 2 replaced by the mode:

| word | meaning | source |
|---|---|---|
|0|terrain type 0 desert, 1 temperate, 2 ice, 3 urban (SIM table 0x924a0) (H)| campaign: GO table 0x80f14 by campaign index = 1,2,2,0,0,3,3,3; single: `random(4)`. The MSN value is only used through these overrides|
|1|zone number → `ZONE<n>.DAT` (SIM@20238) (H)|MSN|
|2|mode: 1 campaign, 0 single mission (GO aad56) (H)|shell|
|3|mission type 0–9: win test + debrief selection (SIM@f4e8, SIM@f0f0) (H code / M meaning)|MSN|
|4|unused by sim; copied to GO aad5c (L: sub-type)|MSN|
|5|AMMO option|campaign 0 / single: options dialog (MENU1110 "MISSION PARAMS")|
|6|DAMAGE option|campaign 0 / options|
|7|DIFFICULTY option (0–3)|campaign 2 / options|
|8|VISIBILITY (1 = short: SIM@1f814 uses 30000 instead of 60000; also selects odd WORLDn.WLD = `tex_lo` variant)|campaign: MSN (random, ~1/5000) / options|
|9|TIME OF DAY 0–2 (palette set)|campaign: MSN (random) / options; also copied to mission.var[3]|

World file: `WORLD<terrain*6 + time*2 + visibility>.WLD`, palette set `world<terrain*6 + time*2>`
(SIM@251c4) (H).

### 2.4 point (22 bytes) (H)
`id, cond, pick, s16 unused(-1), s16 rel, i32 x, i32 y, i32 z`. x/y = ground plane, z up (always 0
except 9 points). World units: map spans about ±500000. If `rel` != 0, x and y hold point *ids* and the
point = P[x] + P[y] (never used in shipped data). script.dat: 12 bytes (x,y,z).

### 2.5 heading (10 bytes) (H layout, M semantics)
`id, cond, pick, s16 unused, s16 value`. script.dat: s16 value. Two authoring conventions exist:
older files use degrees (0,90,180,270,0,45,…,315; 12 entries), C3/C6 files use 16-bit binary angles
(0, 4004, 8190 … ≈ k·360/16 deg). **Quirk:** SIM@1dd62 stores `(value << 14) & 0xffff` as the rotation,
i.e. only the low 2 bits survive – headings are effectively broken in the original. Groups with no
heading face from their first to second path point (SIM@1f0bc). Recommendation for the remake: interpret
values ≤ 360 as degrees, otherwise as 65536-per-turn.

### 2.6 path (10 + 2n bytes) (H)
`id, cond, pick, s16 unused, s16 n, s16 point_id[n]`. script.dat: `s16 n, s16 point_index[n]`.
Used by groups as waypoint routes (patrol / player nav points).

### 2.7 area (12 bytes) (H)
`id, cond, pick, s16 kind, s16 p1, s16 p2`. kind 0: axis-aligned rectangle between points p1 and p2;
kind != 0 (always 1): circle around point p1 with radius `p2 * 10` world units (SIM@1cb48, 1cb94;
distance is 2-D, SIM@63c64). script.dat: 3 words (kind, p1 index, p2 index-or-radius).

### 2.8 region = trigger (30 bytes) (H layout; M names)
| off | field |
|---|---|
|0..4|id, cond, pick|
|6|type: who must be inside one of the areas (SIM@1f87c, table 0x923c0): 0 the player herc, 1 any member of the player's group, 2 any unit of an active team-0 (human) group, 3 any unit of an active team-1 (cybrid) group, 4 any unit of an active herc group, 5 any unit of an active flyer group|
|8|param (mostly 1; not read by the trigger code found; L)|
|10|8 x area id (-1 = unused)|
|26|var (mission.var index, -1 none)|
|28|op: 6 = var += 1, 5 = var = 0 (SIM@1cc5c)|

Runtime (16 bytes, SIM@1df44): type, param, nAreas, areas*, fired flag (+0xa), var, op.
A region **fires once** (sets `fired`, applies the var op). It fires when its presence test is true
(checked every frame, SIM@59994 → 1f87c), or when an object that references it as alert/death region
is alerted/destroyed (§2.9). Effects of firing: var op, and **activation of groups** whose
`spawn_region` is this region (SIM@5991a: each frame, a group with a region pointer stays dormant –
no AI, not drawn, not hittable, not counted by triggers – until `region.fired`, then the pointer is
cleared).

### 2.9 herc (106 bytes) (H layout unless noted)
| off | field | notes |
|---|---|---|
|0..4|id, cond, pick||
|6|u6| -1 / -99 / 1 / 2; dropped by the shell (L)|
|8|flag0|block word 0; non-zero sets unit flag `obj+0x91` (SIM@1eb0d). Values 0–9 (M: skill/pilot level?)|
|10|unk|block word 1; if ≥ 0 stored at `obj+0x1e6` (values 25–256) (L)|
|12..47|block words 2–19|always 0|
|48 (0x30)|type| SIMVOL0/NAM/MECHS.NAM index: 0 ROADRUNNER 1 GUNSLINGER 2 RAPTOR 3 TOMAHAWK 4 PATRIOT 5 PANTHER 6 HERCULES 7 COLOSSUS 8 MONGOOSE 9 SCORPION 10 MIRIMAC 11 RAMSES 12 ACHILLES 13 APOLLO 14 BULLDOG 15 SPIDER|
|50 (0x32)|weapon[10]|weapon id per hardpoint (index = mount's hardpoint byte); -1 → 17 = none (SIM@c3b1)|
|70 (0x46)|point| start position (-1: placed by group/formation)|
|72 (0x48)|heading|heading id|
|74 (0x4a)|var| mission var changed when this unit dies (SIM@d77c)|
|76 (0x4c)|op| 2 var+=1, 1 var=0, 13..16 var=1..4 (table 0x91640)|
|78 (0x4e)|ammo[10]|per hardpoint ammo/missile variant, default 5 (SIM@c405: launcher type 0x15 with 5 → 0) (M)|
|98 (0x62)|f62|always 2, not read by the sim loader (L)|
|100 (0x64)|alert_region|fired when the unit is hit (SIM@1f496) or an enemy comes within 50000 (SIM@e722) (M)|
|102 (0x66)|death_region|fired when destroyed (SIM@13699) (M)|
|104 (0x68)|health|<100 → starts damaged; 0..80 thresholds in SIM@12f20 (M)|

script.dat = bytes 8..105 (98 bytes). Legacy 88-byte layout: identical up to 0x4e, then
`u4e, f62, alert_region, death_region, health`.

### 2.10 flyer (64 bytes)
`id, cond, pick, u6, block[20] (word0 = flag0), point(0x30), heading(0x32), type(0x34: 0 SKIMMER,
1 HOVTANK – FLYERS.NAM; all shipped are 0), var(0x36), op(0x38), alert_region(0x3a),
death_region(0x3c), health(0x3e)`. script.dat = bytes 8..63 (56). (H, SIM@1ec07)

### 2.11 struct (24 bytes)
`id, cond, pick, u6, type(8), point(0xa), heading(0xc), var(0xe), op(0x10), alert_region(0x12),
death_region(0x14), health(0x16)`. script.dat = bytes 8..23 (16). type = index into
SIMVOL0/DAT/BASES.DAT (9 entries, 0–8; SIM@3cbc switch per type); the owning group's team selects
human or cybrid version. Health values other than 100 (0, 3, 50, 75 …) = pre-damaged/ruined (M).

### 2.12 group (88 bytes) (H layout; M semantics)
| off | field | notes |
|---|---|---|
|0|id||
|2|cond||
|4|u4| -1 / -99 / 2; no pick for groups (L)|
|6..45|block[20]| word 0 = flag0 (0/1), rest 0|
|46 (0x2e)|kind|members are 0 hercs, 1 flyers, 2 structures|
|48 (0x30)|formation|0–4, index into MFORMS.DAT (hercs) / FFORMS.DAT (flyers) / BFORMS.DAT; used with the member slot (SIM@12ee8 → 1a098)|
|50 (0x32)|orders|initial AI state. Hercs (SIM@1892c, table 0x91d14): 1 search/destroy, 3 ramming, 6 guarding, 7/8 patrolling, 10 sleeping, 11 travelling (fast hercs "bulldog travel"); others keep the default. Flyers (SIM@1c46c): 1 search and destroy, 6/10 sleeping, 7/11 scouting, 8 patrolling. Player group: 11 is changed to 8 (SIM@1f014)|
|52 (0x34)|point|group position (used for structures/static groups)|
|54 (0x36)|heading||
|56 (0x38)|path|waypoint route (patrol route, player nav points)|
|58 (0x3a)|members[8]|object ids of the `kind` section|
|74 (0x4a)|team|0 human, 1 cybrid (runtime byte grp+0x14)|
|76 (0x4c)|target_kind|0 group, 1 herc, 2 flyer, 3 structure (GO@341c5, SIM@1d070)|
|78 (0x4e)|target|id → index of that kind; escort/attack/defend target used by the win tests|
|80 (0x50)|spawn_region|group dormant until this region fires (see §2.8)|
|82 (0x52)|u52|-1 / 0, not read (L)|
|84 (0x54)|var|mission var changed when the whole group is destroyed (SIM@1d524)|
|86 (0x56)|op|same codes as herc op (table 0x9222c)|

script.dat = bytes 6..87 (82). **Group index 0 is the player's squad**: its members are replaced by the
hercs from `player.mec` (SIM@1efbc); its path is the player's nav-point route.

---------------------------------------------------------------------------------------------------------

## 3. script.dat (H)
```
s16 header[10]                       (§2.3)
s16 n; n x {i32 x, y, z}             points
s16 n; n x s16                       headings
s16 n; n x {s16 k; s16 point[k]}     paths
s16 n; n x {s16 kind, p1, p2}        areas
s16 n; n x 24 bytes                  regions  (type, param, area[8], var, op)
s16 n; n x 98 bytes                  hercs    (MSN herc bytes 8..105)
s16 n; n x 56 bytes                  flyers   (MSN 8..63)
s16 n; n x 16 bytes                  structs  (MSN 8..23)
s16 n; n x 82 bytes                  groups   (MSN 6..87)
```
Readers: SIM@1d850 (preload + region/area/path tables), SIM@1e638 (object creation, group creation via
SIM@1cff4). The copies in demo tapes are zero-padded to 4558 bytes.

## 4. mission.var (H layout, M meaning)
200 bytes = 100 × s16 "mission variables", shared shell ↔ sim. Before compiling, the shell sets
(GO@359d9): campaign: var1 = campaign index, var2 = mission slot (from pilot record); single: all 0,
var1 = 99. Both: var3 = time-of-day option, var4..var6 = random(12). The sim modifies vars through
triggers/deaths and writes the file back (SIM@1d7eb). Higher vars carry campaign state between
missions (MSN conditions on var15+; ENG text switches on var7, 13, 20, 96–98 …). The shell uses var0
(`aad58`) as the debrief index.

## 5. Mission result / debriefing (M)
SIM@f4e8 (per frame) decides if the mission is over using header word 3 (mission type, jump table
0x9173c): 0 objective flag `+0x8c+0xd`, 1/2 player group reached the end of its path, 3 flag
`+0x8c+0xe`, 4/5 target-group test SIM@f99a, 6/8/9 target group state == 4 (destroyed), 7 escort
(target reached end of its path and alive). Common end codes: 2 ejected, 3 player killed, 8 left map,
7 out-of-bounds warning.
SIM@f0f0 computes the debrief code written to results.dat: per type, 1 = best result (objective plus
bonus), `2 + damage` = objective done with player damage level 0–3 (3 = herc lost), `6 + damage` =
failed (exact formula differs per type). The shell shows `DEB:` chunk number (code − 1) (verified
against B0_C0_0A texts). Mission counts as **failed** if `code > threshold[type]`, thresholds
(GO table 0x7ec80, one value per mission type), exported to `campaign.json` `outcome_threshold`
(`tools/export_missions.py`).

### 5.1 Win test details (H code, M meaning; implemented in `ES1WinRules`)
* Order (0xf4e8): ejected → 2, killed → 3; if the player group's orders are 6 (guarding), target status (0xee84) ≥ 3
  ends it as failed (4/6); then the type test; status 9 = objective done and the player safe, 10 = done but an enemy is
  close (the mission goes on), else per-type "in progress" codes (table 0x91728).
* Target status 0xee84: object → 0..3 by damage (0..255: <50, <128, <192, else 3), 4 destroyed; group (0xecc0) → 4 all
  lost, 3 ≥ 500/1024 lost or mean damage > 192, 2 ≥ 250/1024 or > 128, 1 > 50.
* Safe 0xf744(X): no living, active (group +0x16 = 0, i.e. not dormant) enemy that knows X (0xd808) within 80000 units
  (100000 if its target is X); for X outside the player's group also no enemy whose group's order target is X (0x1ce3c).
  0xf99a(group G): G's target (group: every member) is safe.
* Objective flags (0x15f80, the player each frame): type 0 sets +0xd once the player's target is an object of the
  squad's order target ("ID with the targeting computer"); type 3 sets +0xe after standing within 10000 units of the
  order target (0x1cda0: a group's first member), facing it ±45° (torso included), through the link timer (two 5000 ms
  stages, table 0x91ce8); stepping away resets it. Type 5 sets +0xd within 40000 units of the target (message only).
* Death / alert regions: a unit's death fires its `death_region` (SIM@13699), a hit or an enemy within 50000 its
  `alert_region`; many campaign missions chain their reinforcement waves this way (e.g. B0_C0_4A, 3B).
* Remake rule: types 0 / 3 also end won when every active hostile unit and structure is destroyed.

## 6. Demo tapes (TAPES/*.TAP) (H)
vcr.cpp, SIM@58e74: sequence of `u32 len + bytes` for script.dat, player.mec, mission.var, prefs.cfg,
restore.dat, object.str, keyjoy.cfg, then the recorded input stream. DEMO1/2 = SM_SCR01
(zone 1004), DEMO3 = SM_PTL01 (zone 2305), DEMO4 = SM_RAD01 (zone 2300), all single-mission mode with
options ammo 1, damage 1, difficulty 2, visibility 0, time 0. `python tools/mission.py tape <file>`.

## 7. ENG text (GO@19453) (H)
```
u16 1
repeat: char tag[4] ("BRF:", "OBJ:", "DEB:"), u32 size, body[size]
body: u16 text buffer size; OBJ: + u16 objective count; then items:
  0x01 u16 len, char text[len] (NUL-terminated piece; pieces are concatenated)
  0x02 u16 var, u16 n, u16 offs[n], (s16 lo, s16 hi)[n], then case texts (u16 len + text) at
       base+offs[i]; case i (i < n-1) is shown if lo_i <= mission.var[var] <= hi_i; base+offs[n-1] = end
  0x10 end of chunk
```
One BRF, one OBJ (one item per objective line; 15 files have none), N DEB chunks (debrief by index, §5).
Switch vars seen: var3 (time of day in briefings), 4, 7, 13, 20–98.

## 8. Zone file ZONE<n>.DAT (SIM@20238) (H layout)
`u16 unknown (0/2), u16 n, n × {s16 shape, i32 x, i32 y, i32 z, u16 rot[3]}` – terrain features
(mountains etc.): `shape` indexes the grid shapes of `<terrain>.DGS` (desert/temper/ice/urban),
`<terrain>.DAT` has 24-byte per-shape records. rot = 1/65536 turns (only yaw used). Searched in
ZONES/DAT then SIMVOL0/DAT. WORLD0–3.DAT in ZONES/DAT not decoded (shell map data, L).

## 9. Campaign structure (GO, M)
* `bst\batlsets.bin`: `u32 n, u32 pool size, u16 offs[n], strings` → btlset_0.dat, btlset_1.dat,
  btlset_2.dat (GO@13f01 loads one by index; which index the game passes was not traced – L).
  btlset_0 contains `any_msn.dat` random slots and the C7 files; btlset_1/2 are identical to each other,
  have no random slots and contain the B0_C3_1A/3A/4A/5A/7A and B0_C6_* files; test_btl.dat = debug.
* `btlset_N.dat`: `u8 nCampaigns; per campaign: u8 nSlots; per slot: u8 nVariants, NUL strings`.
  A string without ".MSN" is a list file (`any_msn.dat`, …: `u8 n, NUL strings`) from which a mission is
  picked at random (GO@140a5 → 20289).
* Variant in a slot (always 2): index 0 if the previous mission succeeded, 1 if it failed
  (GO@159e9: var0 > threshold[type]). E.g. C0 slot 3 = 3A after success, 3B after failure.
* After the last slot the next campaign is chosen by the last result (GO table 0x7ead0):
  C0→C1 / C2, C1→C3 / C4, C2→C3 / game over, C3→C5 / C6, C4→C5 / over, C5→C7 / over,
  C6→C7 / over, C7→victory (99) / over. In btlset_0 C6 reuses C5's list and "B0_C6_*" files only appear
  in btlset_1/2 (H for tables, M for interpretation).
* Campaign index selects terrain (§2.3) and var1. Naming `B<battleset>_C<campaign>_<slot><variant>`,
  `SM_<type><nn>` single missions (type ASS assault, ESC escort, PTL patrol, RAD raid, RCN recon,
  SAR search & rescue, SCR scramble?, SCT scout). `msn\sing_msn.dat` = same format as btlset with one
  campaign: 8 categories (rcn, sct, ptl, rad, scr, sar, ass, ass) → random file within the category
  (GO@36649). `car\c_armory.dat`, `car\s_armory.dat`, `car\car_init.dat`, `car\sm_init.dat` = initial
  herc/armory lists for campaign and single play (not decoded here).

## 10. player.mec (SIM@1d9af, layout M)
`u16 ?, u16 n, n × 0x7e records` {+0 u16, +2 u16, +4 herc type, +6 u16 k, +8 k words, +0x20 k words,
+0x3a u16, +0x3c 26 bytes, +0x56 20 bytes (weapons?), +0x6a 20 bytes}, then 17 bytes. These hercs
become group 0's members (player is the one marked `+0x11`).

## 11. Unknown / open
* Exact semantics of region `param`, herc `u6`/block word 1/flag0 values > 1, group `u4`/`u52`, herc
  `f62`, header word 4.
* Per-mission-type debrief formulas (SIM@f0f0) only summarised.
* The "heading << 14" quirk: confirm in a running game whether initial facings are really lost.
* WORLDn.DAT (ZONES/DAT), BFORMS/FFORMS/MFORMS record layout (count 5, 7 slots each; offsets ±10000…).
