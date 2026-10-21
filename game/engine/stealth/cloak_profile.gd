class_name CloakProfile
extends RefCounted
## One game's cloak rules, read from its data (gamedata/<pack>/gameplay/cloak.json, written by the exporters;
## docs/formats/cloaking.md). A cloak is the same mechanic in every game that has one (CloakState); the games differ
## only in these numbers:
##   Tribes 2   the cloaking pack: energy per second while on, a wait after a shot or a hit, the close range at
##              which the AI still sees the wearer, jammed sensors while worn (the motion sensor still sees him).
##   Starsiege  the Chameleon / Cuttlefish components: the sensors' `camo` modifiers decide how likely a sensor
##              sweep is to find the unit, health thresholds make it glitch and fail.
## Ids are "<pack>:<name>" (tribes2:cloaking_pack, starsiege:830).

const FILE := "gameplay/cloak.json"
## Seconds the cloak takes to fade in and out: about one second in Tribes 2's ShapeBase cloak (engine code, not data).
const DEFAULT_FADE_IN_S := 1.0
const DEFAULT_FADE_OUT_S := 1.0

static var NONE := CloakProfile.new()
static var _by_id := {}
static var _sensors := {}   # "<pack>:<sensor id>" -> {"a": {...}, "p": {...}, "name"}
static var _loaded := false

var id := ""
var display_name := ""
## Energy spent per second while the cloak is on, and the energy below which it will not start.
var energy_per_s := 0.0
var min_energy := 0.0
## After a break the cloak comes back on its own after this many seconds (0 = it stays off until switched on again);
## a shot breaks it only while the energy is above recloak_min_energy.
var recloak_delay_s := 0.0
var recloak_min_energy := 0.0
var breaks_on_fire := false
var breaks_on_damage := false
## A hit has to deal more than this (engine damage points) to break it.
var damage_break_min := 0.0
## Closer than this (metres) a cloaked unit is seen by eyes and by every sensor.
var reveal_range_m := 0.0
## Wearing the gear (cloak on or off) hides the wearer from sensors that do not detect jammed units.
var jams_sensors_when_worn := false
## A sensor jammer's field around the unit stops the cloak (CloakingPackImage::onActivate / onForceUncloak: "Jamming
## field prevents cloaking").
var blocked_by_jam_field := false
## Seconds of the timed cloaks the game's scripts apply: after a respawn and on a new vehicle (0 = none).
var respawn_cloak_s := 0.0
var vehicle_pad_cloak_s := 0.0
## Starsiege: the standard sensor's modes {"a": {base, camo, stop, slow, fast, activ, sweep_s ...}, "p": {...}}.
var sensor_modes := {}
## Starsiege: health fractions below which the cloak glitches / fails, and the glitch rate.
var glitch_health := 0.0
var glitch_coef := 0.0
var fail_health := 0.0
var ai_uses := false
var ai_order := ""
var sound_loop := ""
var sound_toggle := ""
## The cloak bitmap of the pack ("fx/textures/cloaktexture.png": Tribes 2's special/cloakTexture), "" = the shader's own pattern.
var texture := ""
var fade_in_s := DEFAULT_FADE_IN_S
var fade_out_s := DEFAULT_FADE_OUT_S


