class_name TVVehicleFleet
extends RefCounted
## The drivable vehicles a Tribes: Vengeance map places (map.json "vehicles": the Vehicle* actors, "vehicle_pads": the BaseObjectVehicleSpawn*
## pads, tools/tv_vehicles.py) and the ones its script spawns (ActionSpawnRook of a Vehicle* class).
##
## Each one is a catalog vehicle of the pack (Pod, Tank, AssaultShip, Buggy: gameplay/hercs.json, docs/formats/tribes_vengeance.md) that
## appears when the player comes within SPAWN_RADIUS, parked and empty where the actor stands (the Tribes 2 vehicle pad rule: a soldier
## boards by touching it, BoardingRules). A pad holds its own vehicle (the script calls it by the pad's label + "vehicle") and builds a new
## one when it is gone, after the pad's spawnDuration. A vehicle is crewed by the vehicle's own AI pilot (the shared Flyer / AIPilot brains the
## other games use) when the actor is the enemy's and has AI goals, when a script spawns it (a rook), when a script gives it a goal or when
## a script puts a soldier into it (ActionEnterVehicle, or the soldier's own EnterVehicle goal: he walks to it and takes his seat for real).
## The goals the script adds (TVVehicleGoals: patrol, move, attack, guard) steer it
## through the shared AIOrder (VehicleOrders); with none it flies a patrol loop around its start, or drives to and fro, and attacks what it meets.
## The script's label names the vehicle: ActionEnable / ActionDestroy and MessageDeath address it as they address a soldier, and the driver
## and gunner seats raise MessageDriverEnter / DriverLeave / GunnerEnter / GunnerLeave.

const SPAWN_RADIUS := 450.0
const PER_TICK := 2
const AI_SKILL := 0.5
const PATROL_RADIUS := 150.0
const PATROL_POINTS := 4
const FLOOR_PROBE_UP := 3.0
const FLOOR_PROBE_DOWN := 60.0
const SETTLE_LIFT := 0.1
const FLOOR_TOLERANCE := 0.5                # a floor higher than the actor's centre by more is a roof
const PAD_LABEL_SUFFIX := "vehicle"
const PLAYER_LABEL := "player"
const VEHICLE_CLASSES := {"VehiclePod": "POD", "VehicleTank": "TANK", "VehicleAssaultShip": "ASSAULT_SHIP", "VehicleBuggy": "BUGGY"}
const PACK := "tribes_v"
const GUNNER_SEAT := 1

var _runtime: Node                         # the TVMissionRuntime: battle, ally rule, script
var entries: Array = []                    # [{rec, enabled, spawned, dead, vehicle (Herc), goals, applied, order, pad, respawn_at, pilot, gunner}]


func _init(runtime: Node) -> void:
	_runtime = runtime


## `records`: the map's placed vehicles; `pads`: its vehicle pads.
func build(records: Array, pads := []) -> void:
	for rec in records:
		if not Packs.vehicle(str(rec.get("vehicle", ""))).is_empty():
			add_entry(rec)
	for pad in pads:
		if not Packs.vehicle(str(pad.get("vehicle", ""))).is_empty():
			add_entry(make_pad_record(pad), pad)


## A new entry for the vehicle `rec` (a pad's vehicle has the pad as `pad`).
func add_entry(rec: Dictionary, pad := {}) -> Dictionary:
	var e := {"rec": rec.duplicate(), "enabled": true, "spawned": false, "dead": false, "vehicle": null, "goals": {}, "applied": "",
		"order": null, "pad": pad, "respawn_at": 0, "abandoned_at": 0, "pilot": 0, "gunner": 0, "pilot_named": false}
	entries.append(e)
	return e


