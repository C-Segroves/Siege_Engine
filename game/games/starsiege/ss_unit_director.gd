class_name SSUnitDirector
extends RefCounted
## Mission AI units of a Starsiege mission: spawns the .mis vehicles with their pilots and turns the
## scripts' order() calls (attack, guard routes, formation, speed, holdFire, shutdown, ...) into
## AIPilot settings. Unit state: {pilot, mode, goal, arrived, speed, max_speed, sensor, last_index}.

## order(..., speed, <level>) -> fraction of the vehicle's top speed.
const SPEEDS := {"low": 0.4, "slow": 0.4, "medium": 0.7, "high": 1.0, "fast": 1.0}
const DEFAULT_SKILL := 0.5
const DEFAULT_SENSOR_RANGE := 900.0
const LAST_RESORT_VEHICLE := "es1:RAPTOR"
const UNIT_START_LIFT := 0.5

var rt: StarsiegeMissionRuntime
var tree: SSObjectTree
var units := {}            # obj id -> unit state
var formations := {}       # lower name -> Formation (engine local offsets)


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime
	tree = runtime.tree


# ------------------------------------------------------------------ spawning

## Spawns the mission vehicle of object `id` through the Battle and gives it a guarding pilot.
func spawn_vehicle(id: int) -> void:
	var o: Dictionary = tree.objects[id]
	var d: Dictionary = o.def
	var pos := _spawn_position(o)
	var xf := Transform3D(Basis(Vector3.UP, float(d.get("yaw", 0.0))), pos)
	var pilot_rec = _pilot_record(int(d.get("pilot", 0)))
	var skill := DEFAULT_SKILL
	var pilot_name := ""
	if pilot_rec is Dictionary:
		skill = clampf(float(pilot_rec.get("skill", DEFAULT_SKILL)), 0.1, 1.0)
		pilot_name = str(pilot_rec.get("name", ""))
	var info := {"skill": skill, "group": 1 + id, "order": 6, "path": []}
	if o.kind == "flyer":
		info["flyer"] = true
		info["path"] = SSFlyerOrders.make_patrol(pos)
	var team: int = StarsiegeMissionRuntime.TEAM_OF.get(o.team, SSTeams.NEUTRAL)
	var h: Herc = rt.battle.spawn_ai(_vehicle_id_for(d), team, xf, _loadout_of(d), pilot_name, info)
	if h == null:
		return
	o.node = h
	h.set_meta("ss_id", id)
	h.set_meta(StarsiegeCommandProvider.PILOT_META, str(int(d.get("pilot", 0))))   # his voice set (squad orders)
	rt.watch_unit(h, id)
	_apply_cloak_install(h, d)
	_register_unit(id, h, pos)
	apply_team_stance(id)
	if h is Flyer and SSFlyerOrders.is_parked_placement(rt, d):
		SSFlyerOrders.park(h as Flyer)


func _spawn_position(o: Dictionary) -> Vector3:
	var pos := SSObjectTree.position_of_def(o.def)
	if o.kind == "flyer":
		pos.y = rt.ground_height_at(pos) + 0.5
		return pos
	return rt.make_start_position(pos, UNIT_START_LIFT)


## The cloak among the mountables the .mis lists for the vehicle (datIntMounts.cs newCloak), when its catalog entry has none.
func _apply_cloak_install(h: Herc, d: Dictionary) -> void:
	if h.cloak.is_equipped():
		return
	var p := CloakProfile.of_mountables(StarsiegeMissionRuntime.PACK, MissionRuntime._arr(d.get("mountables")))
	if p.is_real():
		h.cloak.apply_profile(p)


## Weapon ids per hardpoint; a vehicle listing no weapon at all keeps its catalog loadout.
static func _loadout_of(d: Dictionary) -> Array:
	var loadout := []
	var armed := false
	for w in MissionRuntime._arr(d.get("weapons")):
		loadout.append(String(w) if w != null else "")
		if w != null:
			armed = true
	return loadout if armed else []


