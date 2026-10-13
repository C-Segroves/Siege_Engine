# Public release audit

Date: 2026-10-12. This prepares the public GitHub copy (one fresh commit of the working tree, no private history).
Policy: `docs/LEGAL_AUDIT.md`. The repository holds code only, and game data reaches a player only by being
converted from their own discs. Nothing was committed or pushed.

## Publish set

`git ls-files -co --exclude-standard` (tracked plus untracked-not-ignored) gives **1,398 files, 6.4 MB**
(6,445,533 bytes; the largest file is `game/tests/e2e_driver.gd` at 91 KB). Counts include this report and
`THIRD_PARTY_NOTICES.md`.
- **By type:** 553 `.uid`, 543 `.gd`, 131 `.py`, 93 `.tscn`, 40 `.md`, 9 `.gdshader`, 1 `.gdshaderinc`, 7 `.json`,
  4 `.ps1`, 3 `.sh`, 3 `.template`, plus `.tres`, `.html`, `.yml`, `.txt`, `.cfg`, `project.godot`, `.gitignore`,
  `.gitattributes` and `siege.conf.example`.
- **Not present:** binary files, images, audio, video, fonts, models, archives, `.pck`, `.wasm`, base64 or hex blobs.
- **Deleted files:** eight tracked files are deleted in the working tree (`es1/projectile.gd`, `es1/weapon.gd`,
  `es2_targets.gd`, `target_overlay_paint.gd` and their `.uid` files). A fresh commit of the working tree leaves them
  out.

## Findings and actions

### Game content
| # | finding | action |
|---|---|---|
| G1 | Copied data tables in the docs: the BD Herc table (`battledrome.md`), the ES1 projectile damage, range, ammo and refire values and the Starsiege mine values (`gameplay.md`), ES1/ES2 prices, build times, career tech table and unlock vars (`campaign_availability.md`, `es2_campaign_flow.md`), the C_ARMORY stock (`shell.md`), the GO.EXE failure thresholds (`mission.md`), BD raw speeds (`units.md`), the splash radii (`bd_weapons.md`), ES2 manual heights, km/h and weapon ranges (`es2.md`), and the T2 vehicle-weapon datablocks (`tribes_vehicles.md`) | **Fixed:** each is cut to 1-3 example rows, and a pointer names the gamedata file the importer writes |
| G2 | Full game UI sentences quoted in the docs: MENU1240/1250/1260 (`campaign_availability.md`, `shell.md`), the Tribes 2 armour refusal messages (`tribes_vehicles.md`), and a T2 command message (`COMMAND_MAP.md`) | **Fixed:** paraphrased |
| G3 | `game/engine/collision_damage.gd` `RUN_OVER_BY_DATABLOCK`: Tribes 2 vehicle collision values (12 numbers) hard-coded as the data source | see "Code fixes" below |
| G4 | `tools/starsiege_hud.py` `FIXED_COLORS` / `SCHEMES`: RGB tables copied from Starsiege.exe (176 numbers) | see "Code fixes" below |
| G5 | Small RE constant tables in the importer: `tools/mission.py` `OUTCOME_THRESHOLD` (10 values, GO 0x7ec80), `tools/mission_es2.py` `SCRIPT_AWARD_VARS` and the unlock var maps, `tribes_stations.gd` `RESUPPLY_ROUNDS` (7 values), and the AI role weights in `game_mode_ai.gd` | **Kept**, as `LEGAL_AUDIT.md` "Small rule tables" allows: engine-logic constants needed to reimplement behaviour. Optional later: read them from the exe or scripts at import |
| G6 | Short original strings in code comments (`shell_missions.gd:10`, `match_flow.gd:305`) | **Kept:** they are one-line documentary quotes (LEGAL_AUDIT S6 class). The `shell_backups.gd` messages are not in the imported string tables, so they are the remake's own wording |
| G7 | `siege_theme.tres` now embeds four 20x20 check and radio icons | **OK:** our own 2-3 colour swatches. LEGAL_AUDIT "Theme" row updated |
| G8 | `game_modes.json`, `extraction_rules.json`, `tools/pack_meta/*.json` and `tested_versions.json` | **OK:** the remake's own wording and values, our own calibration notes, and version ids and hashes |
| G9 | Tests and fixtures (`game/tests`, `tools/tests`) | **OK:** synthetic fixtures. Asserts compare a few facts against the installed pack |