static func make_from(d: Dictionary) -> CloakProfile:
	var p := CloakProfile.new()
	p.id = str(d.get("id", ""))
	p.display_name = str(d.get("name", ""))
	p.energy_per_s = float(d.get("energy_per_s", 0.0))
	p.min_energy = float(d.get("min_energy", 0.0))
	p.recloak_delay_s = float(d.get("recloak_delay_s", 0.0))
	p.recloak_min_energy = float(d.get("recloak_min_energy", 0.0))
	var breaks: Array = d.get("breaks_on", [])
	p.breaks_on_fire = breaks.has("fire")
	p.breaks_on_damage = breaks.has("damage")
	p.damage_break_min = float(d.get("damage_break_min", 0.0))
	p.reveal_range_m = float(d.get("reveal_range_m", 0.0))
	p.jams_sensors_when_worn = bool(d.get("jams_sensors_when_worn", false))
	p.blocked_by_jam_field = bool(d.get("blocked_by_jam_field", false))
	p.respawn_cloak_s = float(d.get("respawn_cloak_s", 0.0))
	p.vehicle_pad_cloak_s = float(d.get("vehicle_pad_cloak_s", 0.0))
	p.sensor_modes = d.get("sensor_modes", {})
	p.glitch_health = float(d.get("glitch_health", 0.0))
	p.glitch_coef = float(d.get("glitch_coef", 0.0))
	p.fail_health = float(d.get("fail_health", 0.0))
	p.ai_uses = bool(d.get("ai_uses", false))
	p.ai_order = str(d.get("ai_order", ""))
	p.sound_loop = str(d.get("sound_loop", ""))
	p.sound_toggle = str(d.get("sound_toggle", ""))
	p.texture = str(d.get("texture", ""))
	p.fade_in_s = float(d.get("fade_in_s", DEFAULT_FADE_IN_S))
	p.fade_out_s = float(d.get("fade_out_s", DEFAULT_FADE_OUT_S))
	return p


## The profile `id`, or NONE (is_real false) when no installed pack has it.
static func of(profile_id: String) -> CloakProfile:
	_ensure_loaded()
	return _by_id.get(profile_id, NONE)


## The cloak component `component_id` of Starsiege-style numbered equipment of `pack_name`, or NONE.
static func of_component(pack_name: String, component_id: int) -> CloakProfile:
	return of("%s:%d" % [pack_name, component_id])


## The id of the script-driven cloak (respawn, station, vehicle pad) of the game `unit` plays in: "<pack>:timed_cloak".
static func make_timed_id(unit: Node) -> String:
	var def = unit.get("def")
	return "%s:timed_cloak" % str(def.get("pack", "")) if def is Dictionary else ""


## The cloak among the equipment a unit of `pack_name` carries (component ids, 0 = empty slot), or NONE.
static func of_mountables(pack_name: String, component_ids: Array) -> CloakProfile:
	for component_id in component_ids:
		var p := of_component(pack_name, int(component_id))
		if p.is_real():
			return p
	return NONE


## The cloak a catalog vehicle `def` (id `vehicle_id`) carries by default (Starsiege default_mountables), or NONE.
static func of_vehicle(vehicle_id: String, def: Dictionary) -> CloakProfile:
	var ids := []
	for m in def.get("default_mountables", []):
		ids.append(int(m.get("id", 0)))
	return of_mountables(str(Assets.split_id(vehicle_id)[0]), ids) if not ids.is_empty() else NONE


## The sensor modes of the sensor component `unit` (a Herc) carries by default ({} when it has none).
static func make_sensor_modes(unit: Node) -> Dictionary:
	_ensure_loaded()
	var def = unit.get("def")
	if not (def is Dictionary):
		return {}
	for m in def.get("default_mountables", []):
		if str(m.get("kind", "")) == "sensor":
			return _sensors.get("%s:%d" % [str(def.get("pack", "")), int(m.get("id", 0))], {})
	return {}


## The modes of sensor component `sensor_id` of `pack_name` ({} when unknown).
static func make_sensor_modes_by_id(pack_name: String, sensor_id: int) -> Dictionary:
	_ensure_loaded()
	return _sensors.get("%s:%d" % [pack_name, sensor_id], {})


static func reload() -> void:
	_sensors.clear()
	_by_id.clear()
	_loaded = false


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	for pack_name in Assets.installed_packs():
		var data = Assets.load_json(FILE, pack_name)
		if not (data is Dictionary):
			continue
		for d in (data.get("profiles", {}) as Dictionary).values():
			var p := make_from(d)
			_by_id[p.id] = p
		_sensors.merge(data.get("sensors", {}), true)


func is_real() -> bool:
	return id != ""


## True when the profile has the Starsiege-style sensor modes (detection by chance per sweep).
func has_sensor_modes() -> bool:
	return not sensor_modes.is_empty()
