# Walker animation (all packs)

How every legged vehicle (Herc / Cybrid) chooses and plays its leg sequences, per game, and how the engine
reproduces it (`game/engine/herc_animator.gd`, `game/engine/shape_cycles.gd`).

## Common model

All three engines move a walker by the **ground displacement its own walk/run sequence authors per cycle**:
the cycle phase advances by `distance / stride`, so a planted foot stays put whatever the speed.

* 3Space (ES1, ES2, Battledrome): node 0 is a ground tracker without geometry; its transform in frame *k* is
  that frame's ground step (`y` = forward units, `z` rotation = turn). Stride = Σ node-0 `y` over the frames.
* Darkstar (Starsiege): the root node `bounds` carries the cumulative ground motion of the cycle (keys from
  0 to the stride, e.g. Talon walk 0.49 → 10.72 m). It is the parent of every detail level, so it is never
  posed; stride = last key − first key. Turn sequences rotate it instead (`z`).

The engine plays the sequence at phase `travelled / stride` (signed: reversing plays it backwards), one
footstep sound per half cycle, a turn-in-place sequence at `yaw turned / turn angle per cycle` when standing,
and a stand pose (or the default pose) when stopped. Torso twist/pitch is applied on top of the leg pose
(Battledrome's walk sways the torso node itself).

## Earthsiege 1 (DBSIM.EXE) — unchanged

Unit DAT (`gameplay.md` §2), names as in `hercs.json`:

| DAT | hercs.json | meaning | Hercs | Bulldog | Spider |
|---|---|---|---|---|---|
| +0x0c | `anim_seq_stand` (misnamed) | walk sequence (0x12547) | 1 | 3 | 0 |
| +0x0e | `anim_seq_start` (misnamed) | run sequence above `walk_seq_speed_cap` (0x125ba) | 2 | 4 | 0 |
| +0x7a | `anim_seq_7a` | turn in place: node 0 rotates 1820 units per 100-tick frame (70° per 700-tick cycle) | 6 | 1 (728/frame) | 1 (no rotation → none) |
| +0x44 | `anim_seq_shutdown` | collapse on death (0x122fc) | 7 | 2 | 1 |

`units.json hercs[]` already carries `walk_seq` / `run_seq` and the m/s-per-speed-unit factors; the engine
keeps the old stride maths for ES1/ES2 (`walk_factor × ticks × 0.256 × tick_ms`, identical to the node-0
sum) and 1 tick = 1 ms. Death plays at rate 256.
**Fixed:** the Bulldog and the Spider used the Herc layout (seq 1/2/7): the Bulldog walked with its turn
sequence, the Spider twitched in a 200-tick transition. They now use their own DAT ids.

## Earthsiege 2 (SIMVOL DBSIM) — same layout, 1.25 ms ticks

Same DAT fields and meaning (`es2.md` §speed: walk DAT+0x0c, run DAT+0x0e above DAT+0x2c, 0x416fb3).
Pitbull = Bulldog layout (walk 3, run 4, turn 1, death 2), Spider walk 0. Death now plays on the 1.25 ms
tick (`anim_tick_seconds`). Razor/Skimmer are flyers (no gait).

## Battledrome (SIM.EXE 1.3.2)

`Animate` (0x2a880) switches on the **current sequence** (jump table 0x7955c):

| seq | case | meaning |
|---|---|---|
| 0 | 0x2a8c4 | walk: rate = speed·256/V_walk (V_walk = seq-0 node-0 displacement per 2000 ticks) |
| 1 | 0x2a8a6 | stand: rate 0 (3-tick still pose) |
| 2 | 0x2a8c4 | run, entered when the rate ≥ w24 (200, Ronin 250) |
| 3 / 4 | default | torso pitch (node 12) / torso yaw (node 11) lookup sequences |
| 5 | 0x2a926 | turn in place at rate turn/80 (node 0 rotates 1820 per frame, 70° per cycle) |
| 6 | 0x2a962 | fixed rate w25 (60): the collapse (hips drop 2300 → 650 units) |

Exported as `units.json hercs[]` `stand_seq 1, walk_seq 0, run_seq 2, turn_seq 5, death_seq 6`
(`tools/units_calib.py`, which checks the switch bytes). Run switch speed = authored walk speed ×
w24/256; death at 60/256 of rate 256; 1 tick = 0.512 ms at rate 256.
**Cause of the slide:** the engine always played seq 1 (the 3-tick still pose) as the walk and had no stride.

## Starsiege (Darkstar DTS v7 + datHerc_*.cs)

Every Herc/Cybrid DTS has `Seq00_walk, Seq01_run, Seq02_stand, Seq04_squat, Seq05_t22, Seq06_t45,
Seq07_cockpit/cpit, Seq08_frun, Seq09_fall, Seq10_land, Seq11_LLeg, Seq12_RLeg`. From the tracks:

* `walk` / `run` / `frun`: cyclic, `bounds` moves forward (Talon 10.2 / 29.7 / 45.9 m per cycle).
* `t22` / `t45`: turn in place, `bounds` rotates 4094 / 8188 units (22.5° / 45°) per cycle.
* `stand`: the standing pose (also the exported default pose); `fall`/`land`: jump poses; `squat`,
  `cockpit`, `LLeg`/`RLeg`: single-pose sequences (not used).

`hercAnim(toStandVel, toRunVel, toFastRunVel m/s, toFastTurnVel deg/s)` in each `datHerc_*.cs` gives the
switches, e.g. Talon `4, 10, 30, 30`. Exported by `tools/export_starsiege_gameplay.py` as
`anim {stand, walk, run, fast_run, turn, fast_turn, stand_speed, run_switch_speed, fast_run_speed,
fast_turn_rate}` (sequence names are matched by suffix).
**Cause of the slide:** `ShapeInstance` only played 3Space `sequences`; Darkstar shapes only have
`ds_sequences`, so nothing animated. In addition the default torso node (4) and cockpit node (11) were 3Space
indices that land on random Darkstar nodes (Talon: `Right_Calf0`, `head0`), freezing a calf.

## Torso and turret (all packs, `game/engine/torso_rig.gd`)

Vehicle def keys: `torso_node` (yaw), `cockpit_node` (pitch and view; the same node = it turns and pitches;
−1 = none, the aim alone carries the pitch and the view starts in the chase camera), `lower_body_nodes`
(children of the torso node that keep their world pose), `pitch_mounts` (the weapon mount markers pitch).
Defaults: 3Space torso 4 / cockpit 11. Weapon muzzles hang off the gun's `attach_node` in that node's frame
(`HercModel.build_mounts`: one hardpoint frame per gun, weapon_mounts.md), so pods turn with the torso.

**Starsiege (Starsiege.exe).** The engine turns one node, `head0`, for Hercs and tanks alike:
* `0x443278` finds `head0` and shares its transform with every LOD's `head*` node (`+0xfbc`);
* `0x445838`–`0x445860`: the torso / turret yaw (`+0xfd0`, moved towards the target `+0xfcc` at the rate `+0xfac`,
  wrapped by `0x443c74`) is written as `TMat3F::set(EulerF(0, 0, yaw))` on that transform each frame — yaw only;
* `0x4952c1`: a hardpoint without a node name mounts on `head0` (`newHardPoint` "Offset_fm_Node"); every
  hardpoint has its own pitch / yaw range (`X_rot_rnge`, `Z_rot_rnge`), so the weapons pitch, not the head.
* Tank shapes have no barrel nodes: `head0` (child of `Body0`) is the whole turret, the barrels are its mesh or the
  mounted weapon pods.

Export (`tools/export_starsiege_gameplay.py`): every Herc `torso_node = cockpit_node = head0` (LOD 0; the engine
also pitches it, the established cockpit-view pitch); tanks / drones `torso_node = head0`, `cockpit_node = −1`,
`pitch_mounts = true` (turret yaws, the weapon mounts pitch); guns `attach_node = head0` with `muzzle_units` =
the hardpoint offset in the head's frame (same rest positions as before). **Six Hercs hang their legs below
`head0`** (Basilisk, Minotaur, Goad, Executioner, Emancipator, Olympian; Minotaur/Goad also `Pelvis0`):
`lower_body_nodes` lists those children (leg / calf / thigh / foot / pelvis subtrees) and the rig
counter-rotates them (`L' = head_turned⁻¹ · head_rest · L`), so only the upper body and its weapons turn.
Earlier they had `torso_node −1` (no visual twist) and tanks the 3Space defaults 4 / 11 (random nodes).

**Earthsiege 1 / 2 (DBSIM).** DAT +0x1a / +0x22 (`hercs.json torso_yaw_node` / `torso_pitch_node`, misnamed)
are lookup **sequence** ids, not node indices: DBSIM 0x11652 / 0x11682 start an anim thread on that sequence
(0x1f48) and 0x14ac8 sets its position to `yaw >> 2` (0x620c4 indexes the shape's sequence list and sums the
frame lengths). `PackVehicleLoader._es_torso_nodes` takes the topmost node that lookup really turns (riders
under 1024 units ignored; of several, the one under the torso): every Herc and biped Cybrid seq 0 / 5 → nodes
4 / 11 (the old defaults, unchanged), **Bulldog** seq 0 / 7 → 19 / 20, **Pitbull** 0 / 7 → 6 / 19 (the turret and
its gun, part 5 = the weapon mount), **Headhunter** 0 / 5 → 5 / 12, **Spider** −1 / −1 (no twist).
**Cause of the Pitbull/Bulldog "front leg turns perpendicular":** without these keys the rig used the Herc
defaults 4 / 11 — on the quadrupeds node 4 is the front-right hip and 11 the rear-right thigh, so the torso
twist (±180°, free turret) yawed a front leg sideways and the aim pitch swung a rear leg; the cockpit view
also sat on that thigh. Headhunter twisted its pitch node 4 and pitched a leg, the Spider twisted a hip.
The leg sequences themselves were correct (planted-foot slip 0.03).

**Battledrome.** `torso_node` = the node SIM.EXE's yaw lookup sequence 4 turns and `cockpit_node` = the node of
the pitch lookup sequence 3 (`PackVehicleLoader._bd_torso_nodes`, from the shape: Stryder/Thor/Viper … 11 / 12,
Phantom 12 / 13, Slayer 13 / 14, Talon 13 / 13 — its yaw sequence turns the three pod nodes below 13). The 3Space
defaults 4 / 11 twisted a leg on the Talon, Nomad and Slayer and put the Talon/Slayer view on a leg. Pods sit on
their logical part's node (`bd_weapons.md` §6); the loader attaches each muzzle to that node (offset = part
offset + muzzle offset, default rotations 0) instead of the shape root, so torso pods follow the twist and
pitch while hip mounts (mine pods, Stryder's missile pod on node 4) stay with the legs as in the original.

## Remake polish (not in the originals)

All three originals snap between sequences and Starsiege has no death sequence. The remake adds, in
`game/engine/herc_animator.gd` with `pose_blend.gd` and `walker_collapse.gd`:

* **Cross-fades.** A change of clip (stand / walk / run / fast run / turn in place) cross-fades over
  `HercAnimator.TRANSITION_SECONDS` (0.3 s, smoothstep weight): each node's local transform is slerped
  (rotation) and lerped (offset) from the outgoing to the incoming pose; a node only one of them poses uses its
  default transform on the other side. The outgoing clip keeps playing at its own phase (walk and run share
  `gait_phase`, so the feet stay in step); a switch during a cross-fade fades from the pose shown last.
  Measured over every walker, walk and run (and fast run) are authored in phase — the same phase gives the
  closer pose than half a cycle apart for every ES1/ES2/Starsiege gait (Starsiege mean node difference 0.10–0.33
  rad vs 0.36–0.70), Battledrome is about even — so no phase offset is applied. A death sequence (ES1, ES2,
  Battledrome) is cross-faded in from the last leg pose over `DEATH_BLEND_SECONDS` (0.2 s). Outside a cross-fade
  every pose is the original sequence pose (ES1 strides and poses are unchanged; `transition_seconds = 0` snaps
  like the originals). `apply_stand` (hangar, respawn) still snaps and resets unposed nodes to their default.
  The torso twist / pitch (`TorsoRig`) is applied after the blended leg pose; during a cross-fade `animates()` is
  true for the nodes of either clip.
* **Procedural collapse** (`WalkerCollapse`, walkers without a death sequence, i.e. Starsiege). Over 1.5 s the
  leg nodes fold from the pose at the kill toward a crouch — the shape's own `squat` or early `land` pose, up to
  1.7× deeper than authored (measured from `stand`), each node by a critically damped approach that hangs back
  more the deeper the node sits (hips first, feet last), normalised to arrive at 1.5 s — while every root node
  (`bounds`) pitches forward 15–45° and rolls 12°; the lowest point is kept on the ground it stood on. The
  crouch, depth and pitch are the combination whose settled pose leaves the body (mean mesh centre) lowest,
  chosen once at the kill: a fixed large pitch stood Hercs with long forward guns (Gorgon, Emancipator) on their
  muzzles with their legs in the air. Every pose is a function of the seconds since the kill (puppets replay it).

## Approximations

* `toStandVel` (4 m/s) is not used: walkers walk at any speed above 0.05 m/s (the stride sync keeps the feet
  planted), and switch to the stand pose below it. Standing below 4 m/s as Starsiege does would slide a
  standing Herc over the ground at a creep (e.g. a 15 % throttle Talon), so the remake keeps the stride sync.
* Between keyframes the engine slerps each node's rotation (shortest arc) and lerps its offset; a pose at a
  keyframe is that keyframe exactly. Whether 3Space lerps the Euler angles (shortest wrap) instead is not
  verified; over every blended 3Space keyframe pair (ES1, ES2, BD) the two midpoints differ by at most 6.4°
  (Spider walk node 8, an authored 83° snap), under 5° everywhere else, and no pair needs the long way round.
* Starsiege has no death sequence: the original keeps the dead Herc's last pose; the remake collapses it
  (above).
* Starsiege: the original replaces the head's rotation with the yaw; the engine composes the yaw with the
  head's rest rotation (identical except the Rebel artillery's turned head and 2° on the Pirate Apocalypse).
  Whether the original also turns the legs of the six legs-below-head Hercs is not verified; the engine keeps
  them planted.
