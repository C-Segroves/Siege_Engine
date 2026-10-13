# Legal-hygiene audit (copyrighted game content)

> **Re-audit 2026-10-12 (public release):** 1,398 files. The full results are in `docs/PUBLIC_RELEASE_AUDIT.md`.
> - New copied tables in the format docs were cut to example rows (G1), and full UI sentences were paraphrased (G2).
> - Two hard-coded datablock / exe tables in code were moved to import (G3, G4).
> - The theme now embeds our own check icons.
> - Personal paths were replaced, and third-party notices plus bundled license texts were added.
>
> The policy below is unchanged.

Date: 2026-10-10. This audit is read-only and covers the 657 paths that `git add -A --dry-run` would add:
245 `.gd`, 247 `.uid`, 78 `.py`, 43 `.tscn`, 25 `.md`, 8 `.gdshader`, 4 `.json`, 3 `.ps1`, 1 `.txt`, 1 `.tres`,
1 `project.godot` and `.gitignore`. The policy under test is that the repository holds no content from the
original games or their manuals. Original data may only reach the user by being extracted from their own
discs at import time.

## Summary

| rank | count |
|---|---|
| Must-fix before public | 2 (fixed) |
| Should-fix | 6 (fixed) |
| Fine (checked, keep) | 12 groups |

What was checked:
- **Binaries and blobs.** The tracked set has no binary files and no images, audio, video or fonts. There are
  no base64 or hex blobs: the only 80+ character runs are `====` comment rulers.
- **Embedded resources.** No `.tscn` or `.tres` embeds an image or a resource; the theme uses a `SystemFont`.
- **Game text and scripts.** No verbatim briefings, dialogue, credits, manual paragraphs or Starsiege/Tribes
  `.cs` script source were found. The only TorqueScript in the repo is the synthetic test snippet in
  `game/tests/test_ss_script.gd:28-30`.
- **Git history.** It is clean: one commit holding `.gitignore`, `LICENSE` and `README.md`.

## Must-fix before public

### M1. Original ES2 flight-model files used as runtime data — FIXED 2026-10-10
Fixed: `FlightPresets` no longer stores the FM words; it reads the Razor/Skimmer FM from the user's imported ES2 catalog (`flight_model`) and falls back to the remake's own `GENERIC_JET`. `flight_check` asserts only structural properties.

- **Where:** `game/engine/flight/flight_presets.gd:26-30` (`FM_RAZOR`, `FM_SKIMMER`). They are used at `:119`
  and `:127`, and also by the tests at `game/tests/flight_check.gd:42-47`.
- **What it is:** a word-for-word copy of the two original 27-word files `SIMVOL0/FM/RAZOR.FM` and
  `SKIMMER.FM` (the comment says "Original FM files ... used when the ES2 pack is not installed"). They drive
  the ES1 Skimmer and every small Starsiege flyer even when no ES2 disc was imported. That breaks the
  "only from the user's disc" rule. The legal risk is low, since these are small functional parameters, but it
  is a direct copy of original files.
- **Remedy:**
  - When ES2 is installed, take the FM only from the ES2 catalog (`flight_model`, which the importer already
    exports).
  - When it is not, replace the constants with the project's own generic jet preset: hand-tuned values in
    metres and seconds, not the original words.
  - Change `flight_check.gd` to decode a FM taken from an installed pack, or a synthetic one.
  - `docs/formats/flight_model.md:31-49` may keep the field layout. It can keep the two value columns as
    examples, or reduce them to one example.

