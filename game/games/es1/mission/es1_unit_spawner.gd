class_name ES1UnitSpawner
extends RefCounted
## Spawns an Earthsiege 1 mission group (MissionRuntime): flyer groups as Skimmers in formation,
## Herc groups with their mission records' type, position, weapons, orders, path and leader.

const FLYER_VEHICLE := "es1:SKIMMER"
const FLYER_LOADOUT := ["es1:LAS100"]
const FLYER_SKILL := 0.5
## Default herc type (NAM order) / group order (ES1 order code) when a record has none.
const DEFAULT_HERC_TYPE := 9
const DEFAULT_ORDER := 8

var rt: MissionRuntime


func _init(runtime: MissionRuntime) -> void:
	rt = runtime


## Spawns group gi's units; returns the Hercs (flyer groups return none, as the original runtime).
func spawn_group(gi: int) -> Array:
	var g: Dictionary = rt.m.groups[gi]
	var path: Array[Vector3] = []
	for p in MissionRuntime._arr(g.get("path_points")):
		path.append(MissionRuntime.to_godot(p))
	var spawn := {"gi": gi, "g": g, "path": path, "base": MissionRuntime._group_base_position(g, path),
		"yaw": MissionRuntime._group_yaw(g, path)}
	if rt._kind_code(g) == MissionRuntime.KIND_FLYER:
		_spawn_flyers(spawn)
		return []
	return _spawn_hercs(spawn)


func _spawn_flyers(spawn: Dictionary) -> void:
	var g: Dictionary = spawn.g
	var yaw: float = spawn.yaw
	var flyers: Array = MissionRuntime._arr(rt.m.get("flyers"))
	var k := 0
	for mi in MissionRuntime._arr(g.get("members")):
		if int(mi) >= flyers.size():
			continue
		var fpos: Vector3 = spawn.base + rt._formation_offset("flyer", int(g.get("formation", 0)), k, yaw)
		var fl = rt.battle.spawn_ai(FLYER_VEHICLE, int(g.get("team", 1)), Transform3D(Basis(Vector3.UP, yaw), fpos),
			FLYER_LOADOUT, "Skimmer", {"skill": FLYER_SKILL, "group": spawn.gi, "path": spawn.path, "flyer": true})
		_register(fl, "flyer", int(mi))
		k += 1


func _spawn_hercs(spawn: Dictionary) -> Array:
	var g: Dictionary = spawn.g
	var yaw: float = spawn.yaw
	var hercs: Array = MissionRuntime._arr(rt.m.get("hercs"))
	var leader: Herc = null
	var units := []
	var k := 0
	for mi in MissionRuntime._arr(g.get("members")):
		var h: Dictionary = hercs[int(mi)] if int(mi) < hercs.size() else {}
		if h.is_empty():
			continue
		var vid := "es1:%s" % MissionRuntime.MECH_SHAPES[clampi(int(h.get("type", DEFAULT_HERC_TYPE)), 0, MissionRuntime.MECH_SHAPES.size() - 1)]
		var pos: Vector3 = MissionRuntime.to_godot(h.position) if h.get("position") != null \
			else spawn.base + rt._formation_offset("mech", int(g.get("formation", 0)), k, yaw)
		pos = rt.make_clear_spawn(pos)
		var info := {"skill": _es1_skill(h), "group": spawn.gi, "order": int(g.get("orders", DEFAULT_ORDER)), "path": spawn.path,
			"leader": leader.net_id if leader else 0, "formation_slot": k, "health": int(h.get("health", 100))}
		var unit: Herc = rt.battle.spawn_ai(vid, int(g.get("team", 1)), Transform3D(Basis(Vector3.UP, yaw), pos),
			_loadout_for(vid, MissionRuntime._arr(h.get("weapons"))), "", info)
		if unit == null:
			continue
		_register(unit, "herc", int(mi))
		if leader == null:
			leader = unit
		units.append(unit)
		k += 1
	return units


## Links a spawned unit to its mission record (death / alert regions, order targets: MissionTargets).
func _register(unit: Node, kind: String, record: int) -> void:
	if unit == null:
		return
	unit.set_meta("%s_index" % kind, record)
	rt.unit_index["%s:%d" % [kind, record]] = unit


## Pilot skill from the mission difficulty and the herc's block word 0.
func _es1_skill(h: Dictionary) -> float:
	var difficulty := float(rt.m.get("header", {}).get("difficulty", 2))
	return clampf(0.3 + 0.1 * difficulty + 0.03 * float(h.get("flag0", 0)), 0.2, 0.95)


## Original herc weapon ids are per hardpoint slot (gun.loadout_slot); 17 / -1 = none.
func _loadout_for(vid: String, ids: Array) -> Array:
	var v := Packs.vehicle(vid)
	var names: Array = []
	var w = Assets.load_json("gameplay/weapons.json")
	if w is Dictionary:
		for x in MissionRuntime._arr(w.get("weapons")):
			names.append(x.name)
	var out := []
	var armed := false
	for g in v.get("guns", []):
		var slot := int(g.get("loadout_slot", 0))
		var wid := int(ids[slot]) if slot < ids.size() else -1
		if wid >= 0 and wid < names.size():
			out.append("es1:%s" % names[wid])
			armed = true
		else:
			out.append("")   # keep hardpoint order (Herc.equip: slot index = hardpoint index)
	return out if armed else v.get("loadout", [])
