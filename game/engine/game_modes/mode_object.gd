class_name ModeObject
extends RefCounted
## One object a game mode plays with (map.json "mode_objects", docs/formats/game_modes.md): a flag, flag stand,
## switch, Nexus, objective, goal, ball or a dropped Hunters flag. Pure state, the same on every peer (the host's
## copy is sent with GameModeRules.make_state).

const KIND_FLAG := "flag"
const KIND_STAND := "flag_stand"
const KIND_SWITCH := "switch"
const KIND_NEXUS := "nexus"
const KIND_OBJECTIVE := "objective"
const KIND_GOAL := "goal"
const KIND_BALL := "ball"
const KIND_HUNTER_FLAG := "hunter_flag"
const KIND_OUT_OF_BOUNDS := "out_of_bounds"
const KIND_GENERATOR := "generator"
const KIND_STRUCTURE := "structure"
## Hunters: the trigger box round the Nexus (camping).
const KIND_NEXUS_ZONE := "nexus_zone"
## WAR: an AI Herc defending its base (GameModeDefenders).
const KIND_DEFENDER := "defender"
## state: at its home place / carried by `carrier` / lying where it was dropped / placed on a stand (Find and
## Retrieve) / destroyed (objectives) / gone (picked-up Hunters flags).
const HOME := "home"
const CARRIED := "carried"
const DROPPED := "dropped"
const PLACED := "placed"
const DESTROYED := "destroyed"
const GONE := "gone"
const NO_CARRIER := 0
const NEUTRAL := -1

var id := 0
var kind := ""
var team := NEUTRAL
var home := Vector3.ZERO
var pos := Vector3.ZERO
var yaw := 0.0
var state := HOME
## net id of the combatant carrying it (NO_CARRIER: nobody).
var carrier := NO_CARRIER
## Seconds left before a dropped object returns home / a Hunters flag fades; capture countdown of a switch.
var timer := 0.0
## Score value (Tribes scoreValue, Hunters flag denomination).
var value := 1.0
## Switch / stand: the team that holds it; the flag a stand holds (Find and Retrieve).
var owner_team := NEUTRAL
var held_object := 0
## Goal and trigger boxes (metres, engine axes); zero = touched by distance.
var half_extents := Vector3.ZERO
var shape := ""
var name := ""
var datablock := ""
## Switch: seconds it has been held by owner_team since the capture counted (scoring ticks).
var hold_time := 0.0
var points_per_minute := 0.0
## Switch: positions of the turrets and stations of its group (they change team with it); times it changed hands.
var group: Array = []
var claims := 0


static func from_map(d: Dictionary) -> ModeObject:
	var o := ModeObject.new()
	o.id = int(d.get("id", 0))
	o.kind = str(d.get("kind", ""))
	o.team = int(d.get("team", NEUTRAL))
	o.home = _vec(d.get("pos", [0, 0, 0]))
	o.pos = o.home
	o.yaw = float(d.get("yaw", 0.0))
	o.value = float(d.get("value", 1.0))
	o.half_extents = _vec(d.get("half_extents", [0, 0, 0]))
	o.shape = str(d.get("shape", ""))
	o.name = str(d.get("name", ""))
	o.datablock = str(d.get("datablock", ""))
	o.points_per_minute = float(d.get("points_per_minute", 0.0))
	o.group = d.get("group", []).duplicate()
	o.owner_team = o.team if o.kind != KIND_SWITCH else NEUTRAL
	if o.kind == KIND_SWITCH and o.team >= 0:
		o.owner_team = o.team
	return o


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if a.size() >= 3 else Vector3.ZERO


## True when something at `p` within `radius` touches this object (its box, or its position).
func is_touched_at(p: Vector3, radius: float) -> bool:
	if half_extents != Vector3.ZERO:
		var d := (p - pos).abs()
		return d.x <= half_extents.x + radius and d.y <= half_extents.y + radius and d.z <= half_extents.z + radius
	return p.distance_to(pos) <= radius


## True when `p` stands inside the box's ground footprint (goal and field boxes: any height).
func is_over_footprint(p: Vector3) -> bool:
	var d := (p - pos).abs()
	return half_extents != Vector3.ZERO and d.x <= half_extents.x and d.z <= half_extents.z


func is_takeable() -> bool:
	return state in [HOME, DROPPED, PLACED]


func make_dict() -> Dictionary:
	return {"id": id, "kind": kind, "team": team, "home": [home.x, home.y, home.z], "pos": [pos.x, pos.y, pos.z],
		"yaw": yaw, "state": state, "carrier": carrier, "timer": timer, "value": value, "owner_team": owner_team,
		"held_object": held_object, "half_extents": [half_extents.x, half_extents.y, half_extents.z],
		"shape": shape, "name": name, "datablock": datablock, "hold_time": hold_time,
		"points_per_minute": points_per_minute, "group": group, "claims": claims}


static func from_dict(d: Dictionary) -> ModeObject:
	var o := ModeObject.new()
	o.apply_dict(d)
	return o


func apply_dict(d: Dictionary) -> void:
	id = int(d.id)
	kind = str(d.kind)
	team = int(d.team)
	home = _vec(d.home)
	pos = _vec(d.pos)
	yaw = float(d.yaw)
	state = str(d.state)
	carrier = int(d.carrier)
	timer = float(d.timer)
	value = float(d.value)
	owner_team = int(d.owner_team)
	held_object = int(d.held_object)
	half_extents = _vec(d.half_extents)
	shape = str(d.shape)
	name = str(d.name)
	datablock = str(d.datablock)
	hold_time = float(d.hold_time)
	points_per_minute = float(d.points_per_minute)
	group = d.get("group", [])
	claims = int(d.get("claims", 0))
