# Missile camera and player-steered missiles

Which of the original games had a missile camera and missiles the player steers, as read from the user's own
installed data and executables, and how the remake does it. Confidence: **H** = read from code and consistent
with the data, **M** = code read, meaning partly inferred, **L** = guess. Addresses: Earthsiege 1 `DBSIM.EXE`
flat-model VAs (`tools/exe.py`), Earthsiege 2 `DBSIM.EXE` PE VAs. Paths below are relative to the repo root.

## Summary

| game | missile cam | steerable missiles | controls | ECM vs. the steered missile |
|---|---|---|---|---|
| Earthsiege 1 | yes: MFD page F6 MISSILE CAM, follows the player's newest missile (any type) | EO (electro-optical) rack missiles fired by the player | hold the fire trigger; joystick / mouse axes turn it | none (EO is never jammed) |
| Battledrome | no (cameras: COCKPIT + 4 camera probes) | no (missiles seek the Herc's target) | — | — |
| Earthsiege 2 | yes: MFD page MISSILE CAM, same logic as ES1 | EO rack missiles fired by the player | as ES1 | none |
| Starsiege | no working one (an unbound, unimplemented "Use Projectile Camera" action) | no (heat / radar homing after lock) | — | ECM / thermal diffuser jam homing missiles |
| Tribes | no | no (only the base rocket turret's heat seeker) | — | — |
| Tribes 2 | no (the tutorial's `MissileCamera` is a fixed scripted camera) | no (lock-on seekers) | — | flares, heat |

## Earthsiege 1

**Missile cam page (H).** MFD mode F6 is MISSILE CAM (`docs/formats/cockpit.md` 3.7; label in
`gamedata/es1/cockpit/strings0.json`). Its class is built at `0x360c0`: a small 3D view of its own (scene,
camera, `SMLWLD2` horizon silhouette) in the MFD display rect. Update `0x364f8`:
- The tracked missile is the global `[0x93914]`. The rocket launch routine `0x7748` stores every new rocket there
  when the shooter is the player (flag `shooter+0x8c+0x11`, `0x783a`), whatever its guidance type.
- While the missile lives, the eye is put 500 units (about 2 m) behind it along its heading, with the
  missile's orientation (`0x36620..0x3668f`), and the page renders the 3D scene.
- When it is gone, the page looks for a blast object within 10000 units of the last eye position (`0x36690`).
  While one exists it stays on it and the frame colour alternates between palette 0x3c and 0x3f (`0x36552`).
- With no missile the page shows the launcher text and a blinking lamp (`0x367e0`). The remake already draws this
  text (`CockpitMfd`).
- The page is chosen with the MFD buttons / F6. No code was found that switches to it on launch.

**Steering (H unless marked).** Rocket update `0x7198`:
- `0x72b8`: if the shooter is the player and the rocket's sub-type is 3 (EO; types SARH/ARH/ARM/EO,
  `docs/formats/gameplay.md` 4), it calls `0x70dc` with the player's input block `0xb17ac` and sets the
  "steering" word `[0xb5bc6]`. Otherwise it homes normally (`0x6eb4`).
- `0x70dc`: if button 1 (the fire button: bit 0 of the input buttons, `0x4ccf3`) is held, yaw changes by
  `0x500 x stick_x / 256` and pitch by `0x500 x stick_y / 256` per frame (`0x5e7f8` is a multiply >> 8; 0x500 is
  7.03 degrees, at the nominal 10 Hz frame about 70 degrees/s). The input is then consumed.
  If the button is not held, the rocket's target is cleared and its type set to 0 (`0x717e`). From then on it
  flies straight with no guidance.
- The input is consumed by the first EO rocket updated each frame, so only one missile is steered at a time (M).
  The list order was not checked; the remake lets the newest one steer.
- Lifetime: ROCKETS.DAT word 1 = 80 frames (`0x7247`), i.e. 8 s at 10 Hz
  (`gameplay/projectiles.json` "rockets").
- When the rocket expires while being steered, `0x73b4` latches button 1 (`0x4d8c8`), so it must be released before
  the trigger works again.

**The player's Herc meanwhile (M).** Player input `0x4ced2..0x4cf4a`: while `[0xb5bc6]` is set, the stick
axes feed the missile. The Herc's turn / twist commands (`0xb1894`, `0xb1898` and their sources) are zeroed. The
throttle is untouched, so the Herc keeps walking at its set speed and stays fully vulnerable. A pitch-invert option
(`[0x95814]`) flips the Y axis. The firing-chain check `0xce1c` reports "busy" while steering, so the held trigger
fires nothing else.

**ECM (H).** In the homing code, EO (type 3) skips the ECM deflection (`0x6ffb`). ARM (type 2) also skips it, and the
others are deflected by up to `0xc00` (16.9 degrees). The steered path never reaches that code. The ES1 readme
(`original/INSTALL/README`, ECM section) also says ECM jams only SARH and ARH.

## Battledrome

There are no missile-camera views. The camera list is COCKPIT + PROBE 1..4 (`tools/bd_hud.py` `CAMERA_NAMES`,
0x771a4), and the readme's camera notes are about probes. Missiles seek the firing Herc's target
(`docs/formats/bd_weapons.md`, steering `0xf238`), with no player input.

## Earthsiege 2

The code is the ES1 code ported to Win32 (H):
- EO steering is `0x40a488`, called from the rocket update at `0x40a636` when the shooter is the player and the
  sub-type is 3. It uses the same `0x500 x stick / 256` per frame. Releasing the button clears the target and
  type (`0x40a526`).
- `0x40a644` sets the steering word `[0x4d25aa]`. Expiry while steered latches the button (`0x40a765`).
- The frame is 125 ms, so the catalog's 56.25 degrees/s turn rate is exact.
- The missile cam keeps the tracked missile in `[0x49c394]`, set at launch for the player (`0x40aae1`). Its view
  code at `0x43fe1c` uses the same 500-unit eye offset (`0x43ff57`).
- A missile that dies before its lifetime ends sets `[0x49c398]` (`0x40a78a`). The page then flashes between two
  colours for 0x1e timer units.
- EO skips ECM (`0x40a394`; `docs/formats/es2.md` section 9 lists EO as jammable, which this corrects).
- The MFD label MISSILE CAM is in `gamedata/es2/cockpit/strings0.json`.

## Starsiege, Tribes, Tribes 2

These come from scripts and executables read by a research pass. No player-steered missile exists in any of them.
- **Starsiege:**
  - An action "Use Projectile Camera" is defined (`starsiege/extracted/scripts/action.strings.cs`,
    `actionTable.cs`). It is not in the allowed-actions list and no keymap binds it. `Starsiege.exe` has no
    projectile-camera class (its cameras are orbit, fly, combat, flyby and similar).
  - Missiles home by track type H (thermal) or R (radar), with turn rates in `datProjectile.cs`.
  - ECM pods and the thermal diffuser carry jam chances (`datIntMounts.cs`).
- **Tribes:** only the base rocket turret's `SeekingMissileData` (heat). The Scout's rocket is unguided. There is
  no missile camera (`tribes.exe` cameras: observer, flying, edit).
- **Tribes 2:**
  - The missile launcher fires a lock-on seeker (`missileLauncher.cs`: seek radius 300, max seek angle 8, flares
    pull it away).
  - `MissileCamera` in Training1 is a fixed observer camera for a tutorial scene.

## The remake

- **Tracking / steering:** `game/games/es1/missile_steering.gd` (`MissileSteering`, one per Herc).
  - It tracks the newest missile a player (no `ai` meta) fires from an Earthsiege 1/2 weapon.
  - It steers an EO one while that weapon's fire group trigger stays held: `Projectile.apply_steer`, at the
    missile's turn rate (ES1 70.3 degrees/s, ES2 56.25 degrees/s).
  - Releasing the trigger calls `Projectile.drop_guidance` (straight flight).
  - The group does not refire while steering, and stays latched after the missile is gone until the trigger is
    released.
  - AI EO missiles still home on the target, and are not jammed by ECM (`Projectile.ECM_IMMUNE_GUIDANCE`).
- **Controls:** hold the trigger that fired the EO missile (default right mouse / LB for missiles), then steer with
  the mouse (each movement turns it, capped at the turn rate) or the right stick (rate, like the original stick).
  The Herc keeps its throttle and does not turn (`PlayerPilot`, `PlayerFlightPilot`).
- **Pitch:** Options > Controls > "Missile steering pitch" (`MissileSteering.pitch_mode`, saved). Default "as the
  original game". The ES1 parser of `DATA/KEYJOY.CFG` (`0x4d918`, keyword MISSILE, flag `[0x95814]`) reads
  DEFAULT (up steers up) or REVERSE. The shipped ES1 file says REVERSE; the ES2 file says Default.
- **Homing cap:** every ES1 missile now turns at most 0x500 per frame, at Packs.TICK_HZ frames per second
  (`PackWeaponLoader.make_missile_turn_rate_deg`, about 70.3 degrees/s, was 140). The ES2 catalog already derives
  56.25 degrees/s from the same cap at 125 ms frames.
- **ES1 EO lifetime:** the rocket table's 8 s (`PackWeaponLoader._rocket_lifetimes`) instead of a range-based
  lifetime, so the missile can be flown as in the original.
- **Camera:** `game/games/es1/missile_cam.gd` (`MissileCam`, a SubViewport sharing the battle's world). The eye
  is 500 units behind the missile, looking along its flight. After a hit it holds for 1 s (remake value), then ends.
  It is shown in two places:
  - the cockpit MFD MISSILE CAM page (F6, `CockpitMfd`), with the original's flashing frame colours on a hit;
  - the remake's `MissileCamWindow` (HUD panel style, range readout), shown while a missile flies unless the MFD
    already shows the page. It is placed clear of the cockpit's or HUD's windows, the chat and the objectives
    panel (`ChatPlacement.is_clear`, searched from the bottom right), with a smaller picture when needed.
- **Window toggle:** `missile_cam_toggle` (M, no pad default) and Options > Display > "Missile cam window"
  (`DisplaySettings.missile_cam_window_on`, default on) switch the window. The original's page was likewise
  chosen at will.
- **LAN:** clients send `"missile_steer"` (the stick) in their controls while steering. The host steers the real
  missile. The weapon fx `projectile` args gain the shooter's net id (index 4), so every peer's visual copy is
  adopted by the shooter's `MissileSteering`. Snapshots append the stick at index 16
  (`HercSnapshots.SNAP_MISSILE_STEER`; index 15 is the soldier block or null), so other peers' copies follow the
  same stick.
- **Tests:**
  - `game/tests/missile_cam_check.tscn` (headless): steered hit off-axis, release, non-steerable and AI missiles
    ignore the stick, camera rules, net fields.
  - `game/tests/missile_cam_shots.tscn` (window) writes `renders/missile_cam_{mfd,window,hit}.png`.

**Open:**
- The original missile cam's field of view.
- ES1's exact blast hold time and ES2's timer unit for the flash.
- Which of two EO missiles in flight keeps the stick (list order).
