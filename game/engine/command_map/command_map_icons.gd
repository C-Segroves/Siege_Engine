class_name CommandMapIcons
extends RefCounted
## The game's own command-map icons (docs/COMMAND_MAP.md section 4; tools/export_map_icons.py: Tribes 1 M_*.bmp,
## Tribes 2 com_icon_*.png, Starsiege mapIcon*.pba) by the remake's kinds (self, soldier, herc, flyer, turret,
## generator, sensor, station, vehicle_station, nav, ...). Each kind has a friend and an enemy picture, drawn as
## the game drew it or (tint) white-on-grey art tinted by side. A game or kind without icons draws the map's
## neutral shapes (has returns false).

const ICONS_FILE := "command_map/icons.json"
const ICONS_DIR := "command_map/icons/"
## Drawn size range (pixels, longest side): small originals keep their size, big ones (Tribes 2: 64 px) shrink.
const MIN_SIDE := 10.0
const MAX_SIDE := 20.0
const STATION_KINDS := ["inventory", "ammo", "command"]
const VEHICLE_STATION_KINDS := ["vehicle", "vehicle_pad"]

var _icons := {}       # kind -> {friend: Texture2D, enemy: Texture2D, tint: bool}


static func load_for(pack: String) -> CommandMapIcons:
	var out := CommandMapIcons.new()
	var j = Assets.load_json(ICONS_FILE, pack) if pack != "" else null
	if not (j is Dictionary):
		return out
	for kind in (j as Dictionary).get("icons", {}):
		var e: Dictionary = j.icons[kind]
		var friend := _load(pack, str(e.get("friend", "")))
		var enemy := _load(pack, str(e.get("enemy", "")))
		if friend and enemy:
			out._icons[kind] = {"friend": friend, "enemy": enemy, "tint": bool(e.get("tint", false))}
	return out


static func _load(pack: String, file: String) -> Texture2D:
	var img := Assets.load_image(ICONS_DIR + file, pack) if file != "" else null
	return ImageTexture.create_from_image(img) if img else null


func has(kind: String) -> bool:
	return _icons.has(kind)


func is_empty() -> bool:
	return _icons.is_empty()


## The icon kind of a combatant (the viewer himself: "self" when the game has its own marker).
func make_unit_kind(unit: Node, is_viewer: bool) -> String:
	if is_viewer and has("self"):
		return "self"
	if unit is Infantry:
		return "soldier"
	if unit is Flyer:
		return "flyer"
	return "herc"


## The icon kind of a structure ("" for buildings no game marks with an icon).
static func make_structure_kind(s: Node) -> String:
	var kind := str(s.get("kind")) if s.get("kind") != null else ""
	if kind in STATION_KINDS:
		return "station"
	if kind in VEHICLE_STATION_KINDS:
		return "vehicle_station"
	return kind


## Draws icon `kind` centred at `at` on `canvas`, for a friend or an enemy in `color` (tinted art) - false when the
## game has no such icon.
func draw(canvas: CanvasItem, kind: String, at: Vector2, friend: bool, color: Color) -> bool:
	if not _icons.has(kind):
		return false
	var e: Dictionary = _icons[kind]
	var tex: Texture2D = e.friend if friend else e.enemy
	var size := make_draw_size(tex.get_size())
	canvas.draw_texture_rect(tex, Rect2(at - size * 0.5, size), false, color if bool(e.tint) else Color.WHITE)
	return true


static func make_draw_size(native: Vector2) -> Vector2:
	var side := maxf(native.x, native.y)
	return native * (clampf(side, MIN_SIDE, MAX_SIDE) / maxf(side, 1.0))
