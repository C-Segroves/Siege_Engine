class_name FlagResponse
extends RefCounted
## The owning faction's answer to a stolen raid-task flag (host; extraction_rules.json "flag_response"): after
## delay_s a squad of infantry bots (and by vehicle_chance an armed vehicle) of that faction spawns out of the
## carrier's sight spawn_distance_m away and hunts him (InfantryBot.objective, AIPilot guard on his position).
## When the carrier dies the flag lies in his bag: the squad runs to it and, within retake_radius_m, takes it back to
## the faction's base (the flag container is put back at its home). Bots and vehicles replicate like every bot.

const SIGHT_TRIES := 16
const EYE := Vector3.UP * 1.7

var director: ExtractionDirector
var rng := RandomNumberGenerator.new()
## Per task id: {state: "wait" | "hunt" | "done", timer, bots, vehicle, home: Vector3, faction}.
var responses := {}


func _init(p_director: ExtractionDirector) -> void:
	director = p_director


static func rules() -> Dictionary:
	return ExtractionRules.data().get("flag_response", {})


## One host tick (RaidTasks._process) over the task states `states`.
func apply_tick(states: Array, delta: float) -> void:
	for task in states:
		if str(task.kind) != RaidTaskBoard.KIND_FLAG or bool(task.void) or not task.has("target"):
			continue
		var id := str(task.id)
		var carrier := find_carrier()
		if not responses.has(id):
			if carrier == null:
				continue
			responses[id] = {"state": "wait", "timer": float(rules().get("delay_s", 8.0)), "bots": [], "vehicle": null,
				"home": task.target, "faction": str(task.faction)}
		var r: Dictionary = responses[id]
		match str(r.state):
			"wait":
				r.timer = float(r.timer) - delta
				if float(r.timer) <= 0.0 and carrier != null:
					_spawn(r, carrier)
			"hunt":
				_hunt(r, carrier)


## The soldier carrying a faction flag (null when none carries one).
func find_carrier() -> Infantry:
	for peer in director.inventories:
		if (director.inventories[peer] as ExtractionInventory).count(RaidTasks.FLAG_ITEM) > 0:
			var s := director.battle.occupancy.soldier_of(int(peer))
			if s != null and s.alive:
				return s
	return null


func _spawn(r: Dictionary, carrier: Infantry) -> void:
	var team := -1
	for t in director.faction_teams:
		if str(director.faction_teams[t]) == str(r.faction):
			team = int(t)
	if team < 0 or director.squads == null:
		r.state = "done"
		return
	var at := make_spawn_point(carrier)
	r["spawn"] = at
	var rr := rules()
	var n := ExtractionRules.roll_range(director.squads.rng, rr.get("infantry", [3, 5]))
	var with_vehicle := director.squads.rng.randf() < float(rr.get("vehicle_chance", 0.35))
	var made := director.squads.spawn_response(str(r.faction), team, at, n, with_vehicle)
	r.bots = made.bots
	r.vehicle = made.vehicle
	r.state = "hunt"


## A point spawn_distance_m from `carrier` that he cannot see (never on top of him); the last try when every one
## is in view.
func make_spawn_point(carrier: Infantry) -> Vector3:
	var span: Array = rules().get("spawn_distance_m", [150.0, 300.0])
	var best := carrier.global_position
	for i in SIGHT_TRIES:
		var a := rng.randf() * TAU
		var d := rng.randf_range(float(span[0]), float(span[1]))
		var xz := Vector2(carrier.global_position.x + cos(a) * d, carrier.global_position.z + sin(a) * d)
		if not director.map.is_inside(xz):
			continue
		var p := director.map.make_ground(xz)
		best = p
		if not LineOfSight.is_clear(carrier, carrier.global_position + EYE, carrier, p + EYE):
			return p
	return best


func _hunt(r: Dictionary, carrier: Infantry) -> void:
	var bag := _find_flag_container()
	var goal := Vector3.INF
	var target: Node3D = null
	if carrier != null:
		goal = carrier.global_position
		target = carrier
	elif bag != null:
		goal = bag.position
	var radius := float(rules().get("retake_radius_m", 4.0))
	for b in r.bots:
		if not is_instance_valid(b) or not (b as InfantryBot).soldier.alive:
			continue
		var brain := b as InfantryBot
		if goal != Vector3.INF:
			brain.objective = {"point": goal, "urgent": true, "radius": radius, "hold": false, "target": target}
		if carrier == null and bag != null and brain.soldier.global_position.distance_to(bag.position) <= radius:
			_return_flag(r, bag)
			return
	var v = r.vehicle
	if goal != Vector3.INF and is_instance_valid(v):
		for c in (v as Herc).get_children():
			if c is AIPilot:
				(c as AIPilot).guard_point = goal


## The container (a dead carrier's bag, or the loose flag) that holds the flag item; null when none.
func _find_flag_container() -> LootContainer:
	for c in director.containers.values():
		var lc := c as LootContainer
		for st in lc.stacks:
			if str(st[0]) == RaidTasks.FLAG_ITEM:
				return lc
	return null


## The squad takes the flag out of `bag` and puts it back where it lay; the squad stands down.
func _return_flag(r: Dictionary, bag: LootContainer) -> void:
	var rest := bag.stacks.filter(func(st: Array) -> bool: return str(st[0]) != RaidTasks.FLAG_ITEM)
	director._set_container(bag.container_id, rest, bag.money)
	director.add_container({"kind": RaidTasks.FLAG_CONTAINER, "stacks": [[RaidTasks.FLAG_ITEM, 1]], "money": 0}, r.home)
	r.state = "done"
	for b in r.bots:
		if is_instance_valid(b):
			(b as InfantryBot).objective = {}
