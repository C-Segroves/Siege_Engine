class_name OnlineSettings
extends RefCounted
## The player's online choices, kept in user://settings.json (Assets.settings, key "online"): the master server address
## ("" = none: LAN play needs no master), the addresses joined lately, and the last "Run dedicated server" sheet values
## (never the password).

const SETTINGS_KEY := "online"
const MAX_RECENT := 8
const SERVER_KEY := "server"


static func master() -> String:
	return str(_data().get("master", ""))


static func apply_master(text: String) -> void:
	_store("master", text.strip_edges())


static func has_master() -> bool:
	return master() != ""


static func recent() -> Array:
	var r: Variant = _data().get("recent", [])
	return (r as Array).duplicate() if r is Array else []


## Puts `address` first in the recent list (no duplicates, at most MAX_RECENT).
static func remember(address: String) -> void:
	var list := recent()
	list.erase(address)
	list.push_front(address)
	_store("recent", list.slice(0, MAX_RECENT))


static func forget_all() -> void:
	_store("recent", [])


static func server_sheet() -> Dictionary:
	var v: Variant = _data().get(SERVER_KEY, {})
	return (v as Dictionary).duplicate() if v is Dictionary else {}


static func apply_server_sheet(values: Dictionary) -> void:
	_store(SERVER_KEY, values)


static func _data() -> Dictionary:
	var d: Variant = Assets.settings.get(SETTINGS_KEY, {})
	return d if d is Dictionary else {}


static func _store(key: String, value: Variant) -> void:
	var d := _data().duplicate()
	d[key] = value
	Assets.settings[SETTINGS_KEY] = d
	Assets.save_settings()