func _register_unit(id: int, h: Herc, pos: Vector3) -> void:
	var pilot: AIPilot = null
	for c in h.get_children():
		if c is AIPilot:
			pilot = c
	units[id] = {"pilot": pilot, "mode": "idle", "goal": 0, "arrived": false, "speed": 1.0,
		"max_speed": h.max_speed, "sensor": pilot.sensor_range if pilot else DEFAULT_SENSOR_RANGE, "last_index": 0}
	if pilot:
		pilot.order = AIPilot.Order.GUARD
		pilot.guard_point = pos
		pilot.path_finished.connect(_on_path_finished.bind(id))


## Catalog vehicle for a .mis vehicle: explicit id, the datVehicle id table, the shape name, else any.
func _vehicle_id_for(d: Dictionary) -> String:
	var pack := StarsiegeMissionRuntime.PACK
	var v = d.get("vehicle")
	if v is String and v != "" and not Packs.vehicle(v).is_empty():
		return v
	var ids = Assets.load_json("gameplay/ids.json", pack)
	if ids is Dictionary:
		var key = ids.get("vehicles", {}).get(str(int(d.get("vehicle_id", 0))))
		if key != null and not Packs.vehicle("%s:%s" % [pack, key]).is_empty():
			return "%s:%s" % [pack, key]
	var shp := String(d.get("vehicle_shape", ""))
	if shp != "" and not Packs.vehicle("%s:%s" % [pack, shp]).is_empty():
		return "%s:%s" % [pack, shp]
	return _any_pilotable_vehicle()


## Fallback so the mission still runs: any pilotable vehicle, preferring Starsiege's own.
static func _any_pilotable_vehicle() -> String:
	var any := Packs.pilotable([StarsiegeMissionRuntime.PACK])
	if any.is_empty():
		any = Packs.pilotable()
	return String(any[0].id) if not any.is_empty() else LAST_RESORT_VEHICLE


## The script-declared Pilot object with this id (skill, name), or null.
func _pilot_record(pilot_id: int):
	if pilot_id <= 0:
		return null
	for k in rt.vm.objects:
		var ob: Dictionary = rt.vm.objects[k]
		if String(ob.get("__type", "")).to_lower() == "pilot" and int(SSScript.num(ob.get("id", -1))) == pilot_id:
			return ob
	return null


## Neutral units (team 9) take no side: AIPilot and FlyerAI skip vehicles marked "dormant" when they
## look for targets, and a neutral pilot looks for none of its own (a scripted attack order still
## names its target). Re-applied when a script changes the unit's team (setTeam).
func apply_team_stance(id: int) -> void:
	var h := tree.node_of(id) as Herc
	if h == null:
		return
	var neutral := SSTeams.is_neutral(h.team)
	if neutral:
		h.set_meta("dormant", true)
	elif h.has_meta("dormant"):
		h.remove_meta("dormant")
	var u: Dictionary = units.get(id, {})
	if u.is_empty() or u.pilot == null:
		return
	if neutral:
		u.sensor = 0.0
		u.pilot.sensor_range = 0.0
	elif float(u.sensor) <= 0.0:
		u.sensor = DEFAULT_SENSOR_RANGE
		u.pilot.sensor_range = DEFAULT_SENSOR_RANGE


func _on_path_finished(_p: AIPilot, id: int) -> void:
	var u: Dictionary = units.get(id, {})
	if u.is_empty() or u.arrived:
		return
	u.arrived = true
	rt.raise_object_callback(id, "vehicle", "onarrived", [id, u.get("goal", 0)])


# ------------------------------------------------------------------ per-frame