## The pad's vehicle as a placed vehicle: standing on the pad, labelled as the scripts call it.
static func make_pad_record(pad: Dictionary) -> Dictionary:
	var p: Array = pad.pos
	return {"vehicle": str(pad.vehicle), "actor": str(pad.get("actor", "")), "label": str(pad.label) + PAD_LABEL_SUFFIX,
		"pos": [p[0], float(p[1]) + float(pad.get("offset_m", 0.0)), p[2]], "basis": pad.basis, "yaw": pad.get("yaw", 0.0),
		"team_name": str(pad.get("team_name", "")), "health_modifier": 1.0, "ai_goals": false}


## Script label -> position of the pad vehicles (objective markers point at "<pad>vehicle" before it exists).
func apply_label_positions(actors: Dictionary) -> void:
	for e in entries:
		if not (e.pad as Dictionary).is_empty():
			actors[str(e.rec.label)] = e.rec.pos
			actors[str(e.rec.label).to_lower()] = e.rec.pos


## One streaming tick: vehicles near `at` appear (PER_TICK per call), a pad whose vehicle is gone builds the next, goals steer the crewed.
func sync(at: Vector3) -> void:
	apply_respawns()
	var spawned := 0
	for e in entries:
		if not bool(e.enabled) or bool(e.spawned) or bool(e.dead):
			continue
		if at.distance_to(_position_of(e.rec)) > SPAWN_RADIUS:
			continue
		apply_spawn(e)
		spawned += 1
		if spawned >= PER_TICK:
			break
	apply_abandonment()
	apply_goals()
	apply_seat_messages()


## An empty vehicle left farther from its pad than the pad's abandon radius for the abandon time is destroyed (the class defaults
## abandonmentDesturctionStartRadius / Period), so the pad can build the next.
func apply_abandonment() -> void:
	var now := Time.get_ticks_msec()
	for e in entries:
		var h = e.vehicle
		if (e.pad as Dictionary).is_empty() or not bool(e.spawned) or bool(e.dead) or h == null or not is_instance_valid(h) or not (h as Herc).alive:
			continue
		var far: float = (h as Herc).global_position.distance_to(_position_of(e.rec))
		var left := VehicleOccupancy.of(h).is_empty() and far > float(e.pad.get("abandon_radius_m", INF))
		if not left:
			e.abandoned_at = 0
		elif int(e.abandoned_at) == 0:
			e.abandoned_at = now
		elif now - int(e.abandoned_at) >= int(float(e.pad.get("abandon_s", INF)) * 1000.0):
			apply_destroy(str(e.rec.label))


## Host: the vehicle of entry `e` appears on every peer.
func apply_spawn(e: Dictionary) -> Herc:
	e.spawned = true
	e.applied = ""
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


## The spawn spec of a placed vehicle: parked and empty, or with an AI pilot when the record says it is `crewed` (default: `ally` is false and
## the actor has goals).
static func make_spec(rec: Dictionary, battle: Battle, ally: bool) -> Dictionary:
	var vid := str(rec.vehicle)
	var vdef := Packs.vehicle(vid)
	var crewed := bool(rec.get("crewed", not ally and bool(rec.get("ai_goals", false))))
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
## less the shape's depth below its own origin. A record that says `in_air` (a script's rook spawned at an air node) keeps its height.
static func make_start_point(rec: Dictionary, battle: Battle, vdef: Dictionary) -> Vector3:
	var p := _position_of(rec)
	if bool(rec.get("in_air", false)):
		return p
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


## The catalog id of a script's Vehicle* class ("" when it names none).
static func make_vehicle_id(class_name_: String) -> String:
	for prefix in VEHICLE_CLASSES:
		if class_name_.begins_with(prefix):
			return "%s:%s" % [PACK, VEHICLE_CLASSES[prefix]]
	return ""


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
	return entries.filter(func(e: Dictionary) -> bool: return str(e.rec.get("label", "")).to_lower() == label.to_lower())


func has_label(label: String) -> bool:
	return not _named(label).is_empty()


func apply_enable(label: String, on: bool) -> void:
	for e in _named(label):
		e.enabled = on
		if on and not bool(e.spawned) and not bool(e.dead):
			apply_spawn(e)