* The original ES1/ES2 node-0 steps differ per frame (e.g. 0, 320, 260, 160, 40 …); the engine moves the
  body at a steady speed, so within a cycle a foot can still creep (measured slow-walk slip median 0.14 of the
  body travel in every pack; ES1/ES2 Colossus ≈ 0.9 as authored).
* Battledrome plays its run at the walk's rate (`top_speed_kmh_animated`); the engine syncs the run to its own
  stride instead (feet do not skate).

## Tests

`game/tests/animation_check.tscn` (headless): every walker has a gait with ground motion, legs move at top and
slow speed, stride = authored ground motion, slow-walk slip median per pack < 0.35, standing is a fixed
pose, turning on the spot steps, ES1 strides/poses equal the pre-animator maths; for every played sequence
(walk, run, fast run, stand, turn, death) a pose sampled at a keyframe equals it and no node turns faster
between keyframes than its share of the keyframe step (no flips; Darkstar: no step over 0.35 rad per 1/256
cycle); the torso / pitch nodes carry no foot unless the rig counter-rotates it; over a stand → top speed →
stop → turn profile at 60 fps no mesh node steps more per frame inside a cross-fade window than 0.35 rad (or
1.2× the sequences' own largest step; cycle-wrap frames skipped; snapped: 0.6–1.55 rad); walkers without a
death sequence collapse mid-stride onto the ground (lowest point within 0.5 % of the height, body lower than
standing and body or top below 90 %, no node faster than 0.3 rad per frame, root tilt within the fall angle).
`game/tests/blend_strip.tscn` (windowed): per vehicle a stand → walk → run → stop strip and the death
(`renders/blend_*.png`).
`game/tests/torso_check.tscn` (headless): every Starsiege Herc / tank turns `head0`; standing and mid-stride the
twist moves the upper body and the muzzles about the torso node while every leg node keeps its world position
(also under pitch); tank turrets yaw by the aim and their barrels pitch; Battledrome pods turn with the torso.
`game/tests/twist_strip.tscn` (windowed): per vehicle twist left / centre / right / right + pitch / mid-stride +
twist, muzzles marked red (`renders/twist_*.png`).
`game/tests/anim_battle_shots.tscn` (windowed): versus chase view, skirmish AI, campaign garage Herc and a LAN
puppet all move their legs; frame strips. `game/tests/anim_strip.tscn`: side-view walk/run strips with
scrolling ground ticks.
