class_name CallinBomberPilot
extends FlyerAI
## The autopilot of a bombing run's aircraft (host): it flies the straight line of the run at a steady height, entering
## and leaving the map, and lets the planned stick of bombs go as it passes. A bomb is a catalog bomb projectile (the shared
## weapon/projectile system, the aircraft its shooter): it keeps the plane's speed when it is released and falls, so each
## one is released a lead ahead of its impact point, the lead being the distance the bomb still flies while it falls from
## the height the plane has over that point. It flies a line goal through the shared FlightPilot (engine/flight) and never fires its guns.

## The pilot aims at the point of the line this far ahead of it (m): it flies back onto the line from any offset.
const LOOK_AHEAD_M := 150.0
## The run is over this close to its end (m).
const END_REACH_M := 60.0
## A bomb leaves the hull this far below it (m).
const BOMB_DROP_M := 3.0
const GRAVITY := 9.81
const MIN_FALL_HEIGHT_M := 1.0

## The flat start of the line, its flat unit direction and its length to the exit point.
var origin := Vector3.ZERO
var direction := Vector3.FORWARD
var length := 0.0
## The height (world y) the plane holds, its speed (m/s).
var cruise_y := 0.0
var speed := 60.0
## The bomb weapon definition and the planned impact points (ground height in y), first to last along the line.
var bomb_def := {}
var plan := PackedVector3Array()
## Bombs released so far, and where they came down (the host's record).
var released := 0
var impacts: Array[Vector3] = []
## Called as on_impact(at) for each bomb that landed.
var on_impact := Callable()


static func make(p_flyer: Flyer, p_origin: Vector3, p_direction: Vector3, p_length: float) -> CallinBomberPilot:
	var pilot := CallinBomberPilot.new(p_flyer)
	pilot.origin = p_origin
	pilot.direction = p_direction
	pilot.length = p_length
	return pilot


func is_done() -> bool:
	return make_along() >= length - END_REACH_M


func has_dropped_all() -> bool:
	return released >= plan.size()


## Metres the plane has flown along the line.
func make_along() -> float:
	return CallinAirLine.make_along(origin, direction, flyer.global_position)


## Seconds until the first release at the plane's present speed (0 once it has been made).
func make_seconds_to_release() -> float:
	if released > 0 or plan.is_empty():
		return 0.0
	var gap := CallinAirLine.make_along(origin, direction, plan[0]) - _make_lead(plan[0]) - make_along()
	return maxf(gap, 0.0) / maxf(_make_flat_speed(), 1.0)


func update(delta: float) -> void:
	flyer.target = null
	for w in flyer.weapons:
		w.trigger = false
	var goal := FlightGoal.make_line(origin, direction, LOOK_AHEAD_M, 0.0)
	goal.height_y = cruise_y
	goal.crosses_edge = true
	flyer.apply_flight(goal, speed, delta)
	_apply_releases(make_along())


func _apply_releases(along: float) -> void:
	while released < plan.size() and along >= CallinAirLine.make_along(origin, direction, plan[released]) - _make_lead(plan[released]):
		_release(plan[released])
		released += 1


## The distance (m) a bomb let go now flies on before it lands at `impact`.
func _make_lead(impact: Vector3) -> float:
	var height := maxf(flyer.global_position.y - BOMB_DROP_M - impact.y, MIN_FALL_HEIGHT_M)
	return _make_flat_speed() * sqrt(2.0 * height / GRAVITY)


func _make_flat_speed() -> float:
	var along_v := Vector3(flyer.velocity.x, 0.0, flyer.velocity.z).dot(direction)
	return along_v if along_v > 1.0 else speed


func _release(impact: Vector3) -> void:
	var from := flyer.global_position + Vector3.DOWN * BOMB_DROP_M
	var bomb := WeaponShot.launch_projectile({"shooter": flyer, "def": bomb_def, "from": from, "dir": Vector3.DOWN, "target": null})
	bomb.impacted.connect(_on_bomb_impacted)
	var sound := str(bomb_def.get("sounds", {}).get("fire", ""))
	if sound != "":
		Sfx.play_at(sound, from)


func _on_bomb_impacted(at: Vector3) -> void:
	impacts.append(at)
	if on_impact.is_valid():
		on_impact.call(at)