### Personal and environment data
| # | finding | action |
|---|---|---|
| P1 | `tools/sync_lan_copy.ps1` defaulted to the personal LAN share | **Fixed:** `-Target`, the env var `SIEGE_LAN_TARGET` or the git-ignored `tools/local_settings.ps1`; a clear error when none is set |
| P2 | `tools/sandbox_iso_test.py` hard-coded the Godot path under the user profile and the disc folder | **Fixed by agent N:** `--godot` / `--iso-dir`, defaulting to the env vars `GODOT` / `SIEGE_ISO_DIR`, with a clear error |
| P3 | `tools/export_skins.py` hard-coded the disc paths | **Fixed:** `--iso-<pack>`, or `$SIEGE_ISO_DIR/<file name>`; a clear error otherwise |
| P4 | Disc paths in README, `RE_NOTES.md`, `es2.md`, `starsiege.md`, `tribes.md`, `tribes2.md`, `siege_soundtrack.py`, `import_disc.py` and `LEGAL_AUDIT.md` | **Fixed:** replaced with `<iso dir>` |
| P5 | `tools/package_release.ps1` had no place for a personal Godot path | **Added:** it reads `tools/local_settings.ps1` (`$env:GODOT`). `tools/local_settings.example.ps1` is the committed template. The user's own `tools/local_settings.ps1` was created with the previous defaults (git-ignored), so nothing breaks locally |
| P6 | LAN IPs, the private Gitea URL, emails, the machine name, the WSL user name, scratchpad paths | **None found** in the publish set. `deploy/siege.conf.example` uses `git.example.lan`. The README and WEB_DEPLOY mention Gitea and Proxmox only generically |
| P7 | Names | **Resolved**: `LICENSE` names the copyright holder as chosen by the owner; the Ko-fi account is published on purpose; the kill-text examples and `fix_d_check.gd` now use the neutral pilot name "Ace" |
| P8 | `export_presets.cfg` | **OK:** relative export paths, empty company and copyright |