### M2. Tribes `FlierData` datablocks hard-coded as the data source — FIXED 2026-10-10
Fixed: `export_tribes_vehicles.py` writes each Tribes 1 flier's `flier_data` from the user's `scripts/vehicle.cs` at import; T2 attitude limits are read from the Tribes 1 scripts when imported (else the remake's own generic values); `FlightPresets.TRIBES_FLIERS` is gone (fallback `GENERIC_HOVER`).

- **Where:** `game/engine/flight/flight_presets.gd:38-46` (`TRIBES_FLIERS`: Scout, LAPC and HAPC, about
  10 fields each). They are used at `:149` and `:165`, by `game/tests/flight_check.gd:67`, and named by
  `tools/export_tribes_vehicles.py:192`.
- **What it is:** values copied from `scripts/vehicle.cs` on the Tribes disc. Tribes 1 vehicles get their
  flight values only from this constant, not from the disc. The HAPC record is also the fallback for every
  large Starsiege flyer.
- **Remedy:**
  - Have `export_tribes_vehicles.py` parse the `FlierData` blocks of `vehicle.cs` at import and write
    `flier_data` into the catalog, the same way the Tribes 2 path already does.
  - Delete `TRIBES_FLIERS`.
  - For the large-flyer fallback, use the project's own generic hover preset.
  - Trim `docs/formats/flight_model.md:72-78` to one example column, or keep it as documentation.

## Should-fix

### S1. Complete Battledrome weapon stat table and AI loadout table in the docs — FIXED 2026-10-10
Fixed: `bd_weapons.md` keeps the record layouts and rules; the weapon table is cut to 3 example rows, the bay
table and the AI loadout table to 2, the per-missile cruise/accel list to one example. Each points to
`gamedata/bd/gameplay/weapons_engine.json` / `loadouts.json` written by `tools/export_bd_weapons.py`.

- **Where:**
  - `docs/formats/bd_weapons.md:116-131`: every weapon with price, damage, refire, speed, range,
    capacitor and ammo.
  - `docs/formats/bd_weapons.md:274-285`: the default AI loadout and components of all 10 Hercs.
  - `:247-258`: the bay table, which is a smaller issue.
- **What it is:** these copy whole game data tables. The exporter already extracts them at import
  (`tools/export_bd_weapons.py`, which writes `loadouts.json` and the weapons JSON).
- **Remedy:** keep the record layouts (`:43-95`) and the behaviour rules. Cut the value tables down to 2-3
  example rows, and point to the generated `gamedata/bd/...` files for the rest.

### S2. Content catalogues with stat tables in the Starsiege, Tribes and Tribes 2 docs — FIXED 2026-10-10
Fixed: the Herc, armour and vehicle tables are cut to 1-2 example rows; the name catalogues (Starsiege
tanks/flyers/weapons, mission titles, multiplayer, Tribes and Tribes 2 map lists, T2 weapon stats) are
replaced by counts, one example and a pointer to the generated `gamedata/<pack>/gameplay/*.json` and
`maps/`. Same treatment for the newer docs: `tribes_infantry.md` (armour values), `tribes_vehicles.md`
(FlierRocket datablock, vehicle stats), `flight_model.md` (the FM value columns are gone, the layout stays;
FlierData reduced to one Scout example). `weapon_mounts.md`, `animation.md`, `cockpit.md` and `shell.md`
hold only layouts, addresses and our own resolution rules: kept.

- **Where:**
  - `docs/formats/starsiege.md:76-89` (13-Herc stat table), `:107-112` (example weapon stats) and `:124-130`
    (mission titles and multiplayer map names).
  - `docs/formats/tribes.md:52-57` (armour datablock values).
  - `docs/formats/tribes2.md:60-64` (armour table), `:78-85` (vehicle table) and `:90-97` (map list).
- **What it is:** facts and names, mostly derived or rounded, so the legal risk is low. Together, though,
  they amount to a fairly complete copy of the game data.
- **Remedy:** keep the format and field documentation. Reduce each table to a few example rows, or replace
  it with a reference to the catalog the importer generates.

### S3. No trademark or non-affiliation notice — FIXED 2026-10-10 (README)
- **Where:** `README.md` (top) and `LICENSE`.
- **What it is:** the README names Metaltech, Earthsiege, Starsiege, Tribes, Dynamix and Sierra. That use is
  nominative and fine, but there is no disclaimer.
- **Remedy:** add a short "Legal" section to the README:
  - The game names are trademarks of their owners.
  - The project is not affiliated with or endorsed by them.
  - You need your own original discs.
  - The MIT license covers this code only, not any game content.

### S4. `.gitignore` gaps — FIXED 2026-10-10
These are hygiene issues; nothing copyrighted slips in today.
- **Negation overridden:** `.gitignore:215` (template `export_presets.cfg`) comes after
  `!game/export_presets.cfg` (`:25`), so the presets file stays ignored. Delete the template line, or move
  the negation to the end.
- **No backstop for converted assets.** A converted asset dropped into `game/` would be committed today.
  Add patterns such as `game/**/*.png`, `*.jpg`, `*.ogg`, `*.ogv`, `*.wav`, `*.mp3`, `*.flac`, `*.dts`,
  `*.vol`, `*.vl2`, `*.smk`, `*.avi`, `*.iso`, `*.bin`, `*.cue`, `qa/` and `**/packs/`. Use explicit `!`
  negations if an own icon or texture is ever added.
- **Missing directories:**
  - An `es1/` per-game tree (in case one is ever made, alongside `bd/`, `es2/` and the others).
  - `user_data/` or similar.
  - Godot `*.translation` is already covered.

### S5. Personal paths in tracked files — FIXED 2026-10-10
These are privacy issues, not copyright.
- **Where:**
  - `docs/QA_REPORT.md:7` and `:16` (`<local path>`, scratchpad path).
  - `tools/sync_lan_copy.ps1:6`.
  - `tools/tests/test_mission_port.py:17`.
  - Multiple disc-folder paths (`<iso dir>\...`) in the README and docs; replaced with placeholders on 2026-10-12.
- **Remedy:** use an environment variable such as `GODOT` or a relative or placeholder path.

### S6. A few one-line in-game strings quoted in the docs — FIXED 2026-10-10
Fixed: the replay prompts in `es2_campaign_flow.md` and the status texts in `es2.md` §10.4 are paraphrased
(the status ids and the string file stay); `tools/cockpit.py` mockup shows a neutral `MESSAGE LINE`. The
weapon range numbers in `es2.md` are scale evidence, not text: kept.

- **Where:**
  - `docs/formats/es2_campaign_flow.md:26` ("The war is lost. Replay the mission?").
  - `docs/formats/es2.md:462-463` (two status messages) and `:263` (weapon range text).
  - `tools/cockpit.py:449` (mockup text `COMMANDR: PROCEED TO NAV 1`).
- **What it is:** brief quotes used for documentation. They are acceptable as they are.
- **Remedy:** keep them, but make sure no longer passages get added. This is listed only so it is reviewed
  once.

## Fine (checked, keep)

| item | where | why fine |
|---|---|---|
| `tools/pack_meta/*.json` (4 files, 1.2-1.9 KB) | `tools/pack_meta/` | Our own scale calibration and notes. They cite a handful of values as evidence (heights, a few speeds and ranges, script field names). They hold no tables or text from the games. |
| Theme | `game/engine/ui/siege_theme.tres` | `StyleBoxFlat` colours and a `SystemFont`. Since 2026-10-12 it also embeds four 20x20 check and radio icons, which are our own 2-3 colour swatches in the theme colours, not game art. No font. |
| Scenes and shaders | 43 `.tscn`, 8 `.gdshader` | No embedded `Image` or `PackedByteArray`, and no external asset references (png, ogg, ttf and so on). Shaders are our own code. |
| `project.godot` | `game/project.godot` | No icon or boot splash from the games. |
| RE format docs | `docs/formats/*.md`, `docs/RE_NOTES.md` | Offsets, field layouts, exe addresses, formulas and a few example values. This is interoperability information, not copied tables (except S1 and S2). |
| Exe signature checks | e.g. `tools/export_es2_weapons.py:64-76`, `tools/export_bd_weapons.py:45-60`, `tools/units_calib.py:26-58`, `tools/export_es2_world.py:60-68` | Byte patterns of 3-8 bytes used to verify the exe version. These are interoperability facts. |
| Identifier lists | `game/games/es1/mission_runtime.gd:14-15`, `game/games/es1/mission/es2_mission_resolver.gd:7`, `tools/export_es2_units.py:58`, `tools/mission_es2.py:51`, `tools/export_economy.py:38-42`, `game/games/es1/mission/es2_unit_catalog.gd:19` | Unit and weapon type index → short name, the names the file formats use. Optional: read them from `MECHS.NAM` and `WEAPONS.DAT` instead. |
| Small rule tables | `game/games/es1/mission_runtime.gd:16`, `game/games/es1/mission/es1_msn_compiler.gd:6`, `tools/mission.py:759-761`, `game/games/es1/shell/shell_style.gd:14` | Engine-logic constants (thresholds, campaign graph, palette indices) recovered by reverse engineering, needed to reimplement the behaviour. |
| Hand-written mapping tables | `tools/export_es2_weapons.py:227-246`, `game/engine/pack_vehicle_loader.gd:33`, `game/games/es1/mission/es2_unit_catalog.gd:10` | Our own classification, fallback and evidence notes. |
| Derived calibration tables | `docs/formats/units.md:209-243`, `docs/formats/es2.md:246-257` | Our own measurements and computed values, with a few manual heights cited as evidence. |
| UI strings | `game/engine/ui/**`, `game/games/es1/battle/battle_exit.gd` and others | Our own wording. Pilot names come from the disc at runtime (`GarageEconomy.make_pilot_names`). |
| Tests | `game/tests/*.gd`, `tools/tests/*.py` | Synthetic fixtures (fake CD images, tones, mini-scripts). Asserts use ids and short facts and load data from installed packs, not embedded copies. Exception: `flight_check.gd` (M1, M2). |
| Music renderer | `tools/hmi_fm.py`, `tools/hmi_digi.py`, `tools/hmi_song.py`, `tools/render_music.py`, `tools/music_games.py`, `tools/music_situations.py` | Driver behaviour reimplemented from RE; the FM driver's frequency, velocity and slot tables, the patch banks and the drum samples are read from the user's own `HMIMDRV.386` / `*.BNK` / `DRUM32.DIG` at import time. Only small situation facts (sound ids, region and campaign track choices) are in the code. All audio is written to `gamedata/`. |
| Release and build scripts | `tools/package_release.ps1`, `tools/build_importer.ps1` | Ship the engine and importer only, and state that no game content is included. `sync_lan_copy.ps1` copies `gamedata` only to the user's own machines. |

## Ignore coverage (verified with `git status --ignored`)

Ignored as intended:
- `original/`, `extracted/`, `gamedata/` (unanchored)
- `/bd/`, `/es2/`, `/tribes/`, `/starsiege/`, `/tribes2/`
- `/out/`, `renders/`, `/dist/`, `/build/`
- `game/.godot/`, `*.import`, `__pycache__/`
- `USER_TODO.md`, `game/override.cfg`

Godot user data and imported packs live in `%APPDATA%` and are outside the repository.

One file is ignored by mistake: `game/export_presets.cfg` (see S4).
