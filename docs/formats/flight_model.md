# Flight model — player and AI flyers

Only two original games let the player fly: **Earthsiege 2** (the Razor) and **Tribes** (Scout, LAPC,
HAPC). Every flying vehicle in the remake flies by one of those two models, shared by the player and
the AI:

| code | role |
|---|---|
| `game/engine/flight/flight_model.gd` | `FlightModel`: state (speed, heading, pitch, bank, velocity, landed), ground contact, the original rate law, `create()` |
| `game/engine/flight/jet_flight_model.gd` | `JetFlightModel`: Earthsiege 2 FM (style `"es2"`) |
| `game/engine/flight/hover_flight_model.gd` | `HoverFlightModel`: Tribes FlierData (style `"tribes"`) |
| `game/engine/flight/flight_presets.gd` | parameters per catalog vehicle: FM decoding, Tribes datablocks, scaling for other games |
| `game/engine/flight/flight_controls.gd` | one frame of stick input (throttle, roll, yaw, pitch, lift) |
| `game/games/es1/flyer.gd` | `Flyer` vehicle: moves its body by the model, carries pitch/bank on the visual model |
| `game/games/es1/flyer_ai.gd` | `FlyerAI`: patrol / strafing-run brain, steers through `FlightModel.make_steering` |
| `game/games/es1/player_flight_pilot.gd` | `PlayerFlightPilot`: SiegeInput actions → stick input |
| `game/tests/flight_check.tscn` | presets, hover model, injected-action flight (take-off → ceiling → turn → land), AI patrol |

## 1. Earthsiege 2 (DBSIM.EXE 1.0) — evidence

### 1.1 Loading
`SIMVOL0/FM/<RAZOR|SKIMMER>.FM`, 54 bytes, read with the volume reader (`0x492e48`, size `0x36`):

- Herc types with `type+0x50 != 0` (the Razor) load it into `type+0x1dc` (`mechsys.cpp`, `0x420416`);
- flyer types (`flyersys.cpp`) load it into `type+0x3a` (`0x422f72`).

Both loaders then compute `FM+0x0e = fixdiv(d5 - d6, d7 - d8)` (`0x47df5c`, 16.16), the ceiling slope.

### 1.2 Layout (7 words + 10 dwords)

| off | meaning (where used in the flight step `0x466a54`) |
|---|---|
| +0x00 w0 | max pitch rate, and pitch demand at full stick (angle units / frame) |
| +0x02 w1 | max roll rate / roll demand at full stick |
| +0x04 w2 | max rudder (yaw) rate / demand |
| +0x06 w3 | pitch acceleration limit per frame |
| +0x08 w4 | roll and yaw acceleration limit per frame |
| +0x0a w5 | speed change per frame towards the target speed (`0x467a24`) |
| +0x0c w6 | unused |
| +0x0e d0 | ceiling slope (d5 − d6) / (d7 − d8) |
| +0x12 d1 | rate damping, /1024 of the rate lost per frame |
| +0x16 d2 | pitch self-level shift (`-pitch >> d2` with no stick: effectively none) |
| +0x1a d3 | roll self-level shift (`-bank >> d3` with the stick released) |
| +0x1e d4 | turn shift: heading change per frame = `-bank >> d4` (coordinated turn, `0x467047`) |
| +0x22 d5 | ceiling above the ground at maximum speed (Razor: 234 m) |
| +0x26 d6 | ceiling at minimum speed (23 m) |
| +0x2a d7 | maximum speed (units / frame); the HUD maps it to the shell km/h (`0x41bb3c`) |
| +0x2e d8 | minimum speed (throttle at idle) |
| +0x32 d9 | sideslip / vertical drift kept per frame, /1024 (`0x466c26`) |

Only the layout is documented here. The words themselves are read at import from the user's
`RAZOR.FM` / `SKIMMER.FM` (`tools/export_es2_units.py`, catalog field `flight_model`); for example
the Razor's d7 (maximum speed) is 1500 units / frame.

Frame = 125 ms (frame scale 256 = 125 ms, `0x46774c`, `units.json` `seconds_per_tick`). In the shared
1/256 m world the Razor flies at 7.8–46.9 m/s with a ceiling of 23–234 m.

### 1.3 The step (`0x466a54`, called by the Razor wrapper `0x41bb9c` and the flyer AI `0x422251`)
1. Throttle −0x400..0x400 (stick input × 8 clamped, or incremented by `input × 100 >> 8` per frame).
2. Target speed = d8 + (d7 − d8) × (throttle + 0x400) / 2048, minus `pitch × 62 >> 10` nose up or
   `pitch × 250 >> 10` nose down; speed approaches it by w5 per frame.
3. Ceiling = d6 + (speed − d8) × d0. Above it the pitch demand becomes
   `min(demand, −excess × 10 >> 10)` (split over pitch and yaw by the bank, `0x466e0a`).