### Third-party code and licenses
| # | finding | action |
|---|---|---|
| L1 | No third-party notices existed | **Added `THIRD_PARTY_NOTICES.md`:** Godot (MIT plus its bundled parts), Python (PSF), the PyInstaller bootloader (GPL-2.0+ with the bootloader exception), altgraph, pefile, pywin32-ctypes, pycdlib (LGPL-2.1), NumPy (BSD-3 plus its bundled parts), Pillow (MIT-CMU), imageio-ffmpeg (BSD-2, now developer-only), FFmpeg (now LGPL-2.1, see L2), PyOPL (GPL-3.0-only), the build-only tools, and siege-studio (MIT) and ScummVM as format references |
| L2 | The bundled FFmpeg was gyan.dev's 7.1 "essentials" build, configured `--enable-gpl --enable-version3` with many external libraries (x264, x265, libvpx, ...). Its GPLv3 Corresponding Source would have to cover every one of them | **Replaced (agent R).** Releases now ship our own minimal FFmpeg 8.1.3 (`tools/ffmpeg/build_ffmpeg.sh`, MinGW-w64 cross-build), configured `--disable-autodetect --disable-everything` with only the decoders, demuxers, encoders and filters the importer uses, plus libogg 1.3.6, libvorbis 1.3.7 and libtheora 1.2.0 (BSD), and **without** `--enable-gpl`, `--enable-version3`, `--enable-nonfree`: LGPL-2.1-or-later, 5 MB instead of ~80 MB. The four archives are pinned by SHA-256 in `tools/ffmpeg/sources.lock`, each checked against the publisher (FFmpeg's OpenPGP signature, key FCF9 86EA 15E6 E293 A564 4F10 B432 2F04 D676 58D8; Xiph's SHA256SUMS). The importer finds it at `siege-importer/ffmpeg/ffmpeg.exe` (`tools/video.py` `ffmpeg_exe()`, also `SIEGE_FFMPEG`); PyInstaller excludes imageio-ffmpeg, and `collect_licenses.py` fails the build if the bundled ffmpeg is not LGPL or another ffmpeg is present. libtheora is built with `--disable-asm`: its x86 assembly produced corrupt Theora streams in this MinGW build |
| L3 | The releases did not ship license texts | **Fixed.** `tools/build_importer.ps1` now runs `tools/collect_licenses.py`, which copies the dist-info license files of every bundled package, Python's `LICENSE.txt`, the FFmpeg texts, `THIRD_PARTY_NOTICES.md` and our `LICENSE` into `siege-importer/licenses/`; the build fails if a required text is missing. `tools/package_release.ps1` copies the notices and `LICENSE`, and writes Godot's own license and third-party notices from the exporting Godot binary (`tools/godot_licenses.gd`, `Engine.get_license_text()` / `get_copyright_info()`) into `licenses/`. Both helpers were run into a scratch folder. A full release build was **not** run |
| L4 | The `darkstar_*.py`, `dts.py` and `torque_dts.py` tools follow the open-siege/siege-studio (MIT) structures | Credited with its copyright line in `THIRD_PARTY_NOTICES.md`. They are independent Python implementations, not copied C++ |
| L5 | `tools/shell.py` `dgds_rle` cites ScummVM | **OK:** a trivial RLE, written independently; listed as a reference only |
| L6 | README did not say what is MIT and what is GPL | **Fixed:** the "License and trademarks" section now says so |
| L7 | GPL / LGPL source was not shipped with releases (only links) | **Fixed (agent R).** `tools/package_release.ps1 -Zip` writes two assets per release: `SiegeEngine-<v>-win64.zip` and `third-party-sources-<v>.zip` (`tools/third_party_sources.py`: the FFmpeg/Xiph archives, `BUILD.txt` with the configure line, the build scripts, the PyPI sdists of PyOPL 2.0 and pycdlib at the bundled versions checked against PyPI's SHA-256, `git archive` of this repository, `SOURCES.md` with rebuild steps). The app zip has `licenses/SOURCE-CODE.txt` (where the source is, plus a three-year written offer: GPLv3 §6, LGPL 2.1 §6) and the full GPL-3.0 / LGPL-2.1 texts. `.github/workflows/release.yml` builds ffmpeg on ubuntu-24.04 and the app on windows-latest, then drafts a release with both assets. PyOPL 2.0's sdist was checked: `pyopl.cpp`, the DOSBox `dbopl.cpp/.h` (GPL-2.0-or-later, combined under GPL-3.0-only), headers, `setup.py`/`pyproject.toml` and `COPYING` (GPL-3.0): complete. **Verified 2026-10-13:** ffmpeg built in WSL with the script; all 103 Earthsiege 2 / Starsiege cinematics convert and decode with no errors at the source length; a frozen-importer Battledrome import gave the same files as the old GPL ffmpeg with identical audio; 43 soundtrack rips and the CD-audio tests pass; `tools/tests` 34/34; `build_importer.ps1` (clean venv, 69 MB folder) and `package_release.ps1 -Zip` were run into a scratch folder and both zips inspected. The release workflow itself has not run yet |

### Secrets
None found: no keys, tokens, passwords or private keys in the publish set.
- `.github/` holds only `FUNDING.yml`.
- The real `deploy/siege.conf` is git-ignored; `siege.conf.example` has empty `BASIC_AUTH_*` values.
- `.env` is ignored.

### .gitignore
- Already covered: `renders/`, `/dist/`, `/build/`, `gamedata/`, `original/`, `extracted/`, the per-game trees, `*.pck`,
  `*.wasm`, `*.pkl`, `*.log`, `__pycache__/`, `.godot/`, `.pytest_cache/`, `USER_TODO.md` and `game/override.cfg`.
  Test stores live in `user://test_store`, outside the repository.
- Added: `tools/local_settings.ps1`, `test_store/`, `/es1/`, `user_data/`, `*.stackdump`, and more asset and binary
  types (`*.ogv *.webm *.smk *.flc *.fli *.gif *.tga *.webp *.dds *.ttf *.otf *.pal *.mid *.xmi *.exe *.dll *.pyd
  *.zip *.7z *.tpz`).
- No tracked file matches an ignore rule (`git ls-files -c -i --exclude-standard` is empty).
- Six stray `rendersfix_d_*.png` files sit at the repository root: a test writes `renders` + name without a path
  separator. They are ignored by `*.png`, so this is harmless, but the test path should be fixed.

### README
- Updated the title and intro (all six games).
- Setup: Godot 4.6, Python, the env vars and `local_settings`.
- Layout and Controls (from the input map) are rewritten. The Earthsiege shell section is retitled, because the
  library is now the main menu.
- Units rows were added for Starsiege and Tribes 2.
- **Status** is rewritten from the playtest, command-map, extraction and tested-versions docs. Tribes is no longer
  "proof-of-life".
- Licensing paragraph added.
- Kept: Ko-fi "Supporting the project", "License and trademarks", and agent N's "Tested game versions" section.

## Decisions needed from the user
1. **Copyright holder name.** Resolved: the owner chose the name in `LICENSE`; example pilot names are neutral.
2. **GPL source for releases.** Decided: attach the corresponding source to each release (release tooling in progress). Original note: attach (or mirror) the source archives for
   FFmpeg 7.1 and PyOPL 2.0 next to it, or include a written offer. The bundle already names the exact builds.
   Another option is to drop PyOPL from public releases, which loses the Earthsiege FM music in the frozen importer
   but leaves FFmpeg as the only GPL part. A third option is an LGPL FFmpeg build, which needs another source
   than imageio-ffmpeg.
3. **Optional hardening:** read the G5 constant tables from the exe or scripts at import, like G3 and G4.

## Remaining risks
- **Facts in docs and code.** The RE docs still hold layouts, addresses and a few example values per table. This is
  interoperability documentation, as the policy accepts, but a reviewer could argue about the combined detail.
- **Inferring removed values.** The nominal km/h column in `units.md` is a conversion of the removed raw BD speed,
  so the raw value can be worked back from it. This is low risk.
- **Parallel edits.** Other agents (C, L, N) are still editing. Any file changed after this audit was not reviewed:
  re-run the greps in this report (personal paths: `Z:`, `C:\Users`, `192.168.`, the Gitea host; blobs: binary
  extensions) right before the publish commit.
- **The release build was not run end to end.** The license helpers were tested on their own; the first real
  `package_release.ps1` run should be checked for `licenses/` and `siege-importer/licenses/`.
- **Trademarks.** The game names are used nominatively with a disclaimer. Don't use any original logos or box art
  on the GitHub page.
- **The browser build** serves converted game data. `docs/WEB_DEPLOY.md` warns to keep it private, and the
  basic-auth password is off by default.
