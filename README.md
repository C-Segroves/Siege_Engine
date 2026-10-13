# Siege Engine — native rebuild of the Earthsiege / Starsiege / Tribes games (Godot 4)

A fan rebuild of the Dynamix *Metaltech: Earthsiege* series as one native Windows game in Godot 4.6. It covers
Metaltech: Earthsiege (1994), Metaltech: Battledrome (1994), Earthsiege 2 (1996), Starsiege (1999),
Starsiege: Tribes (1998) and Tribes 2 (2001). Siege Engine contains **no game content**: it plays the original data
it converts from **your own discs**, with LAN multiplayer and modes that mix the games.

[![Support me on Ko-fi](https://img.shields.io/badge/Ko--fi-support%20Siege%20Engine-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/csegroves)

## What the repository contains: code only
No game content is (or may be) committed: no disc files, no converted assets. The app imports the player's
own discs (.iso) itself, using the bundled disc importer, and stores the converted packs per user in
`%APPDATA%\Godot\app_userdata\Siege Engine\packs\<pack>` (`Assets.user_packs_dir()`). Supported discs:
Metaltech: Earthsiege (`es1`), Metaltech: Battledrome (`bd`), Earthsiege 2 (`es2`), Starsiege: Tribes (`tribes`),
Starsiege (`starsiege`, disc 1 holds everything converted so far), Tribes 2 (`tribes2`).
`.gitignore` keeps `original/`, `extracted/`, `gamedata/`, the per-game dev trees (`bd/`, `es2/`, ...), `dist/`
and `build/` out of git.

## Setup (development)
Players: download a release, start `SiegeEngine.exe` and import your discs from the library. No Python is
needed. For development:
1. Install [Godot 4.6](https://godotengine.org/download/archive/) (4.6.3 is what the project is tested with) and
   Python 3.10+, then run `python -m pip install -r tools/requirements.txt` (pyopl is the DOSBox OPL emulator
   that renders the Earthsiege FM music; it is optional).
2. Import discs, either
   - in the app: open `game/project.godot` in Godot 4.6, run, "Import disc (.iso)..." (a source checkout runs
     `python tools/siege_import.py`), or
   - from the command line: `python tools/siege_import.py import --out gamedata <iso dir>\earth_siege.iso`
     (the old one-step dev pipeline `python tools/import_disc.py <iso>` still writes `original/`, `extracted/`
     and `gamedata/es1/` in the repository).
3. Run. The app uses the user packs folder, or a checkout's `gamedata/` when no user packs exist.
4. Personal paths for the helper scripts (Godot exe, disc folder, LAN copy target) come from parameters or
   environment variables (`GODOT`, `SIEGE_ISO_DIR`, `SIEGE_GODOT_DIR`, `SIEGE_LAN_TARGET`). The PowerShell
   tools also read the git-ignored `tools/local_settings.ps1`; copy `tools/local_settings.example.ps1` to create it.
   Tests are Godot scenes in `game/tests/` (run headless with `--audio-driver Dummy`) and Python scripts in
   `tools/tests/`.

## Disc importer (`tools/siege_import.py`)
Command-line contract (used by `game/engine/importer.gd`):
- `identify <iso|cue|bin>` → one JSON line `{"game","pack","name","disc","discs","needs":[],"audio_tracks":n}`
  or `{"error"}` (reads only the disc directory).
- `import --out <packs_dir> <iso> [<iso> ...]` → JSON progress lines `{"stage","progress","message"}`, then
  `{"done": true, "pack": "<id>"}` or `{"error": "..."}`. Options: `--work <dir>`, `--keep-work`.
- `games` → supported games.

Each game has a module in `tools/siege_games/` (`es1`, `bd`, `es2`, `tribes`, `starsiege`, `tribes2`): a disc
signature (`identify`) and its conversion steps, which run the exporters in-process. Exporters resolve their
folders through `tools/siege_paths.py`: `SIEGE_WORK` (disc files / unpacked archives; default the repository
root, i.e. `original/`, `extracted/`, `bd/installed`, `es2/extracted`, ...) and `SIEGE_PACKS` (default
`gamedata/`). An import works in a scratch folder in `%TEMP%` and installs `<packs_dir>/<pack>` only when every
step succeeded; exporter output goes to `%TEMP%\siege-import-<pack>.log`. Each pack gets `pack.json` (name,
default palette, `provides`, importer version, source discs) and `units.json`. Packs never depend on each other.

## Discs with CD audio
Starsiege's soundtrack (and the music of Tribes / Earthsiege 2, if your disc has audio tracks) is Red Book
CD audio, which a WinCDEmu `.iso` cannot hold. Provide each such disc in one of two ways:
- **.iso + ripped tracks**: rip the audio tracks (EAC, foobar2000, Windows Media Player; FLAC or WAV, MP3/OGG
  also work) into a folder named like the .iso, next to it, keeping the track numbers in the file names:
  `<iso dir>\starseige_disc_1.iso` + `<iso dir>\starseige_disc_1\Track 02.flac`, `Track 03.flac`, ...
  (`02 - Track 2`, `starsiege (Track 03)` etc. are recognised; audio-only numbering from 01 is shifted to 02).
- **BIN/CUE image** (ImgBurn / CDRWIN; one .bin or one .bin per track): import the `.cue` (or any of its
  `.bin` files) - the data track (MODE1/MODE2 2352) and the audio tracks are read from the image.

The import converts the tracks to `<pack>/audio/cd/track_NN.ogg` (Vorbis q6) plus `audio/cd/tracks.json`
(`[{track, file, seconds, use, ...}]`; Starsiege adds the track names from `cdAudioTracks.cs` and the
missions that play them). Without audio the import still succeeds and says "no CD audio found".
Code: `tools/siege_cd.py`; tests: `python tools/tests/test_siege_cd.py [--exe dist\siege-importer\siege-importer.exe]`.

## Tested game versions
The importer records which release each disc holds (`pack.json` "release": version / build strings, the main
executable's and the disc image's SHA-256; `tools/disc_version.py`). The library's **Tested game versions** page
(also under Options) shows each installed game's release and gently warns about releases not listed here. Full
hashes, labels and how a release is identified: [docs/TESTED_VERSIONS.md](docs/TESTED_VERSIONS.md); the data the game
reads: `game/engine/tested_versions.json`.

<!-- tested-table:start -->
| Game | Version | Patch level | Main exe SHA-256 (first 16) | Result |
|---|---|---|---|---|
| Metaltech: Earthsiege | 1.0 CD (DOS) | none | DBSIM.EXE `e5fb35966f3c7551` | passed: import + 25/25 sandbox checks (2026-10-12) |
| Metaltech: Battledrome | 1.3.2 (DOS) | none | SIM.EXE `be20467ac28ba9ba` | passed: import + 23/23 sandbox checks, no campaign (2026-10-12) |
| Earthsiege 2 | 1.0 (Windows) | none | DBSIM.EXE `3360074881057866` | passed: import + 25/25 sandbox checks (2026-10-12) |
| Starsiege | 1.000r (retail) | none (1.003 / 1.004 not applied) | Starsiege.exe `42569d3408848481` | passed: import + 25/25 sandbox checks (2026-10-12) |
| Starsiege: Tribes | 1.0 (retail) | none (1.11 not applied) | tribes.exe `9486763a27522034` | passed: import + 25/25 sandbox checks, training missions (2026-10-12) |
| Tribes 2 | 1.0 build 21570 (retail) | none (25034 not applied) | Tribes2.exe `f32e4560c07e61ad` | passed: import + 25/25 sandbox checks, training missions (2026-10-12) |
<!-- tested-table:end -->

All six were tested on 2026-10-12, each disc alone in a sandbox (fresh data folder and user store:
`python tools/sandbox_iso_test.py --sandbox <dir> --iso-dir <iso-dir> --godot <Godot console exe>`).
Every tested disc is unpatched retail install media. The Starsiege disc 2 image at hand was a byte-identical copy of
disc 1 (a bad rip), so only disc 1 was tested; disc 2 is not needed for the converted content.

## Building a release
A release is two files attached to the same GitHub release: `SiegeEngine-<version>-win64.zip` (the app) and
`third-party-sources-<version>.zip` (the source code of the GPL / LGPL parts it bundles, see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)). Pushing a tag `v<version>` runs
`.github/workflows/release.yml`, which builds both and attaches them to a **draft** release for review. By hand:
1. `bash tools/ffmpeg/build_ffmpeg.sh build/ffmpeg` (Ubuntu or WSL with `mingw-w64 nasm pkg-config make`; or
   `docker run --rm -v "$PWD:/src" -w /src ubuntu:24.04 bash tools/ffmpeg/build_ffmpeg.sh --install-deps build/ffmpeg`)
   — the importer's ffmpeg: a small LGPL build cross-compiled from the source archives pinned (with SHA-256) in
   `tools/ffmpeg/sources.lock`, with only the codecs the importer uses (`build/ffmpeg/ffmpeg/ffmpeg.exe`, `BUILD.txt`).
2. `powershell -ExecutionPolicy Bypass -File tools\build_importer.ps1 [-InstallDeps]` — PyInstaller one-folder
   build `dist\siege-importer\siege-importer.exe` (Python, numpy, Pillow, pycdlib, pyopl included; the ffmpeg from
   step 1 goes to `siege-importer\ffmpeg\`). Build it from a clean virtual environment holding only
   `tools/requirements.txt`, so no unrelated packages are frozen in. The players need no Python.
3. `powershell -ExecutionPolicy Bypass -File tools\package_release.ps1 [-Godot <Godot_v4.6.x_console.exe>] -Zip
   -Version <version> -SourceUrl <release page URL>` — exports the app with the "Windows Desktop" preset
   (`game/export_presets.cfg`) to `dist\SiegeEngine\`, copies `dist\siege-importer\` next to `SiegeEngine.exe`
   (`importer.gd` looks for `<exe dir>/siege-importer/siege-importer.exe`), writes the license texts and
   `licenses\SOURCE-CODE.txt` (where the GPL / LGPL source is, plus a three-year written offer), and with `-Zip`
   writes both release files (`tools/third_party_sources.py` builds the sources zip). Needs the Godot export templates
   of the same version (Editor › Manage Export Templates › Download and Install, or install the `.tpz` from the Godot
   download archive); the script says so when they are missing.

Always publish both zips together, and keep old releases' source zips online as long as their app zips are.

## Playing in a browser (self-hosted)
`deploy/` sets up a small Linux server (e.g. a Proxmox LXC container) that imports the discs you copy onto it,
exports the "Web" preset with headless Godot and serves the game with nginx; a systemd timer pulls new commits
and rebuilds. Single player only in the browser (no LAN play). Settings live in a git-ignored `siege.conf`
(`deploy/siege.conf.example`). Step-by-step guide: [docs/WEB_DEPLOY.md](docs/WEB_DEPLOY.md).

**Legal:** the served site contains game data extracted from *your* discs. Keep it private (your LAN, a VPN, or
the password option) and never expose it to the public internet.

## Layout
- `tools/` — Python reverse-engineering workbench and asset converters (`vol.py`, `dts.py`,
  `gfx.py`, `export_es1.py`, `exe.py` disassembly helper), the disc importer (`siege_import.py`,
  `siege_games/`, `siege_iso.py`, `siege_paths.py`, `pack_meta/`) and the build scripts.
- `docs/` — format documentation (`RE_NOTES.md`, `formats/*.md`), design notes (`design/`), menu and command
  maps, playtest reports and audits (`LEGAL_AUDIT.md`, `PUBLIC_RELEASE_AUDIT.md`).
- `game/engine/` — game-agnostic runtime: asset loading, 3Space / Darkstar / Torque shape instancing and
  animation, palette-indexed rendering, maps and terrain, weapons and effects, infantry, vehicles and flight,
  game modes, command map, chat and radio, LAN networking, saves, UI and input.
- `game/games/<game>/` — per-game gameplay and front ends: `es1` (Earthsiege 1 and 2 battle runtime and shell),
  `es2`, `bd`, `starsiege`, `tribes` (Tribes 1 and 2).
- `game/tests/` — headless Godot test scenes; `tools/tests/` — Python tests.
- `deploy/` — optional self-hosted browser build.

## Controls
Every binding is in one input map (`game/engine/input/siege_input.gd`) and can be changed under Options; gamepads
work too. Defaults: W/S throttle, X stop, A/D turn, mouse aims (torso / view), mouse buttons fire, Z centre torso,
Space / Ctrl up and down (jets, fliers), Q next weapon, T next target, C nearest target, V cockpit or chase view,
E enter or leave a vehicle / use, N command map, M missile camera, J objectives, Tab scores, Esc menu. Infantry adds
G grenade, B mine, R pack, H repair kit; in extraction raids I opens the inventory and O calls the exfil.

## Earthsiege front end (original shell)
The library (`res://library.tscn`) is the app's main menu. Its "Metaltech: Earthsiege" entry opens a rebuild of
the original GO.EXE shell (`game/games/es1/shell/`):
intro cinematic (`video/flic/intro3.ogv`) → startup TTMs (DYNAMIX, LEAD_IN, IINTRO, EARTH_W) → blast doors
(ESIEGE2.ANM) → MAIN MENU. Any key skips the current intro piece, Esc skips the rest.
- Data: `tools/export_shell.py` (run by `import_disc.py`) writes `gamedata/es1/shell/`: palette-index PNGs for
  backgrounds / DBA sheets / DFN font atlases / cursors, palettes, decoded DLG menus + `menu_graph.json`, string
  tables, decoded TTM scripts, door-animation frames, `shell.json` (styles, menu→region, region→music,
  talking-head tables). Formats: `docs/formats/shell.md`.
- Runtime: `ShellScreen` (320×200 8-bit frame buffer + palette shader, nearest-scaled & letterboxed, palette
  fades, original ARROW cursor), `ShellFont` (DFN), `ShellMenu` (DLG renderer/input: panels, style buttons,
  CORNERS bitmap buttons, text, edit boxes, lists, hotkeys), `TTMScene` (TTM 4.14 interpreter, several scripts
  per scene, lip-sync driving from `audio/voice/shell_sync`), `EsShell` (screen flow, regions, music, careers).
- Extra entries not in the original: MAIN MENU › MULTIPLAYER (LAN host/join, `launcher.tscn` in multiplayer
  mode) and OPTIONS › DEV LAUNCHER (the old developer launcher; also F10 anywhere in the shell).
- Mission hooks: set `EsShell.launch_handler` (called with shell, mission name, campaign state) to replace the
  default skirmish launch; set `EsShell.mission_result` before returning to `res://main.tscn` to get the
  debriefing. Shell music plays `audio/music/[shell/]<track>.ogg` when present.
- Debug: `-- --shell=menu:1100 | menu:1110:1100 | talk:C0:2 | talk:D1:1 | ttm:INTRO/DYNAMIX | general | boot |
  autotest | launch:SM_RCN01 [--screenshot=out.png --shot-delay=2] [--skip-intro] [--no-movie]`.

## Units and scale across games
Every original game used its own world units. All packs are placed in one metric world
(`game/engine/packs.gd`, `WORLD_SCALE`), with code-derived conversions in `gamedata/<pack>/units.json`
(see `docs/formats/units.md`, `docs/formats/es2.md`, `docs/formats/tribes.md`):

| pack | metres per unit | basis |
|---|---|---|
| es1 | 1/256 | Earthsiege 2 manual heights + km/h table for the identical Herc models (ES1's own HUD readouts use 6 mm/unit, i.e. inflate ranges ~1.5x) |
| es2 | 1/256 | manual heights and km/h table |
| bd  | 0.00215 | Battledrome's distance readout has no unit; Hercs scaled to the Earthsiege average size |
| tribes | 1 | native metres (armors 2.0-2.6 m) |
| starsiege | 1 | Darkstar engine, same as Tribes |
| tribes2 | 1 | Torque engine, native metres |

Times and rates (refire, turn/torso rates, shield/capacitor, projectile speeds, animation-driven
ground speed) always come from each game's code. Override a pack's scale with
`"world_metres_per_unit"` in its `pack.json`. Versus matches can use **Balanced** stats (cross-game
speeds matched per weight class) or **Original** stats.

## Status
Work in progress, playtested regularly (`docs/PLAYTEST_*.md`). All six games import and pass the sandbox checks
(see Tested game versions).
- **Earthsiege 1:** original shell, campaign and single missions (compiled exactly like the original), cockpit
  instruments, worlds, terrain and lighting, units, weapons and damage from the original data, faithful HMI FM
  music, sounds, intro and ending cinematics, saves.
- **Battledrome:** Hercs, weapon pods and the arenas for versus and skirmish; no campaign (the original's arena
  ladder is not rebuilt).
- **Earthsiege 2:** campaign and training missions in the Earthsiege battle runtime (Hercs, Cybrids, bases,
  heightmap terrain, the mission compiler, objectives, timers and orders, campaign flow and unlocks).
- **Starsiege:** Human and Cybrid campaigns and training missions (binary `.mis` plus the mission scripts run by
  the remake's Darkstar script interpreter), the 24 multiplayer maps, Hercs, tanks and fliers, cockpits and HUD
  colour schemes, CD-audio soundtrack.
- **Starsiege: Tribes and Tribes 2:** infantry with armours, weapons, packs, grenades, mines and jets; pilotable
  vehicles; bases with generators, stations, turrets and lights; training missions; multiplayer maps (Tribes 37,
  Tribes 2 52) with the original game modes (CTF, Capture and Hold, Defend and Destroy, Find and Retrieve,
  Deathmatch, Hunters, Rabbit, Bounty, Siege and others; `docs/formats/game_modes.md`) and AI bots.
- **Across the games:** a saga campaign (Earthsiege 1 → Earthsiege 2 → Starsiege, Human or Cybrid); arena and
  versus matches that mix Hercs, vehicles and infantry from every installed game on any arena map, with
  **Balanced** or **Original** stats; LAN co-op and versus for up to 24 players (host-authoritative), with AI bots
  and lobby chat; a command map for orders to wingmen and teammates in every game (`docs/COMMAND_MAP.md`); a missile
  camera (`docs/MISSILE_CAM.md`).
- **Extraction mode** (the remake's own, not in any original): raids with factions, loot, a stash, a shop and
  vehicle call-ins, transports that drop you in and fly you out (`docs/design/extraction.md`).
- **Browser build:** single player only, self-hosted (see above).
- Known gaps and open work are tracked in `docs/STANDARDIZATION_AUDIT.md` and the playtest reports.

## Supporting the project
Siege Engine is free. If you enjoy it and want to chip in, you can buy me a coffee on
[Ko-fi](https://ko-fi.com/csegroves). Donations support development only; they never buy game content,
which always comes from your own discs.

## License and trademarks
The MIT license (see `LICENSE`) covers only the Siege Engine code, tools and documentation in this repository. The games it loads
(Metaltech: Earthsiege, Battledrome, Earthsiege 2, Starsiege, Starsiege: Tribes, Tribes 2) and everything
converted from their discs belong to their respective rights holders and are never part of this repository.

Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The repository's own code is
MIT. A **release bundle** also contains third-party programs under their own licenses, and some of them are
**GPL**: the disc importer bundles the PyOPL / DOSBox OPL emulator (GPL-3.0), so the importer is distributed under
the GPL-3.0, and runs our own minimal FFmpeg build (LGPL-2.1, a separate `ffmpeg.exe`). The Godot app itself
contains no GPL code. The release scripts copy every license text into the bundle (`licenses/`,
`siege-importer/licenses/`), and each release carries the matching `third-party-sources-<version>.zip`.

Siege Engine is an unofficial fan project. It is not affiliated with, endorsed or sponsored by Dynamix, Sierra,
Activision, Microsoft or any other rights holder. Metaltech, Earthsiege, Battledrome, Starsiege and Tribes are
trademarks of their respective owners and are used here only to name the games whose discs the engine can read.
