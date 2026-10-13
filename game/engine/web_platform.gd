class_name WebPlatform
extends RefCounted
## The browser build (Godot's "web" feature) and what it cannot do.
##
## Game data reaches the browser as one .pck file per content pack. The page shell
## (game/web/siege_shell.html) downloads the packs the player picks into PACK_DIR of the page's
## in-memory file system before the engine starts; mount_packs() mounts them so every pack appears
## under DATA_ROOT, and Assets reads them there with the same FileAccess / DirAccess calls as on
## desktop. Discs cannot be imported, folders cannot be browsed and LAN play (ENet, UDP discovery)
## does not exist in a browser. Setup: docs/WEB_DEPLOY.md.

## Where the page shell writes the downloaded pack files (PACK_DIR in game/web/siege_shell.html).
const PACK_DIR := "/siege_packs"
## Where the mounted packs appear (the paths game/tools/web/pack_gamedata.gd writes into each .pck).
const DATA_ROOT := "res://gamedata"

const NO_IMPORT_TEXT := "Browser version: discs are imported on the server that hosts this page."
const NO_LAN_TEXT := "LAN multiplayer needs the desktop app; the browser version plays solo."
const NO_DATA_FOLDER_TEXT := "Browser version: game data is downloaded from the server."
const NO_REMOVE_TEXT := "Browser version: packs are managed on the server."

static var _mounted := false


static func is_active() -> bool:
	return OS.has_feature("web")


## Mounts every pack file the page shell downloaded (once per session).
static func mount_packs() -> void:
	if _mounted:
		return
	_mounted = true
	for file in DirAccess.get_files_at(PACK_DIR):
		if file.get_extension() != "pck":
			continue
		if not ProjectSettings.load_resource_pack(PACK_DIR.path_join(file), false):
			push_error("could not mount game data " + file)