## Keeps followers on their leader, reports route laps (onArrived) and re-engages attack targets.
func update() -> void:
	for id in units:
		var u: Dictionary = units[id]
		var h = tree.objects[id].node
		if h == null or not is_instance_valid(h) or not h.alive or u.pilot == null:
			continue
		match String(u.mode):
			"follow":
				_follow_goal(u)
			"route":
				_track_route_lap(id, u)
			"attack":
				_keep_attacking(h, u)


func _follow_goal(u: Dictionary) -> void:
	var p: AIPilot = u.pilot
	p.order = AIPilot.Order.GUARD
	p.guard_point = tree.position_of(int(u.goal))


func _track_route_lap(id: int, u: Dictionary) -> void:
	var p: AIPilot = u.pilot
	if p.patrol_index < int(u.last_index):
		rt.raise_object_callback(id, "vehicle", "onarrived", [id, u.goal])
	u.last_index = p.patrol_index


func _keep_attacking(h: Herc, u: Dictionary) -> void:
	var p: AIPilot = u.pilot
	var t = tree.objects.get(int(u.goal), {}).get("node")
	if t != null and is_instance_valid(t) and t.alive and not p.engaging:
		h.target = t
		p.engaging = true


# ------------------------------------------------------------------ orders

## order(who, what, args...): applies to every vehicle in `who` (formation applies to the group).
func order(who, what: String, args: Array) -> void:
	var wid := tree.resolve(who)
	rt.log_debug("order %s (%s) %s %s" % [who, tree.objects.get(wid, {}).get("path", "?"), what, args])
	var members := tree.vehicles_in(wid)
	what = what.to_lower()
	if what == "formation":
		_apply_formation(members, SSScript.to_str(args[0] if args.size() > 0 else "").to_lower())
		return
	for u in members:
		order_unit(u, what, args)


## newFormation(name, x0, y0, z0, x1, y1, z1, ...): the first triple is the leader slot.
func define_formation(name: String, coords: Array) -> void:
	var offs := []
	var i := 0
	while i + 2 < coords.size():
		offs.append(StarsiegeMissionRuntime.orig_to_eng(SSScript.num(coords[i]), SSScript.num(coords[i + 1]),
			SSScript.num(coords[i + 2])))
		i += 3
	formations[name.to_lower()] = Formation.make_scripted(offs)


func _apply_formation(members: Array, formation_name: String) -> void:
	var formation: Formation = formations.get(formation_name, Formation.make_scripted([]))
	var leader_id := _formation_leader(members)
	var k := 0
	for u in members:
		var p: AIPilot = units.get(u, {}).get("pilot")
		if p == null:
			continue
		if u == leader_id:
			p.leader = null
			continue
		k += 1
		p.leader = tree.node_of(leader_id) as Herc
		p.formation_offset = formation.offset_of(k)


func _formation_leader(members: Array) -> int:
	var leader_id := 0
	for u in members:
		if tree.objects[u].get("leader", false):
			leader_id = u
	if leader_id == 0 and not members.is_empty():
		leader_id = members[0]
	return leader_id


func order_unit(id: int, what: String, args: Array) -> void:
	var u: Dictionary = units.get(id, {})
	var h := tree.node_of(id) as Herc
	if u.is_empty() or h == null:
		return
	if what == "cloak":
		_order_cloak(h, args)
		return
	if h is Flyer:
		SSFlyerOrders.order(tree, h as Flyer, what, args)
		return
	var a0 = args[0] if args.size() > 0 else ""
	match what:
		"attack":
			_order_attack(u, h, a0)
		"guard":
			_order_guard(u, a0, args)
		"speed":
			h.max_speed = float(u.max_speed) * float(SPEEDS.get(SSScript.to_str(a0).to_lower(), 1.0))
		"makeleader":
			_order_make_leader(id, u, a0)
		"holdfire":
			_order_hold_fire(u, h, SSScript.truthy(a0))
		"shutdown":
			_order_shutdown(u, h, SSScript.truthy(a0))
		"holdposition", "clear", "holdposision":
			if what != "holdposition" or SSScript.truthy(a0) or args.is_empty():
				_order_hold_position(u, h)
		_:
			pass   # height, flythrough, zigzag, useactiveradar, retreat: not modelled