## ActionDestroy: the vehicle is blown up (an unspawned one never appears; a pad builds the next after its spawn time).
func apply_destroy(label: String) -> void:
	for e in _named(label):
		e.dead = true
		_schedule_respawn(e)
		var h = e.vehicle
		if h != null and is_instance_valid(h) and (h as Herc).alive:
			(h as Herc).apply_environment_damage(1.0)


## A vehicle of the battle was destroyed: the label of its entry ("" when it is not one of the map's).
func apply_death(h: Herc) -> String:
	for e in entries:
		if e.vehicle == h and not bool(e.dead):
			e.dead = true
			_schedule_respawn(e)
			return str(e.rec.get("label", ""))
	return ""


## A pad builds a new vehicle `spawn_s` after the last one is gone.
func _schedule_respawn(e: Dictionary) -> void:
	var pad: Dictionary = e.pad
	if not pad.is_empty():
		e["respawn_at"] = Time.get_ticks_msec() + int(float(pad.get("spawn_s", 0.0)) * 1000.0)


func apply_respawns() -> void:
	var now := Time.get_ticks_msec()
	for e in entries:
		if bool(e.dead) and int(e.respawn_at) > 0 and now >= int(e.respawn_at):
			e.dead = false
			e.spawned = false
			e.vehicle = null
			e.respawn_at = 0
			e.pilot_named = false
			e.goals.clear()


## ActionSpawnRook of a Vehicle* class: a crewed vehicle of `team_name` appears at `at` (a script's label position) and is called `label`.
## A rook of the player's side flies for him, of the other side against him. Returns the entry ({} for an unknown class).
func apply_spawn_vehicle(vehicle_class: String, label: String, team_name: String, at: Array) -> Dictionary:
	var vid := make_vehicle_id(vehicle_class)
	if vid == "" or at.size() < 3:
		return {}
	var rec := {"vehicle": vid, "actor": vehicle_class, "label": label, "pos": at, "basis": [[1, 0, 0], [0, 1, 0], [0, 0, 1]], "yaw": 0.0,
		"team_name": team_name, "health_modifier": 1.0, "ai_goals": true, "crewed": true, "in_air": true}
	var e := add_entry(rec)
	apply_spawn(e)
	return e


## ActionEnterVehicle: a soldier takes the pilot's seat of the vehicle `vehicle_label`, so the vehicle is crewed (a parked, empty one is
## replaced by a crewed one where it stands).
func apply_crew(vehicle_label: String) -> void:
	for e in _named(vehicle_label):
		_apply_crewed(e)


## ActionAddGoal / ReplaceGoal / RemoveGoal on a vehicle's label: the goals are kept by name (TVNpcGoals). A vehicle given a goal is
## crewed. Returns true when `label` names a vehicle of the fleet.
func apply_goal(label: String, mode: String, name: String, goal: Dictionary) -> bool:
	var found := _named(label)
	for e in found:
		if mode != "remove" and str(goal.get("kind", "")) == TVVehicleGoals.KIND_EXPEL:
			_apply_uncrewed(e, str(goal.get("occupant", "")))
		elif mode == "remove" or TVVehicleGoals.is_vehicle_goal(goal):
			TVNpcGoals.apply(e, mode, name, goal)
		if mode != "remove" and TVVehicleGoals.is_vehicle_goal(goal):
			_apply_crewed(e)
	return not found.is_empty()


