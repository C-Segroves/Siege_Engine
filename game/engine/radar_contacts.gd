class_name RadarContacts
extends RefCounted
## Which units a radar (and the command map) shows its viewer (docs/COMMAND_MAP.md section 6): none while the
## viewer's side has no sensor link (SensorLink: a campaign story switched the radar off), else on Tribes maps what
## the team's sensor net detects (TribesBase.is_on_radar), elsewhere every unit; a unit a mission script hid
## (Starsiege setVehicleRadarVisible: apply_hidden) never shows. is_on_scope adds the radar's current range (the
## command map: enemies only while the radar shows them). A unit in range of a working com tower of the viewer's
## side (SensorTowers) is on the scope at any distance. A cloaked unit shows only where its cloak profile says (CloakRules).

const HIDDEN_META := "radar_hidden"
## The range (metres) the viewer's radar covers right now: each radar display records it as it draws
## (apply_range); before any has drawn (headless, no cockpit yet) the HUD radar's.
const RANGE_META := "radar_range_m"
const DEFAULT_RANGE := 1200.0
## A unit the call-in radar sweep marks carries the time (engine msec) until which every radar of this machine shows it.
const SWEPT_META := "radar_swept_until_msec"


## Every unit a radar may list: the vehicles and soldiers with a node plus the contacts of far bots without one.
static func make_units(tree: SceneTree) -> Array:
	return tree.get_nodes_in_group("vehicles") + tree.get_nodes_in_group(RadarProxy.GROUP)


static func is_shown(viewer: Node, unit: Node) -> bool:
	if viewer == null or unit == null:
		return false
	if not SensorLink.is_up(SensorLink.battle_of(viewer)) or bool(unit.get_meta(HIDDEN_META, false)):
		return false
	if not is_swept(unit) and is_cloak_hidden(viewer, unit):
		return false
	if is_swept(unit) or SensorTowers.is_revealed_by(viewer, unit) or SensorTowers.is_turret(unit) or SensorTowers.is_com_tower(unit):
		return true   # turrets and com towers always show (inside the scope's range); a tower's reach adds units
	if not TribesBase.is_on_radar(viewer, unit):
		return false
	return RadarMode.can_see(viewer, unit, (viewer as Node3D).global_position.distance_to((unit as Node3D).global_position),
		make_range(viewer))


## True when `unit` is cloaked and the viewer's radar cannot find it (CloakRules; a Tribes map's sensor net applies the same
## rules to its own sensors, TribesSensorNet).
static func is_cloak_hidden(viewer: Node, unit: Node) -> bool:
	if not CloakRules.is_cloaked(unit):
		return false
	var base := TribesBase.of(SensorLink.battle_of(viewer))
	return not (base and base.sensor_net) and CloakRules.is_hidden_from_radar(viewer, unit)


## True while the viewer's radar works at all (radars draw nothing, not even their own scope contents, without it).
static func is_radar_up(viewer: Node) -> bool:
	return viewer != null and SensorLink.is_up(SensorLink.battle_of(viewer))


## Hides (or shows again) one unit from every radar and the command map.
static func apply_hidden(unit: Node, hidden: bool) -> void:
	unit.set_meta(HIDDEN_META, hidden)


## The call-in radar sweep marks `unit` for `seconds`: it shows on every radar and the command map, and T can target it,
## whatever the range, the radar mode or the sensor net say.
static func apply_swept(unit: Node, seconds: float) -> void:
	unit.set_meta(SWEPT_META, Time.get_ticks_msec() + int(seconds * 1000.0))


static func is_swept(unit: Node) -> bool:
	return Time.get_ticks_msec() < int(unit.get_meta(SWEPT_META, 0))


## Records the range `viewer`'s radar shows right now (the radar displays, as they draw).
static func apply_range(viewer: Node, metres: float) -> void:
	viewer.set_meta(RANGE_META, metres)


static func make_range(viewer: Node) -> float:
	return float(viewer.get_meta(RANGE_META, DEFAULT_RANGE))


## True when `unit` is on `viewer`'s radar right now: is_shown, and where no sensor net reports contacts (every game
## but Tribes) within the range his radar covers.
static func is_on_scope(viewer: Node, unit: Node) -> bool:
	if not is_shown(viewer, unit):
		return false
	if is_swept(unit) or SensorTowers.is_revealed_by(viewer, unit):
		return true
	var base := TribesBase.of(SensorLink.battle_of(viewer))
	if base and base.sensor_net:
		return true
	var a: Vector3 = (viewer as Node3D).global_position
	var b: Vector3 = (unit as Node3D).global_position
	return Vector2(a.x - b.x, a.z - b.z).length() <= make_range(viewer)
