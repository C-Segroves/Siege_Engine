# Real-world units: Earthsiege (DBSIM.EXE) and Battledrome (SIM.EXE)

Tool: `python tools/units_calib.py` writes `gamedata/es1/units.json` and `gamedata/bd/units.json`. It is the
last step of `tools/import_disc.py`. Before computing anything it checks the instruction bytes at the
addresses below, so a different exe build fails loudly. Per-Herc tables are computed from the exported
shapes and unit tables.

ES1 addresses are DBSIM.EXE VAs (file offset − 0x48FD). BD addresses are SIM.EXE VAs (file offset − 0x69CD).

Confidence levels:
- **H**: read in code and unambiguous.
- **M**: read in code, but the meaning or unit label is inferred.
- **L**: a guess.

## Summary

| quantity | ES1 | BD |
|---|---|---|
| distance | **1 unit = 6 mm** (166.67 units/m) **H** | **1 unit = 1 mm** (assumed metres) **M** |
| sim clock | variable frame; frame scale 256 = 100 ms; 120 Hz PIT | event clock in 4 ms units; Hercs update every 100 ms |
| speed field | animation rate (256 = authored speed); per-Herc m/s factor | units per 1.024 s → **0.000977 m/s per unit** (walk) |
| turn rate | angle units per frame (nominal 0.1 s) **M** | angle units per 1.024 s **H** |
| torso rate | angle units per 100 ms **H** | — |
| projectile speed | units per 100 ms → 0.06 m/s per unit **H** | units per 1.024 s (`v·dt>>8`) **H** |
| refire / timers | 2560 per s → 1/2560 s **H** | 4 ms ticks, checked in the 100 ms Herc update **H** |
| animation tick | 1 ms at rate 256 **H** | 0.512 ms at rate 256 **H** |
| angles | 65536 per turn | 65536 per turn |

**Answer to "are BD Hercs bigger?"** In raw units, BD Hercs are 1.8× taller than ES1 Hercs (2874–4520 vs
1660–2460 units). Each game's own distance readout calibrates differently: ES1 shows `units·6/1000` m and BD
shows `units/1000`. So the difference is a unit-scale difference, and the scales differ by 6×. After conversion,
BD Hercs are 2.9–4.5 m tall and ES1 Hercs are 10–15 m tall.

The BD readout has no unit label. The alternatives in `bd/units.json` are:
- `same_as_es1` = 0.006 m/unit
- `lore_matched_herc_height` = 0.0033 m/unit, which makes the mean BD Herc as tall as the mean ES1 Herc and has no code basis.

All BD speeds scale linearly with whichever value you choose.

## 1. ES1 time base

- **Timer (H).** `0x5a9f7` creates the DVTimer with PIT divisor 0x26D3 = 9939, which gives 120.0 Hz. `0x63e64` computes:
  - `Hz = 1e6 / (div·0x35A1>>14)` = 120 → `[0xbba44]`
  - `Hz/10` = 12 → `[0xbba42]`, `[0xbdbd4]`

  The IRQ handler `0x63e3c` counts down `[0xbba46]`.
- **Frame scale (H).** `0x63f40` runs once per frame from the main loop at `0x595dc`:
  - It waits until at least 2 PIT ticks have elapsed.
  - It sets `[0xbdbd0] = elapsed_ticks·256/(Hz/10)` (`0x63f04`), clamped to 64..450.
  - So **256 = 100 ms of real time**, and frames are 25–176 ms.

  Helpers built on the frame scale:

  | helper | what it does |
  |---|---|
  | `0x63fa4(x)` | `x·scale>>8`: "x per 100 ms" applied this frame |
  | `0x6410c` / `0x64178` | count a timer down by `scale`, so timers tick at 2560 units/s |