## AI_VehicleExpellOccupantGoal: the occupant gets out where the vehicle stands and it is parked and empty (stealable). A placed soldier who
## climbed in for real steps out beside the hull; the vehicle's own AI pilot is put out by building the vehicle again, empty, and the soldier
## `occupant` (who boarded by ActionEnterVehicle without a seat) is in the world again beside it.
func _apply_uncrewed(e: Dictionary, occupant: String) -> void:
	e.goals.clear()
	e.applied = ""
	e.rec["crewed"] = false
	var h = e.vehicle
	var alive: bool = bool(e.spawned) and h != null and is_instance_valid(h) and (h as Herc).alive
	var rider := _find_rider(h, occupant) if alive else null
	if rider != null:
		_runtime.battle.occupancy.apply_exit(make_seat_id(rider), h)
		return
	var at := _position_of(e.rec)
	if alive:
		at = (h as Herc).global_position
		var yaw := (h as Herc).rotation.y
		e.rec["pos"] = [at.x, at.y, at.z]
		e.rec["basis"] = [[cos(yaw), 0.0, sin(yaw)], [0.0, 1.0, 0.0], [-sin(yaw), 0.0, cos(yaw)]]
		e.rec["in_air"] = h is Flyer and (h as Flyer).make_altitude() > FLOOR_TOLERANCE
		_runtime.battle.remove_vehicle((h as Herc).net_id)
		apply_spawn(e)
	if occupant != "":
		_runtime.apply_expelled(occupant, at)


## The placed soldier `label` when he sits in `h`, else null.
func _find_rider(h: Herc, label: String) -> Infantry:
	var s := _runtime.find_soldier(label) as Infantry if label != "" else null
	return s if s != null and VehicleOccupancy.of(h).seat_of(make_seat_id(s)) >= 0 else null


func _apply_crewed(e: Dictionary) -> void:
	if bool(e.rec.get("crewed", false)):
		return
	e.rec["crewed"] = true
	var h = e.vehicle
	if bool(e.spawned) and h != null and is_instance_valid(h) and (h as Herc).alive and VehicleOccupancy.of(h).is_empty():
		_runtime.battle.remove_vehicle((h as Herc).net_id)
		apply_spawn(e)


# ------------------------------------------------------------------ soldiers aboard

## The vehicle called `label`, spawned and alive (null when it is none of those).
func find_herc(label: String) -> Herc:
	for e in _named(label):
		var h = e.vehicle
		if bool(e.spawned) and not bool(e.dead) and h != null and is_instance_valid(h) and (h as Herc).alive:
			return h as Herc
	return null


## A placed soldier takes a seat of the vehicle `label` for real (the shared boarding: the vehicle takes his team, a pilot is flown for by the
## bot brain, a gunner works the turret). `seat` -1 = the first seat he may take (ActionEnterVehicle has none), but never one behind an unfilled
## pilot's seat. A vehicle that is flown by its own AI already counts its first soldier -1 asked for as that pilot: he gets no seat. Returns false
## when he took none; the caller then takes him out of the world (the vehicle is crewed without him).
func apply_board(label: String, soldier: Infantry, seat: int) -> bool:
	var h := find_herc(label)
	if h == null or not soldier.alive or soldier.stowed:
		return false
	if seat < 0 and _take_ai_pilot(label, h):
		return false
	var chosen := make_seat(soldier, h, seat)
	if chosen < 0:
		return false
	_runtime.battle.occupancy.apply_board(make_seat_id(soldier), h, chosen)
	return true


## The first soldier put into a vehicle that its own AI flies is that pilot (once per vehicle); true when this call is that one.
func _take_ai_pilot(label: String, h: Herc) -> bool:
	if VehicleOccupancy.of(h).pilot() != VehicleOccupancy.AI_PILOT:
		return false
	for e in _named(label):
		if e.vehicle == h and not bool(e.pilot_named):
			e.pilot_named = true
			return true
	return false


## The id a placed soldier holds a seat under: his bot id (a soldier who pilots or guns gives up his owner_peer, OccupancyDirector).
static func make_seat_id(soldier: Infantry) -> int:
	return int(soldier.get_meta("bot_id", soldier.owner_peer))


