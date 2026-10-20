class_name CloakRules
extends RefCounted
## Who can see a cloaked unit (docs/formats/cloaking.md). Every sensor of every game asks here, so radar, the
## command map, T-targeting, turrets and bots all hide a cloaked unit the same way:
##   eyes      (bots, a soldier's own sensor)  seen only inside the profile's reveal_range_m (Tribes 2 AI: 8 m);
##   sensors   (turrets, base sensors)         the same, plus a sensor that detects cloaked units (Tribes 2 motion
##             sensors) sees one that moves at least its min_velocity;
##   radar     (Starsiege)                     a sweep finds the unit with the chance the sensor modes give
##             (base + speed + emitting + camo), rolled once per sweep and unit.
## Teammates and allies always see each other (IFF). A unit without a cloak is never hidden.

## Speed classes of the sensor modes (stop / slow / fast), as shares of the unit's top speed (the remake's choice).
const STOP_SHARE := 0.05
const SLOW_SHARE := 0.5
const SWEEP_FALLBACK_S := 2.0
const ROLL_STEPS := 1000


static func cloak_of(unit: Node) -> CloakState:
	return unit.get("cloak") if unit != null else null


## True while `unit` is cloaked in effect.
static func is_cloaked(unit: Node) -> bool:
	var c := cloak_of(unit)
	return c != null and c.is_cloaked()


## True when `unit` wears cloak gear whose field hides it from sensors that do not detect jammed units.
static func is_passive_jammed(unit: Node) -> bool:
	var c := cloak_of(unit)
	return c != null and c.is_passive_jammed()


## True when another unit's sensor jammer field (InfantryPack, jam_radius) covers `unit`.
static func is_in_jam_field(unit: Node3D) -> bool:
	for other in unit.get_tree().get_nodes_in_group("vehicles"):
		if other == unit or not bool(other.get("alive")) or not other.has_meta(InfantryPack.META_JAM_RADIUS):
			continue
		var reach := float(other.get_meta(InfantryPack.META_JAM_RADIUS))
		if (other as Node3D).global_position.distance_to(unit.global_position) <= reach:
			return true
	return false


## Eyes at `distance` metres (a bot, a pilot): a cloaked unit is seen only closer than its reveal range.
static func is_hidden_from_eyes(unit: Node, distance: float) -> bool:
	return is_cloaked(unit) and distance > cloak_of(unit).profile.reveal_range_m


## A sensor described by `sensor` (the Tribes sensor rules: detects_cloaked, min_velocity) at `distance` metres.
## Starsiege-style profiles ask the sensor modes instead (an active sensor, as a turret is).
static func is_hidden_from_sensor(unit: Node, sensor: Dictionary, distance: float) -> bool:
	if not is_hidden_from_eyes(unit, distance):
		return false
	if bool(sensor.get("detects_cloaked", false)) and _make_speed(unit) >= float(sensor.get("min_velocity", 0.0)):
		return false
	var profile := cloak_of(unit).profile
	if profile.has_sensor_modes():
		return not _is_found_by_sweep(profile, unit, null, true)
	return true


## `viewer`'s radar and `unit`: false for a unit without a cloak, an ally or while the viewer sees it up close; else
## the sensor modes' chance (Starsiege) or hidden (a game with no sensor modes). Tribes maps decide in TribesSensorNet.
static func is_hidden_from_radar(viewer: Node, unit: Node) -> bool:
	if not is_cloaked(unit) or viewer == null or TeamRelations.is_allied(int(viewer.get("team")), int(unit.get("team"))):
		return false
	var distance := (viewer as Node3D).global_position.distance_to((unit as Node3D).global_position)
	if not is_hidden_from_eyes(unit, distance):
		return false
	var profile := cloak_of(unit).profile
	if profile.has_sensor_modes():
		return not _is_found_by_sweep(profile, unit, viewer, RadarMode.is_emitting(viewer), CloakProfile.make_sensor_modes(viewer))
	return true


## The chance (0..1) that one sweep of a sensor in mode "a" (active) or "p" (passive) finds `unit`:
## base + camo + the unit's speed class + `activ` when the unit itself emits (datSensor.cs sensorMode). `modes` are the
## looking sensor's own ({} = the profile's standard sensor).
static func make_detect_chance(profile: CloakProfile, unit: Node, sensor_active: bool, modes := {}) -> float:
	var mode: Dictionary = (modes if not modes.is_empty() else profile.sensor_modes).get("a" if sensor_active else "p", {})
	if mode.is_empty():
		return 0.0
	var chance := float(mode.get("base", 0.0)) + float(mode.get("camo", 0.0)) + float(mode.get(_make_speed_class(unit), 0.0))
	if RadarMode.is_emitting(unit):
		chance += float(mode.get("activ", 0.0))
	return clampf(chance, 0.0, 1.0)


static func _is_found_by_sweep(profile: CloakProfile, unit: Node, viewer: Node, sensor_active: bool, modes := {}) -> bool:
	var chance := make_detect_chance(profile, unit, sensor_active, modes)
	if chance <= 0.0:
		return false
	var mode: Dictionary = (modes if not modes.is_empty() else profile.sensor_modes).get("a" if sensor_active else "p", {})
	var sweep := maxf(0.1, float(mode.get("sweep_s", SWEEP_FALLBACK_S)))
	var sweep_no := int(floor(Time.get_ticks_msec() / 1000.0 / sweep))
	return float(_make_roll(viewer, unit, sweep_no)) / ROLL_STEPS < chance


## A stable pseudo-random number 0..ROLL_STEPS-1 per (viewer, unit, sweep): the same answer all through one sweep.
static func _make_roll(viewer: Node, unit: Node, sweep_no: int) -> int:
	var key := "%d|%d|%d" % [viewer.get_instance_id() if viewer != null else 0, unit.get_instance_id(), sweep_no]
	return absi(key.hash()) % ROLL_STEPS


## How fast `unit` moves (m/s): its forward speed or, for a soldier, his ground velocity.
static func _make_speed(unit: Node) -> float:
	var v = unit.get("velocity")
	var ground := Vector2(v.x, v.z).length() if v is Vector3 else 0.0
	return maxf(absf(float(unit.get("speed"))), ground)


static func _make_speed_class(unit: Node) -> String:
	var top := maxf(0.001, float(unit.get("max_speed")))
	var share := _make_speed(unit) / top
	if share < STOP_SHARE:
		return "stop"
	return "slow" if share < SLOW_SHARE else "fast"