- **Per-frame (unscaled) quantities (M).** These are applied once per `Mech::update` (`0x14844`) or per control
  call (`0x12038`) with no dt. They are frame-rate dependent in the original. The remake should use the 0.1 s
  nominal frame that the scale is normalised to. Bullet lifetimes support this: 17 frames × 500 units per
  frame at 10 Hz = 85 000 units, which matches the ATC range of 70 000.

  | quantity | where |
  |---|---|
  | leg speed approach `approach(v, throttle, accel)` | `0x12198` |
  | yaw-rate approach | `0x12a71` |
  | heading += yaw rate | `0x12a9b` |
  | shield recharge, max 4 | `0xfb51` |
  | beam capacitor +20 | `0xb531` |
  | bullet lifetime counter | `0x800b` |

  The shared energy pool is time-scaled: +15 per 100 ms (`0x14eef`), clamped 0..10 000. Weapons and shields
  draw from it above 1500, so sustained recharge is limited to **150 points/s**.

## 2. ES1 movement is animation-driven (H)

- `Mech::update` → `0x14148`:
  - `0x626c8(shape, rate = mech+0x236)` sets the animation rate.
  - `0x215c(obj, 0x63fa4(100))` advances the animation by dt in ms.
- `0x62718`: `anim_time += dt_ms·rate>>8`. **1 tick = 1 ms at rate 256.**
- `0x205c` resets the ground node and advances the animation. It then adds the node-0 ground transform to the
  object position and heading.
  - `0x61c4c` composes each completed frame's node-0 delta.
  - `0x61da8` / `0x61eb8` apply and remove the partial frame linearly.
- The rate is the current speed `mech+0x224` (`0x12953`). The walk sequence uses `max(speed, 60)` (`0x12458`).
- Sequence choice in `0x12038`:
  - The walk sequence is DAT+0x0C.
  - It switches to run (DAT+0x0E) when `|v| >` `walk_seq_speed_cap` (`0x125ba`), and back to walk when slower (`0x1262e`).

So **ES1 speed is not a velocity.** Velocity in m/s is:

`v = speed × (Σ node-0 y-deltas of the sequence) / (sequence ticks) × 1000/256 × 0.006`

This differs per Herc and per sequence. Light Hercs run at 0.119 m/s per speed unit and mediums at 0.097
(table below). Acceleration (DAT+0x06, 30) is in speed units per frame. Turn rate (DAT+0x00, 600) is in angle
units per frame, so 600·10/65536·360 = **33°/s**.

Torso yaw and pitch use `0x63fa4` (`0x149ac`, `0x14ba0`):
- rate 1000 → 55°/s
- rate 800 → 44°/s

## 3. ES1 distance (H)

`0x2e2a0(d) = d/1000·6`.
- The waypoint readout calls it at `0x34a52`, after `0x645c8` gives the 2D distance, and prints `"WP n: dddd M."` (strings `0x93832`/`0x93839`).
- The SCANNER page `0x355a4` calls it for the `RNG:` and `DST:` fields (STRINGS0 groups 26/27).

So the radar ranges 30000/80000/120000 are 180/480/720 m.

Cross-checks:
- Herc heights 10.0–14.8 m (Roadrunner to Colossus).
- Roadrunner top speed 110 km/h.
- Terrain grid cell 512 = 3.07 m; ground texel 256 = 1.54 m.
- Zones span about ±7.8 km.
- Weapon ranges: ATC 420 m, LAS 300 m, MLRS 360 m.
- Cloud layer z = 10000 = 60 m.

No gravity constant was found: Herc z follows the terrain and bullets fly straight.

Projectiles: `0x8041` and `0x72f6` move by `0x63fa4(speed)`, so the projectile-table field is in units per
100 ms:
- ATC: 5000 → 300 m/s
- missiles: 6000 → 360 m/s
- EMP: 2000 → 120 m/s

The rocket speed ramps toward its cap at ROCKETS.DAT rates per 100 ms (`0x7279`). The weapon cooldown
`+0x30 = refire` (`0xaf11`) is decremented by the frame scale (`0xb44f`): 1200 → 0.469 s, 2500 → 0.98 s.

## 4. BD time base (H)

- **Timer and clock.**
  - The DVTimer uses the same divisor 0x26D3 (`0xfb5`, 120 Hz). Handler `0xfa0` increments `[0xa13a2]`.
  - Per frame, `0x1544` returns `step = avg_elapsed_ticks·25/(Hz/10)`, clamped 8..25 (fixed 25 in network lock-step).
  - The sim clock `[0x954b4]` advances by `step` (`0x15c8` → `SimManager::processEvents 0x382a0`).
  - So **1 time unit = 4 ms**. The frame loop waits ≥ 12 ticks in lock-step and ≥ 4 ticks otherwise.