## The seat `soldier` takes in `h`: the one asked for if it is free and his armour may sit in it, else (-1 asked) the first such seat, but
## never a seat behind an unfilled pilot's. -1 when there is none.
static func make_seat(soldier: Infantry, h: Herc, asked: int) -> int:
	var occ := VehicleOccupancy.of(h)
	for seat in occ.seats.size():
		if (asked >= 0 and seat != asked) or not occ.is_seat_free(seat) or not BoardingRules.is_seat_allowed(soldier, h, seat):
			continue
		return seat if seat == VehicleOccupancy.PILOT_SEAT or occ.has_pilot() else -1
	return -1


# ------------------------------------------------------------------ goals

## The context the goals look places and targets up in: the script's actors, the player, the node a label names.
func make_goal_context() -> Dictionary:
	var p: Herc = _runtime.battle.player
	return {"actors": _runtime.script_data.get("actors", {}) if _runtime.script_data != null else {},
		"player": p.global_position if p != null and is_instance_valid(p) else Vector3.ZERO, "node_of": find_node}


## The player, a vehicle of the fleet or a placed soldier called `label` (null when none is alive).
func find_node(label: String) -> Node3D:
	if label.to_lower() == PLAYER_LABEL:
		var p: Herc = _runtime.battle.player
		return p if p != null and is_instance_valid(p) else null
	for e in _named(label):
		if e.vehicle != null and is_instance_valid(e.vehicle):
			return e.vehicle
	return _runtime.find_soldier(label)


## Steers every crewed vehicle that has goals: the top goal becomes an AIOrder, an achieved goal is dropped.
func apply_goals() -> void:
	var ctx := make_goal_context()
	for e in entries:
		var h = e.vehicle
		if not bool(e.spawned) or bool(e.dead) or h == null or not is_instance_valid(h) or not (h as Herc).alive:
			continue
		if not is_flown_by_ai(h as Herc):
			continue
		_steer(e, h as Herc, ctx)


## True when the vehicle's pilot is its own AI or a bot soldier (a placed soldier who climbed in), so a goal can steer it.
static func is_flown_by_ai(h: Herc) -> bool:
	var pilot := VehicleOccupancy.of(h).pilot()
	return pilot == VehicleOccupancy.AI_PILOT or InfantryBots.is_bot(pilot)


func _steer(e: Dictionary, h: Herc, ctx: Dictionary) -> void:
	var g := TVVehicleGoals.make_top_goal(e)
	if g.is_empty():
		e.applied = ""
		return
	if str(g.key) == str(e.applied):
		if TVVehicleGoals.is_achieved(g, h, e.order, ctx):
			(e.goals as Dictionary).erase(g.key)
			e.applied = ""
			VehicleOrders.apply(h, AIOrder.make_hold_at(h.global_position))
		return
	var order := TVVehicleGoals.make_order(g, h, _position_of(e.rec), ctx)
	if order == null:
		return
	e.order = order
	e.applied = str(g.key)
	VehicleOrders.apply(h, order)


# ------------------------------------------------------------------ seat messages

## The driver's and the gunner's seats raise the script messages (a player boarding or leaving).
func apply_seat_messages() -> void:
	if _runtime.script_run == null:
		return
	for e in entries:
		var h = e.vehicle
		if not bool(e.spawned) or h == null or not is_instance_valid(h):
			continue
		var occ := VehicleOccupancy.of(h)
		var label := str(e.rec.get("label", ""))
		_fire_seat(e, "pilot", "MessageDriverEnter", "MessageDriverLeave", occ.pilot(), label)
		_fire_seat(e, "gunner", "MessageGunnerEnter", "MessageGunnerLeave", _seat_peer(occ, GUNNER_SEAT), label)


func _fire_seat(e: Dictionary, key: String, enter: String, leave: String, now: int, label: String) -> void:
	var was := int(e[key])
	e[key] = now
	if was == now:
		return
	if now > 0:
		_runtime.script_run.fire(enter, label)
	elif was > 0:
		_runtime.script_run.fire(leave, label)


static func _seat_peer(occ: VehicleOccupancy, seat: int) -> int:
	return occ.seats[seat] if seat < occ.seats.size() else VehicleOccupancy.EMPTY
