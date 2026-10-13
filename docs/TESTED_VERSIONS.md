# Tested game versions

Siege Engine converts the game data from the player's own discs. This page lists the disc releases it was tested
with: version identifiers and hashes only, no game content. The same table is data the game reads
(`game/engine/tested_versions.json`, shown on the library's **Tested game versions** page) and is summarised in the
README.

## How a release is identified

The importer (`tools/siege_import.py`) records the disc's release in the pack's `pack.json` under `"release"`
(`tools/disc_version.py`):

| field | evidence |
|---|---|
| `exe`, `exe_sha256`, `exe_size` | the game's main executable (`GAME["main_exe"]` of `tools/siege_games/<game>.py`: on the disc, or unpacked from the install archive) |
| `version` | Darkstar version tag `V 001.000r` (Starsiege), Dynamix `Release 1.3.2 <date>` (Battledrome `code\version.cpp`), a `version 1.0` line in the disc's VERSION.TXT / Readme |
| `build` | Win32 VERSIONINFO FileVersion `0, 21570, 0, 0` (Tribes 2) |
| `build_date` | the Darkstar console's `Version / Date / Time` build stamp (Starsiege, Tribes) or the Dynamix release date |
| `label`, `mastered` | the ISO 9660 volume label and volume creation date |
| `disc_file`, `disc_sha256` | the disc image and its SHA-256 |

A pack imported before releases were recorded is identified without a new import by
`python tools/siege_import.py identify-release --pack <pack dir> <iso>` (reads only the main executable, unpacking
the install archive for Battledrome / Starsiege; about 20 s), or the **Identify** button on the versions page.
`python tools/disc_version.py <iso>` prints the record for a disc whose executable sits on the disc itself.
The game matches `exe_sha256` (then `disc_sha256`) against the table (`engine/game_releases.gd`). A pack imported
by an older importer has no record and is shown as "not identified"; a release that is not in the table gets a gentle
"untested version" note in the library and on the versions page.

All discs are install media: the executable on the disc is the unpatched retail build. None of the tested discs carries
a later patch (Starsiege 1.003 / 1.004 would show `V 001.003r` / `V 001.004r`, Tribes 1.11 a later build date than Dec 15 1998,
Tribes 2 25034 build `25034`).

## Tested releases

<!-- tested-table:start -->
| Game | Version | Patch level | Main exe (SHA-256) | Disc image SHA-256 | Volume label / mastered | Result |
|---|---|---|---|---|---|---|
| Metaltech: Earthsiege | 1.0 CD (DOS) | none | DBSIM.EXE `e5fb35966f3c755106cbeff2cfc1f2aed496bed388edab8ea2c857779efec34a` | `f93acefcca7b32d7a3e47d5f1ac25f3af081fefcf0e9e9fb5bdf4864de853629` | (none) / 1994-10-25 | passed: import + 25/25 sandbox checks (2026-10-12) |
| Metaltech: Battledrome | 1.3.2 (DOS) | none | SIM.EXE `be20467ac28ba9ba35c7c1061103a613a8f91184136fec36f6d2c694ab9c18e5` | `32c2e3073313a15a893257163c68f55104a22f49aa472cb844debef8c3ba5c9a` | (none) / 1995-02-21 | passed: import + 23/23 sandbox checks, no campaign (2026-10-12) |
| Earthsiege 2 | 1.0 (Windows) | none | DBSIM.EXE `33600748810578667ca513841406bbb4f4990eee463a8a041ea09ebd12730df3` | `ac83282ee026a2cc117f39b58e9216c1911599fe40be8a0f4aeaea47703ef515` | ES2 / 1997-12-29 | passed: import + 25/25 sandbox checks (2026-10-12) |
| Starsiege | 1.000r (retail) | none (1.003 / 1.004 not applied) | Starsiege.exe `42569d3408848481f994cf7684135d18a286a33554845d574e326711b8a8a298` | `03c5ef665958ebd8a825403f7f8868f8d9584ca0c0c0efa39ebe6c482898fc97` | STARSIEGE1 / 1999-03-05 | passed: import + 25/25 sandbox checks (2026-10-12) |
| Starsiege: Tribes | 1.0 (retail) | none (1.11 not applied) | tribes.exe `9486763a2752203477d786ec39a567349c22e10a6176b3c3413baf6a11f25050` | `1c0d35e53d55b80b086e2fcbf34db91c2ae4c0647e89c9b4a9cd799ac353a197` | TRIBES / 1998-12-17 | passed: import + 25/25 sandbox checks, training missions (2026-10-12) |
| Tribes 2 | 1.0 build 21570 (retail) | none (25034 not applied) | Tribes2.exe `f32e4560c07e61ad4f0e7dbb5abb6a38cca27b757ff272dbbada8c52b2cd9fb1` | `460df0249fc5d846b534a5c976d370df1b8d41ca590e87bd9f6630de3e5cb738` | T2_INSTALL / 2001-03-15 | passed: import + 25/25 sandbox checks, training missions (2026-10-12) |
<!-- tested-table:end -->

Tested on 2026-10-12 with `tools/sandbox_iso_test.py` (each disc alone, fresh data folder and user store).

## Disc notes

- **Starsiege disc 2**: the tested `starseige_disc_2.iso` is byte-identical to disc 1 (same SHA-256), a bad rip. The
  importer identifies it as disc 1; disc 2 is not needed for the converted content.
- **Earthsiege 1, Battledrome**: DOS discs without a volume label. Earthsiege's DBSIM.EXE carries no version string;
  the release is named by its hash. Battledrome's main program (SIM.EXE) is inside the install archive
  INSTALL/ENGLISH/RESOURCE.000 and is hashed after unpacking.
- **Earthsiege 2**: the Windows disc mastered 1997-12-29 (a later pressing; VERSION.TXT says 1.0), with English,
  French and German folders.
- **Tribes 2**: the disc's Tribes2.exe is build 21570 (FileVersion `0, 21570, 0, 0`); Readme.txt says Version 1.0.

## Sandbox test

`python tools/sandbox_iso_test.py --sandbox <dir> --iso-dir <iso-dir> --godot <Godot console exe>` imports each disc image alone into a fresh data folder and a fresh
user store, then runs `game/tests/single_pack_check.tscn` against it (the library, the campaign's first mission, an
arena battle with a bot, Tribes infantry / vehicles / training, Options, the shape viewer and the cross-pack features
without the other games) and writes `<dir>/report.md`.
