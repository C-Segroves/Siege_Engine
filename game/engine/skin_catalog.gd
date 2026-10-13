class_name SkinCatalog
## The alternate skins of the player models (gamedata/<pack>/skins/skins.json, written by tools/export_skins.py from
## the original discs): Tribes / Tribes 2 armour skins and Starsiege Herc skins (the vehicle lab's SKIN choice).
## File: {"pack", "source", "skins": {shape id: [{id, name, textures: {base texture file (lower case): png path}}]}}.
## A skin replaces the shape's textures named in "textures" (ShapeInstance.texture_overrides); "" is the default.

const SKINS_FILE := "skins/skins.json"
const DEFAULT_CHOICE := {"id": "", "label": "Default"}

static var _by_pack := {}


## The skins of shape `shape_id` as choices: [{id, label}], the default first.
static func make_skin_choices(shape_id: String) -> Array:
	var out := [DEFAULT_CHOICE.duplicate()]
	for s in _skins_of(shape_id):
		out.append({"id": str(s.id), "label": str(s.get("name", s.id))})
	return out


## True when shape `shape_id` has a skin besides its default.
static func has_skins(shape_id: String) -> bool:
	return not _skins_of(shape_id).is_empty()


## {base texture file (lower case): png path in the shape's pack} of skin `skin_id` ({} for the default / unknown).
static func make_texture_overrides(shape_id: String, skin_id: String) -> Dictionary:
	if skin_id == "":
		return {}
	for s in _skins_of(shape_id):
		if str(s.id) == skin_id:
			return (s.get("textures", {}) as Dictionary).duplicate()
	return {}


## The skin choices of vehicle `vehicle_id` (its shape's).
static func make_vehicle_skin_choices(vehicle_id: String) -> Array:
	return make_skin_choices(make_vehicle_shape(vehicle_id))


static func make_vehicle_shape(vehicle_id: String) -> String:
	return Assets.qualify(str(Packs.vehicle(vehicle_id).get("shape", vehicle_id)), vehicle_id.get_slice(":", 0))


## Drops the cache (tests, a new import).
static func reload() -> void:
	_by_pack.clear()


static func _skins_of(shape_id: String) -> Array:
	var pack := shape_id.get_slice(":", 0) if shape_id.contains(":") else Assets.default_pack
	if not _by_pack.has(pack):
		var data = Assets.load_json(SKINS_FILE, pack) if Assets.has_pack(pack) else null
		_by_pack[pack] = (data.get("skins", {}) as Dictionary) if data is Dictionary else {}
	return (_by_pack[pack] as Dictionary).get(shape_id, [])