- **Herc update.** A Herc WakeUp (`0x7294`) reschedules itself `+0x19` = 25 units = 100 ms later (`0x7370`), and
  everything integrates with the true `now − last` (`0x8758`, `0x2a565`).
- **Animation.** `Animate::animate` `0x2a55c` adds `dt·(rate·2000>>8)>>8` anim ticks. At rate 256 that is
  7.8125 ticks per 4 ms, so **1 tick = 0.512 ms**. Yaw += `turn·dt>>8`.

## 5. BD speed, turn, acceleration

Herc record (`0x82ffc + 0x364·k`), words:

| words | meaning | where |
|---|---|---|
| w0..w7 | 4-point throttle→speed table: (−127,−6000) (−5,0) (5,0) (127,max) | `0x44d78` interpolation, used at `0x888d` (**H**) |
| w8..w15 | speed→turn-rate table, e.g. (−6000,9000) (0,0) (6000,5000) (20000,5000) | `0x89f7` (**H**) |
| w16 | turn rate when stopped | `0x8a25` |
| w17 | mass | `0x44c08`; total mass = Herc + engine + shield + reactor + armour + weapons |
| w22..w25 | anim params: min rate 30, ?, run threshold 200, seq-6 rate 60 | Animate `+0xc..+0x18` (`0x714f`) |

The exporter's `acceleration?` label on w9 is wrong.

How speed is integrated:
- `0x874c`:
  - The speed target is the throttle table value, capped by the engine table "mass → max speed" (engine record `0x85a24+0x88·e`, +4).
  - It is reduced by damage.
  - The change is limited to `engine_force·dt>>8` (doubled when reversing direction).
- `0x8a88`: `speed += force/mass`.
- The speed is copied to `Animate+4`.
- `0x2a8c4`: anim rate = `speed·256/V_walk`, where `V_walk` is the seq-0 node-0 displacement per 2000 ticks (`0x2a3bc` → `0x2aa1c`).

The walking ground speed is therefore exactly `speed/256` units per 4 ms, i.e. **speed field = units per
1.024 s → ×0.9766 units/s**.

The run sequence (seq 2, entered when rate ≥ w24) is played with the same rate. Its true ground speed is
`speed/256 · V_run/V_walk`. This ratio is 0.9 for light Hercs and 1.6–1.9 for heavies; see
`top_speed_kmh_animated`.

Turning:
- While moving: `turn·dt>>8`, i.e. units per 1.024 s.
- In place: seq 5 plays at rate `turn/80` (`0x2a926`) with the explicit turn term zeroed (`0x2a65c`), and its
  node 0 rotates 1820 units per 100-tick frame.

`LinMove` (Herc+0x1b5, `0x2b798`: `pos = p0 + v·dt>>8`) only carries knock-back. `0x8a88` halves it every
update.

## 6. BD distance (M)

The HUD target box (`0x5fb8`) does `DIST = approx|Δ|/1000` (`0x4164e`, then `idiv 1000` at `0x61d0`). It
clamps to −999..9999 (`0x19c7c`) and prints the value after `"DIST:"` (`0x77270`). No unit string exists in
SIM.EXE, SHELL.EXE, WATEXT.BIN or MSGTEXT.BIN. Reading it as metres (as ES1 does) gives 1 unit = 1 mm:
- arena radius 65–200 m
- ceiling at 8.2 m
- Hercs 2.9–4.5 m tall
- top speeds 21–60 km/h

The gait is consistent with this: cadence at top speed is 2× ES1's for similar heights-per-second. That fits
smaller machines if the animators kept a pendulum-like gait (**L**).

## 7. Damage scale

ES1 numbers are in `gameplay.md` §4–5:
- shield and armour damage per hit
- component HP 500–2500
- shield max 3500

BD weapons, shields, armour and the damage pipeline are decoded in `bd_weapons.md` (§4–5). Conversion used by
`gamedata/bd/gameplay/weapons_engine.json`: **armour damage = BD damage × 0.5** (BD part armour 400–4800 → 200–2400),
**shield points 1:1** (SG I–VI 3000–5500 vs ES1 3500; `damage.shield` = shield points a hit removes). BD projectile
speeds are units per 1.024 s and BD refire/lifetimes are 4 ms ticks (fire checks run in the 100 ms Herc update).