## cloak <on>: the vehicle switches its cloak component on or off; without one the order does nothing.
static func _order_cloak(h: Herc, args: Array) -> void:
	h.cloak_input = SSScript.truthy(args[0]) if not args.is_empty() else true


func _order_attack(u: Dictionary, h: Herc, target) -> void:
	var tid := tree.resolve(target)
	if tid != 0 and tree.kind_of(tid) == "group" or tree.player_objs.has(tid):
		var alive := tree.alive_units_in(tid)
		tid = alive[randi() % alive.size()] if not alive.is_empty() else tid
	var t := tree.node_of(tid)
	u.mode = "attack"
	u.goal = tid
	var p: AIPilot = u.pilot
	if p and t != null:
		p.leader = null
		var attack := AIOrder.new()
		attack.kind = AIOrder.SEARCH
		attack.apply_to_pilot(p)
		AIOrder.apply_engage(p, t)


## guard <group>: patrol its markers (or follow its units); guard <vehicle>: follow it;
## guard <object>: travel there; guard x, y: travel to a map point.
func _order_guard(u: Dictionary, goal, args: Array) -> void:
	var gid := tree.resolve(goal)
	u.arrived = false
	u.goal = gid
	var p: AIPilot = u.pilot
	if p == null:
		return
	p.leader = null
	if tree.kind_of(gid) == "group":
		_guard_group(u, gid)
	elif tree.is_vehicle(gid) or tree.player_objs.has(gid):
		u.mode = "follow"
	elif gid != 0:
		_travel_to(u, tree.position_of(gid))
	elif args.size() >= 2 and SSScript.is_num(args[0]):
		var pt := StarsiegeMissionRuntime.orig_to_eng(SSScript.num(args[0]), SSScript.num(args[1]), 0.0)
		pt.y = rt.ground_height_at(pt)
		_travel_to(u, pt)


func _guard_group(u: Dictionary, gid: int) -> void:
	var p: AIPilot = u.pilot
	var pts := tree.route_points(gid)
	if pts.is_empty():
		var members := tree.alive_units_in(gid)
		if not members.is_empty():
			u.mode = "follow"
			u.goal = members[0]
			return
		pts.append(tree.position_of(gid))
	AIOrder.make_route(AIOrder.PATROL, pts, true).apply_to_pilot(p)
	u.mode = "route"
	u.last_index = 0


func _travel_to(u: Dictionary, point: Vector3) -> void:
	var p: AIPilot = u.pilot
	AIOrder.make_route(AIOrder.TRAVEL, [point] as Array[Vector3], false).apply_to_pilot(p)
	u.mode = "travel"


func _order_make_leader(id: int, u: Dictionary, flag) -> void:
	tree.objects[id]["leader"] = SSScript.truthy(flag)
	if u.pilot and SSScript.truthy(flag):
		u.pilot.leader = null


func _order_hold_fire(u: Dictionary, h: Herc, hold: bool) -> void:
	var p: AIPilot = u.pilot
	if p == null:
		return
	p.sensor_range = 0.0 if hold else float(u.sensor)
	if hold:
		p.engaging = false
		h.target = null


func _order_shutdown(u: Dictionary, h: Herc, off: bool) -> void:
	var p: AIPilot = u.pilot
	if p == null:
		return
	p.process_mode = Node.PROCESS_MODE_DISABLED if off else Node.PROCESS_MODE_INHERIT
	if off:
		h.throttle = 0.0
		h.turn = 0.0
		for w in h.weapons:
			w.trigger = false


func _order_hold_position(u: Dictionary, h: Herc) -> void:
	var p: AIPilot = u.pilot
	if p == null:
		return
	AIOrder.make_hold_at(h.global_position).apply_to_pilot(p)
	u.mode = "idle"