4. Rates (pitch, roll, yaw): `rate += clamp(demand, ±accel) − rate × d1 / 1024`, clamped to ±max.
   Demand = `w × stick >> 8`; with the roll stick released `−bank >> d3`.
5. Heading −= `bank >> d4` (inverted: `(bank + 0x8000) >> d4`).
6. Velocity: forward = speed along the nose; body-frame sideways and vertical components × d9/1024.
   No gravity, no lift term: altitude only changes through the nose.

Player input (`0x4609ea`): stick X = roll, stick Y = pitch, rudder = yaw (mouse X added), throttle.
Keyboard flags (`mech+0x20e`) give full roll, or roll towards ±0x1000 (22.5°).

## 2. Tribes — evidence and approximations
`tribes/extracted/scripts/vehicle.cs`, `FlierData` (units are metres and seconds, tribes.md §4):

| | Scout |
|---|---|
| maxSpeed / minSpeed | 50 / −2 |
| lift | 0.75 |
| maxBank / maxPitch | 0.5 / 0.5 |

Example values; `tools/export_tribes_vehicles.py` writes each flier's full `flier_data` from the user's
`vehicle.cs`.

The Darkstar flier physics live in the (undecoded) engine, so the meanings are **approximations**:
accel = fraction of maxSpeed per second; lift × 20 m/s² (Tribes gravity) = vertical acceleration;
maxAlt = hard ceiling above the ground; maxVertical = climb/sink rate cap; maxBank × 3 /s = turn rate;
maxBank / maxPitch = visual attitude limits; hover height 2 m (ground cushion when not descending).
The Tribes fliers are in the catalog (tribes_vehicles.md): `tribes:SCOUT`, `LAPC`, `HAPC` name their
preset (`"flight_preset"`); the Tribes 2 Shrike, Thundersword and Havoc carry FlierData-style values derived
from their FlyingVehicleData forces (`"flier_data"`, incl. `hoverHeight`).

## 3. Controls (actions, docs/CODING_STANDARDS.md §2)

| action | ES2 jet | Tribes hover craft |
|---|---|---|
| `throttle_up` / `throttle_down` | throttle idle (minimum speed) .. full | forward speed; below 0 = reverse |
| `throttle_stop` | idle | stop |
| `turn_left` / `turn_right` | roll (bank → coordinated turn) | yaw |
| mouse / right stick X | rudder | yaw |
| mouse / right stick Y | pitch | nose pitch (forward speed → climb) |
| `ascend` / `descend` (Space / left Ctrl, pad A / X) | nose up / down | lift up / down |
| `torso_center` | centre the virtual stick | same |

Mouse motion deflects a spring-centred virtual stick (full at 0.12 rad of mouse look, recentres at 3/s).
Fire groups, targeting and `view_toggle` are unchanged. Strafe: neither original has one.

## 4. Remake additions (not in the originals)
- Bank limit 75°, pitch limit 60° (the original lets a keyboard pilot roll inverted).
- Hard ceiling: no climb above 1.25 × the original (soft) ceiling, which slow-pitching scaled craft
  would otherwise overshoot.
- Taxi, take-off and landing for jets (ES2 flyers never land): on the ground the throttle drives the
  wheels (brake 0.3 × max speed per second), nose-up input above the minimum speed lifts off;
  below 25 m with the stick centred a steeper dive eases to a −6° glide; any touchdown lands, faster than
  12 m/s sink is a hard landing (40 hull damage per m/s).
- Player jets spawn 40 m up at cruise; hover craft spawn landed.
- AI flyers steer with an autopilot on the same model (`make_steering`); patrol points count as reached
  at 60 m (banked turns are wider than the old flat turns).

## 5. Vehicles and presets
| vehicle | preset |
|---|---|
| `es2:RAZOR` (original player flyer, own cockpit) | its FM |
| `es2:SKIMMER` (Landskimmer) | its FM |
| ES1 Skimmer (AI only, not in the ES1 catalog) | ES2 Skimmer FM at the ES1 speed (SKIMMER.DAT max 1200, cruise 1000 units / 100 ms) |
| Starsiege flyers under 10 m tall (Advocate, Consul, Draco, both Banshees) | Razor FM scaled to the catalog max speed; turn per bank from `turn_rate` at 75° bank; pitch rate from `pitch_rate` |
| Starsiege flyers 10 m and taller (dropships, cargo ship, conveyor, escape ship) | Tribes HAPC at the catalog speed / accel / turn rate; maxAlt × size (height / 3 m, ≤ 250 m), maxVertical × √size (≤ 20 m/s) |
| Tribes fliers `tribes:SCOUT` / `LAPC` / `HAPC` | their FlierData (`flight_preset`) |
| Tribes 2 Shrike / Thundersword / Havoc | `flier_data` from FlyingVehicleData (tribes_vehicles.md §5) |

All catalog flyers are pilotable (`flyer` flag; Starsiege `kind: "flyer"`). Flyers without original
cockpit art start in the chase view; the plain HUD shows a bank/pitch line, altitude above the ground
(red above the ceiling), vertical speed and LANDED.
