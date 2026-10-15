# Tribes: Vengeance (PC, 2004, Unreal Engine 2.5) - feasibility

Status: identified only (`siege_import.py identify` names it, "not yet importable"; `tools/siege_games/tribes_vengeance.py`, zip branch in `siege_import.py`).
Source: `TribesVengeance.zip` (3.09 GB).

## Container
The zip has only 3 members, all deflate64 (zip method 9; Python `zipfile` cannot read it, `pip install inflate64` or 7-Zip can):
| Member | Size | Magic |
|---|---|---|
| `setup.exe` | 1.0 MB | `MZ`, Inno Setup loader |
| `setup-1.bin` | 2.10 GB | `idska32 1A` = Inno Setup disk slice, data in zlib chunks (`zlb 1A`) |
| `setup-2.bin` | 0.99 GB | `idska32 1A`, slice 2 |

The game files are inside an **Inno Setup installer**, not listed in the zip. The slices are not encrypted (first stored file, an Internet shortcut, reads fine). Open-source `innoextract` handles this layout (needs the three members unzipped side by side, ~3.1 GB temp, then ~3 GB of game files). Python options: wrap `innoextract` as an external process (GPL: separate exe, list it in THIRD_PARTY_NOTICES), or write an Inno reader (L). Nothing below the installer has been inspected: package names are from engine knowledge and must be confirmed after extraction.

## UE2.5 package types (to confirm)
`.u` code (UnrealScript bytecode), `.ukx` skeletal meshes + animations, `.usx` static meshes, `.utx` textures, `.uax` audio, map packages (UE2 level files; Vengeance uses its own extension), `.int` localisation text, `.ini`. All share the UPackage header, magic `C1 83 2A 9E`, then version/licensee, name/export/import tables and compact indices. Vengeance is a licensee-modified UE2.5 package version. I do not know of package-level encryption; bulk data may be zlib/LZO compressed.

## Tools
- UE Viewer (umodel) lists Tribes: Vengeance among its supported games (from memory; verify with the current build). It is a standalone exe, usable as an external converter (to PSK/PSA, TGA, OGG), not a Python library.
- Python: no maintained UE2 package library I know of. A header + export-table reader is M; tagged properties and UnrealScript bytecode decoding is L.

## Campaign
The single-player campaign (Daniel Vale storyline) lives in map packages plus `.u` game classes (mission objectives in UnrealScript, text in `.int`). Map names and order are **unverified**; read them from the installed maps folder and the SP game classes after extraction.

## Reuse vs Tribes 2
Little: different engine, art and lore. Only names and design ideas carry over.

## Import plan (effort)
1. S: unzip with inflate64, run `innoextract` into the work folder, delete after use.
2. M: UE2 package reader (header, name/import/export tables).
3. M: campaign: map list, objectives, briefings from `.int` and maps; L if objectives live only in bytecode.
4. L: level geometry (BSP, static mesh actors, terrain) to Godot scenes.
5. M: textures (`.utx`, DXT/P8) and audio (`.uax`), own reader or umodel.
6. L: meshes, skins, animations (`.ukx`, `.usx`) plus weapons/armours/vehicles (stats in `.u` class defaults).
Recommended order: 1, 2, 3 first; models via umodel if licensing allows.

## Legal
Code and format notes only; no game data in the repo; everything is read from the user's own copy.
