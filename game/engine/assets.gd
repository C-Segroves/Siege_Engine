extends Node
## Loads converted game data (palettes, indexed textures, shapes) from the gamedata folder.
##
## Game data is produced from the user's original discs by tools/import_*.py and lives
## outside res:// so that no copyrighted content ships with the engine.
##
## Content comes in packs, one per original game ("es1" Earthsiege, "bd" Battledrome, ...).
## Asset ids may be qualified as "pack:NAME"; unqualified names use `default_pack`.

## Original world units -> metres. A Herc is ~2500 units tall.
const UNIT := 1.0 / 256.0

var data_root := ""
var default_pack := "es1"

var _palettes := {}
var _palette_textures := {}
var _texsets := {}
var _shapes := {}


## The settings file of the current store (UserStore; a test store keeps tests off the player's file).
var SETTINGS_FILE: String:
	get: return UserStore.path("settings.json")

## Where imported packs live. Default: the per-user app data folder (user://packs), so the app
## itself never contains game content. A developer checkout's ../gamedata is used if present
## and no user packs exist. Can be overridden in settings ("data_dir").
var settings := {}


func _ready() -> void:
	settings = _load_settings()
	if WebPlatform.is_active():
		WebPlatform.mount_packs()
	data_root = _find_data_root()


## A test store made for this process alone (UserStore, command line / environment) goes with it.
func _exit_tree() -> void:
	if UserStore.root() == UserStore.make_process_dir():
		UserStore.clear_test_store()


## Reads the settings file of the current store again (UserStore switched: a test store or back).
func reload_settings() -> void:
	settings = _load_settings()


func _load_settings() -> Dictionary:
	var f := FileAccess.open(SETTINGS_FILE, FileAccess.READ)
	if f:
		var j = JSON.parse_string(f.get_as_text())
		if j is Dictionary:
			return j
	return {}


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(settings, "  "))


## Folder the importer writes packs into.
func user_packs_dir() -> String:
	var d: String = settings.get("data_dir", "")
	if d == "":
		d = ProjectSettings.globalize_path("user://packs")
	DirAccess.make_dir_recursive_absolute(d)
	return d


func _find_data_root() -> String:
	if WebPlatform.is_active():
		return WebPlatform.DATA_ROOT
	var user := user_packs_dir()
	if not DirAccess.get_directories_at(user).is_empty() or settings.has("data_dir"):
		return user
	for c in [OS.get_executable_path().get_base_dir().path_join("gamedata"),
			ProjectSettings.globalize_path("res://").path_join("../gamedata")]:
		if DirAccess.dir_exists_absolute(c) and not DirAccess.get_directories_at(c).is_empty():
			return c.simplify_path()
	return user


## Re-scan after an import (new packs appear without restarting).
func refresh() -> void:
	data_root = _find_data_root()
	_palettes.clear()
	_palette_textures.clear()
	_texsets.clear()
	_shapes.clear()


## Packs whose data has been imported.
func installed_packs() -> PackedStringArray:
	var out := PackedStringArray()
	if data_root != "":
		for d in DirAccess.get_directories_at(data_root):
			if not d.begins_with("_"):   # "_soundtracks" etc. are stores, not game packs
				out.append(d)
	return out


func has_pack(pack: String) -> bool:
	return data_root != "" and DirAccess.dir_exists_absolute(data_root.path_join(pack))


## Splits "pack:NAME" -> [pack, NAME].
func split_id(id: String) -> Array:
	var i := id.find(":")
	if i < 0:
		return [default_pack, id]
	return [id.substr(0, i), id.substr(i + 1)]


func qualify(id: String, pack := "") -> String:
	if id.find(":") >= 0:
		return id
	return "%s:%s" % [pack if pack != "" else default_pack, id]


func path(rel: String, pack := "") -> String:
	return data_root.path_join(pack if pack != "" else default_pack).path_join(rel)


func load_json(rel: String, pack := "") -> Variant:
	var f := FileAccess.open(path(rel, pack), FileAccess.READ)
	if f == null:
		return null
	return JSON.parse_string(f.get_as_text())


# ------------------------------------------------------------------ palettes

func palette(id: String) -> Array:
	id = qualify(id)
	if not _palettes.has(id):
		var p := split_id(id)
		var j = load_json("palettes/%s.json" % p[1], p[0])
		if j == null:
			# truecolour packs (Tribes 2) have no palettes; only complain for palette-based packs
			if DirAccess.dir_exists_absolute(path("palettes", p[0])):
				push_error("missing palette " + id)
			j = []
			for i in 256:
				j.append([i, i, i])
		_palettes[id] = j
	return _palettes[id]


func palette_color(id: String, index: int) -> Color:
	var c: Array = palette(id)[index]
	return Color8(int(c[0]), int(c[1]), int(c[2]))


## 256x1 RGBA texture used by the indexed-colour shader.
func palette_texture(id: String) -> ImageTexture:
	id = qualify(id)
	if not _palette_textures.has(id):
		var img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
		var p: Array = palette(id)
		for i in 256:
			var c: Array = p[i]
			img.set_pixel(i, 0, Color8(int(c[0]), int(c[1]), int(c[2])))
		_palette_textures[id] = ImageTexture.create_from_image(img)
	return _palette_textures[id]


# ------------------------------------------------------------------ indexed textures

## Returns an array of ImageTexture (single channel, value = palette index).
func texture_set(id: String) -> Array:
	id = qualify(id)
	if not _texsets.has(id):
		var p := split_id(id)
		var meta = load_json("textures/%s.json" % p[1], p[0])
		var arr := []
		if meta != null:
			for i in meta.size():
				var tp := path("textures/%s/%d.png" % [p[1], i], p[0])
				var img: Image = Image.load_from_file(tp) if FileAccess.file_exists(tp) else null
				if img == null:
					img = Image.create(1, 1, false, Image.FORMAT_L8)
				if img.get_format() != Image.FORMAT_L8:
					img.convert(Image.FORMAT_L8)
				arr.append(ImageTexture.create_from_image(img))
		_texsets[id] = arr
	return _texsets[id]


func load_image(rel: String, pack := "") -> Image:
	var p := path(rel, pack)
	if not FileAccess.file_exists(p):
		return null
	return Image.load_from_file(p)


# ------------------------------------------------------------------ shapes

## Shape dictionary; `pack` and `id` keys are added so dependent assets resolve in the right pack.
func shape(id: String) -> Dictionary:
	id = qualify(id)
	if not _shapes.has(id):
		var p := split_id(id)
		var j = load_json("shapes/%s.json" % p[1], p[0])
		if j == null:
			push_error("missing shape " + id)
			j = {"lods": [{"pieces": [], "cells": [], "radius": 1, "center": [0, 0, 0]}], "nodes": []}
		j["pack"] = p[0]
		j["id"] = id
		_shapes[id] = j
	return _shapes[id]


func shape_index(pack := "") -> Array:
	var j = load_json("shapes/_index.json", pack)
	return j if j != null else []
