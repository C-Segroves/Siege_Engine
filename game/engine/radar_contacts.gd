class_name RadarContacts
extends RefCounted
## Which units a radar (and the command map) shows its viewer (docs/COMMAND_MAP.md section 6): none while the
## viewer's side has no sensor link (SensorLink: a campaign story switched the radar off), else on Tribes maps what
## the team's sensor net detects (TribesBase.is_on_radar), elsewhere every unit; a unit a mission script hid
## (Starsiege setVehicleRadarVisible: apply_hidden) never shows. is_on_scope adds the radar's current range (the
## command map: enemies only while the radar shows them).

const HIDDEN_META := "radar_hidden"
## The range (metres) the viewer's radar covers right now: each radar display records it as it draws
## (apply_range); before any has drawn (headless, no cockpit yet) the HUD radar's.
const RANGE_META := "radar_range_m"
const DEFAULT_RANGE := 1200.0


static func is_shown(viewer: Node, unit: Node) -> bool:
	if viewer == null or unit == null:
		return false
	if not SensorLink.is_up(SensorLink.battle_of(viewer)) or bool(unit.get_meta(HIDDEN_META, false)):
		return false
	return TribesBase.is_on_radar(viewer, unit)


## True while the viewer's radar works at all (radars draw nothing, not even their own scope contents, without it).
static func is_radar_up(viewer: Node) -> bool:
	return viewer != null and SensorLink.is_up(SensorLink.battle_of(viewer))


## Hides (or shows again) one unit from every radar and the command map.
static func apply_hidden(unit: Node, hidden: bool) -> void:
	unit.set_meta(HIDDEN_META, hidden)


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
	var base := TribesBase.of(SensorLink.battle_of(viewer))
	if base and base.sensor_net:
		return true
	var a: Vector3 = (viewer as Node3D).global_position
	var b: Vector3 = (unit as Node3D).global_position
	return Vector2(a.x - b.x, a.z - b.z).length() <= make_range(viewer)