## 8. Per-unit tables (generated; see units.json for all fields)

### ES1 (6 mm/unit)

| unit | side | height m | top km/h | reverse km/h | m/s per speed unit (walk / run) | accel m/s² (nominal 10 Hz) |
|---|---|---|---|---|---|---|
| Roadrunner | herc | 10.0 | 110 | 27 | 0.0490 / 0.1191 | 36 |
| Gunslinger | herc | 10.2 | 116 | 27 | 0.0490 / 0.1191 | 36 |
| Raptor | herc | 12.5 | 66 | 19 | 0.0475 / 0.0970 | 29 |
| Tomahawk | herc | 12.2 | 63 | 20 | 0.0475 / 0.0970 | 29 |
| Patriot | herc | 12.5 | 59 | 19 | 0.0475 / 0.0970 | 29 |
| Panther | herc | 13.8 | 60 | 19 | 0.0516 / 0.1045 | 31 |
| Hercules | herc | 14.2 | 56 | 19 | 0.0516 / 0.1045 | 31 |
| Colossus | herc | 14.8 | 61 | 20 | 0.0545 / 0.1205 | 36 |
| Mongoose | cybrid | 11.2 | 116 | 21 | 0.0490 / 0.1191 | 36 |
| Scorpion | cybrid | 10.3 | 116 | 21 | 0.0490 / 0.1191 | 36 |
| Mirimac | cybrid | 11.6 | 59 | 15 | 0.0475 / 0.0970 | 29 |
| Ramses | cybrid | 12.0 | 59 | 19 | 0.0475 / 0.0970 | 29 |
| Achilles | cybrid | 13.6 | 60 | 16 | 0.0516 / 0.1045 | 31 |
| Apollo | cybrid | 14.2 | 56 | 14 | 0.0516 / 0.1045 | 31 |
| Bulldog | cybrid | 17.7 | 113 | 24 | 0.0666 / 0.1964 | 59 |
| Spider | cybrid | 4.3 | 58 | 39 | 0.0542 / 0.0542 | 14 |

All ES1 units turn at 33°/s (per-frame value at the nominal 10 Hz).

### BD (1 mm/unit; multiply by 6 for the `same_as_es1` scale, by 3.3 for `lore_matched`)

| Herc | shape | height units | height m | top km/h (nominal) | top km/h (animated run) | reverse km/h | turn °/s (moving / in place) |
|---|---|---|---|---|---|---|---|
| Stryder | STRYDER | 3375 | 3.4 | 60 | 57 | 21 | 27 / 48 |
| Barretta | BARETTA | 3606 | 3.6 | 48 | 47 | 21 | 22 / 40 |
| Avenger | AVENGER | 3370 | 3.4 | 32 | 32 | 21 | 19 / 30 |
| Cobra | VIPER | 2874 | 2.9 | 39 | 34 | 21 | 19 / 38 |
| Nomad | NOMAD | 3968 | 4.0 | 32 | 36 | 21 | 22 / 23 |
| Talon | TALON | 3612 | 3.6 | 32 | 33 | 21 | 19 / 23 |
| Ronin | PHANTOM | 4010 | 4.0 | 25 | 45 | 21 | 16 / 23 |
| Slayer | SLAYER | 4240 | 4.2 | 27 | 44 | 21 | 16 / 23 |
| Judicator | VNDICTR | 4360 | 4.4 | 25 | 45 | 21 | 15 / 23 |
| Hammer | THOR | 4520 | 4.5 | 21 | 39 | 21 | 13 / 23 |

BD top speeds are the Herc throttle maximum. The installed engine can cap them further: the engine table
maps total mass to maximum speed, for example 250 DL: 1000→14000 and 2000→10000.

## 9. Open items

- BD engine `+0x24` damage table.
- Find any BD document or manual text that names the DIST unit.
- ES1 per-frame quantities are only "per 0.1 s" at the nominal rate. The original ran faster or slower with
  the machine's frame rate.
