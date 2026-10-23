class_name TVVehicleFleet
extends RefCounted
## The drivable vehicles a Tribes: Vengeance map places (map.json "vehicles": the Vehicle* actors, tools/tv_vehicles.py).
##
## Each one is a catalog vehicle of the pack (Pod, Tank, AssaultShip, Buggy: gameplay/hercs.json, docs/formats/tribes_vengeance.md) that
## appears when the player comes within SPAWN_RADIUS, parked and empty where the actor stands (the Tribes 2 vehicle pad rule: a soldier
## boards by touching it, BoardingRules). An actor of the enemy team that has AI goals in the map is crewed by the vehicle's own AI pilot
## instead (the shared Flyer / AIPilot brains the other games use); its goal objects (VehicleGuard, VehiclePatrol, VehicleAttack ...) are
## not decoded, so it flies a patrol loop around its start, or drives to and fro, and attacks what it meets.
## The script's label names the vehicle: ActionEnable / ActionDestroy and MessageDeath address it as they address a soldier.

const SPAWN_RADIUS := 450.0
const PER_TICK := 2
const AI_SKILL := 0.5
const PATROL_RADIUS := 150.0
const PATROL_POINTS := 4
const FLOOR_PROBE_UP := 3.0
const FLOOR_PROBE_DOWN := 60.0
const SETTLE_LIFT := 0.1
const FLOOR_TOLERANCE := 0.5                # a floor higher than the actor's centre by more is a roof

var _runtime: Node                         # the TVMissionRuntime: battle, ally rule
var entries: Array = []                    # [{rec, enabled, spawned, dead, vehicle (Herc)}]


func _init(runtime: Node) -> void:
	_runtime = runtime


func build(records: Array) -> void:
	for rec in records:
		if Packs.vehicle(str(rec.get("vehicle", ""))).is_empty():
			continue
		entries.append({"rec": rec, "enabled": true, "spawned": false, "dead": false, "vehicle": null})


## Spawns the vehicles near `at` (PER_TICK per call).
func sync(at: Vector3) -> void:
	var spawned := 0
	for e in entries:
		if not bool(e.enabled) or bool(e.spawned) or bool(e.dead):
			continue
		if at.distance_to(_position_of(e.rec)) > SPAWN_RADIUS:
			continue
		apply_spawn(e)
		spawned += 1
		if spawned >= PER_TICK:
			return


## Host: the vehicle of entry `e` appears on every peer.
func apply_spawn(e: Dictionary) -> Herc:
	e.spawned = true
	var h := make_spawned(_runtime.battle, make_spec(e.rec, _runtime.battle, _is_ally(str(e.rec.get("team_name", "")))))
	e.vehicle = h
	return h


## Host: sends `spec` (make_spec) to every peer and returns the vehicle. A parked aircraft is set down at the spec's height: its own landing
## finds the terrain's height field, which has no floor where the actor stands on a base's floor (or in a hole of the terrain).
static func make_spawned(battle: Battle, spec: Dictionary) -> Herc:
	battle.send_spawn(spec)
	var h := battle.vehicles.get(int(spec.net_id)) as Herc
	if h is Flyer and not (spec.ai as Dictionary).has("skill"):
		(h as Flyer).global_position.y = float((spec.xf as Transform3D).origin.y)
	return h


## The spawn spec of a placed vehicle: parked and empty, or with an AI pilot when `ally` is false and the actor has goals.
static func make_spec(rec: Dictionary, battle: Battle, ally: bool) -> Dictionary:
	var vid := str(rec.vehicle)
	var vdef := Packs.vehicle(vid)
	var crewed := not ally and bool(rec.get("ai_goals", false))
	var xf := Transform3D(Basis(Vector3.UP, make_yaw(rec)), make_start_point(rec, battle, vdef))
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": vid,
		"team": TVMissionRuntime.ENEMY_TEAM if not ally else TVMissionRuntime.PLAYER_TEAM,
		"owner": VehicleOccupancy.EMPTY if not crewed else 1, "xf": xf, "loadout": vdef.get("loadout", []),
		"name": str(vdef.get("name", vid)), "ai": {}, "parked": not crewed, "protection": 0.0}
	if crewed:
		spec.ai = {"skill": AI_SKILL, "path": make_patrol(xf.origin, vdef)}
	return spec


## The actor's heading (the vehicles only turn about the up axis; the actor's pitch and roll are scenery settling).
static func make_yaw(rec: Dictionary) -> float:
	var forward := MapBuilder.make_transform(rec).basis * Vector3.FORWARD
	return atan2(-forward.x, -forward.z)


## Where the vehicle's origin (its lowest point, Herc._stand_on_lowest_point) goes: on the floor under the actor, else the actor's height
## less the shape's depth below its own origin.
static func make_start_point(rec: Dictionary, battle: Battle, vdef: Dictionary) -> Vector3:
	var p := _position_of(rec)
	var below := _depth_below_origin(vdef)
	var from := p + Vector3.UP * FLOOR_PROBE_UP
	var q := PhysicsRayQueryParameters3D.create(from, p + Vector3.DOWN * FLOOR_PROBE_DOWN)
	for unit in battle.get_tree().get_nodes_in_group("vehicles"):        # the floor, not a soldier or a vehicle standing there
		q.exclude.append((unit as CollisionObject3D).get_rid())
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(q)
	var y := float(hit.position.y) + SETTLE_LIFT if not hit.is_empty() and float(hit.position.y) <= p.y + FLOOR_TOLERANCE else p.y - below
	return Vector3(p.x, y, p.z)


## A loop of PATROL_POINTS around `at` (flyers), nothing for a ground vehicle (AIPilot's default to-and-fro).
static func make_patrol(at: Vector3, vdef: Dictionary) -> PackedVector3Array:
	var out := PackedVector3Array()
	if str(vdef.get("kind", "")) != "flyer":
		return out
	for i in PATROL_POINTS:
		var a := TAU * float(i) / PATROL_POINTS
		out.append(at + Vector3(cos(a), 0.0, sin(a)) * PATROL_RADIUS)
	return out


static func _position_of(rec: Dictionary) -> Vector3:
	var p: Array = rec.pos
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## Metres the shape reaches below its own origin (the bounds header is x right, y forward, z up).
static func _depth_below_origin(vdef: Dictionary) -> float:
	var b: Array = Assets.shape(str(vdef.get("shape", ""))).get("bounds", {}).get("header", [])
	return -float((b[0] as Array)[2]) if b.size() == 2 else 0.0


func _is_ally(team_name: String) -> bool:
	return _runtime.is_ally_team(team_name)


# ------------------------------------------------------------------ script access

func _named(label: String) -> Array:
	return entries.filter(func(e: Dictionary) -> bool: return str(e.rec.get("label", "")) == label)


func apply_enable(label: String, on: bool) -> void:
	for e in _named(label):
		e.enabled = on
		if on and not bool(e.spawned) and not bool(e.dead):
			apply_spawn(e)


## ActionDestroy: the vehicle is blown up (an unspawned one never appears).
func apply_destroy(label: String) -> void:
	for e in _named(label):
		e.dead = true
		var h = e.vehicle
		if h != null and is_instance_valid(h) and (h as Herc).alive:
			(h as Herc).apply_environment_damage(1.0)


## A vehicle of the battle was destroyed: the label of its entry ("" when it is not one of the map's).
func apply_death(h: Herc) -> String:
	for e in entries:
		if e.vehicle == h and not bool(e.dead):
			e.dead = true
			return str(e.rec.get("label", ""))
	return ""
