class_name MissionRuntimeES2
extends MissionRuntime
## Runs an Earthsiege 2 mission (MissionCompilerES2 output, docs/formats/es2.md section 10) with the
## Earthsiege 1 battle runtime: vehicles from pack "es2", heightmap terrain (units are dropped on
## the ground), per-group order lists (ES2GroupOrders), trigger regions with (var, op) actions and
## HUD texts, timers (region chains), explicit objectives (ES2Objectives: success / failure
## conditions) and the debriefing chosen by recompiling the mission with the final mission variables
## (as the original shell does).

const PACK := "es2"
const NVARS := 1000
## herc types that fly (NAM/MECHS.NAM 8 = RAZOR); everything else walks
const FLYING_HERCS := ES2UnitCatalog.FLYING_HERCS
const FALLBACK_VEHICLE := ES2UnitCatalog.FALLBACK_VEHICLE
const WEAPON_NAMES := ES2UnitCatalog.WEAPON_NAMES
const GUIDANCE := ES2UnitCatalog.GUIDANCE
## Region param: how a dormant group arrives relative to the player (DBSIM 0x4236c4):
## param -> [distance (original units), spread (rad), centre bearing (rad)]; make_arrival_waves turns it into SpawnWaves.
const ARRIVAL_UNITS := {2: [150000.0, PI / 2.0, 0.0], 3: [150000.0, PI / 8.0, PI / 8.0],
	4: [90000.0, PI / 8.0, PI], 5: [150000.0, PI / 4.0, 0.0]}
const DEFAULT_HERC_TYPE := "MONGOOSE"
## A unit starts this far above the terrain (on_unit_ground).
const UNIT_LIFT := 0.5
const DEFAULT_STRUCTURE_HP := 15000.0
## Seconds the objectives line (the one queued message) stays up.
const OBJECTIVES_MESSAGE_SECONDS := 10.0
## Mission variable change tables (docs/formats/es2.md 10.5): {op: change} and {op: operand}. Unit and group deaths use
## the Earthsiege 1 table (VAR_OPS / VAR_OPERANDS).
const TABLE_OBJECTIVE := "objective"
const TABLE_REGION := "region"
const TABLE_DEATH := "death"
const OBJECTIVE_OPS := {4: OP_SET, 5: OP_SET, 6: OP_ADD, 7: "sub"}
const OBJECTIVE_OPERANDS := {4: 1, 5: 0, 6: 1, 7: 1}
const REGION_OPS := {5: OP_SET, 6: OP_ADD}
const REGION_OPERANDS := {5: 0, 6: 1}

var orders: ES2GroupOrders
var rules: ES2Objectives
## Training instructor and base-under-attack lines (created in setup).
var command_radio: ES2CommandRadio
## Region-armed countdowns by timer index; the payload is the list of regions it fires (setup).
## The objectives line, played in turn after the first-message delay (setup).
var _briefing_radio: MissionAnnouncer = null
## Region param -> the SpawnWave that places an arriving group around the player.
var _arrivals := make_arrival_waves()
var _objective_vars := MissionVars.new(NVARS, OBJECTIVE_OPS, {})
var _region_vars := MissionVars.new(NVARS, REGION_OPS, {})
## The debriefing's clip (VSHELL clip index) of the final compile, -1 none (make_result_extra).
var _debrief_clip := -1

## Views onto the collaborators (kept for callers that read them directly).
var objectives: Array:
	get: return rules.objectives
var detected: Dictionary:
	get: return rules.detected
var scan_flag: bool:
	get: return rules.scan_flag
var group_done_paths: Dictionary:
	get: return orders.group_done_paths


func _init() -> void:
	super()
	orders = ES2GroupOrders.new(self)
	targets = MissionTargets.new(self)
	rules = ES2Objectives.new(self)


## The arrival waves of ARRIVAL_UNITS by region param: distance in metres, spread and bearing in radians.
static func make_arrival_waves() -> Dictionary:
	var waves := {}
	for param in ARRIVAL_UNITS:
		var a: Array = ARRIVAL_UNITS[param]
		waves[param] = SpawnWave.make_placed_wave("", "arrival:%d" % param, a[0] * Assets.UNIT, a[1], a[2])
	return waves


## Vehicle id for an ES2 herc record (see ES2UnitCatalog.vehicle_for).
static func vehicle_for(type_name) -> String:
	return ES2UnitCatalog.vehicle_for(type_name)


## Engine weapon ids for an ES2 herc record (see ES2UnitCatalog.loadout_for).
static func loadout_for(vid: String, weapons: Array, ammo: Array) -> Array:
	return ES2UnitCatalog.loadout_for(vid, weapons, ammo)


## The player's Herc as the mission defines it: (vehicle id, loadout).
static func player_vehicle(mission: Dictionary) -> Array:
	return ES2UnitCatalog.player_vehicle(mission)


## Earthsiege 2: WORLD<word0*2+word9> of pack es2 with its heightmap zone.
static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	MissionRuntime.apply_world_to_config(config, mission)
	config.world_pack = PACK
	config.world = WorldBuilder.es2_world_index(mission.get("header", {}).get("raw", []))


## Earthsiege 2 missions define the player's Herc and weapons (player start record).
static func make_mission_herc(mission: Dictionary) -> Dictionary:
	var pv := player_vehicle(mission)
	return {"vehicle": str(pv[0]), "loadout": (pv[1] as Array).duplicate()}


## Wingman slots of a resolved mission: its group 0 Hercs besides the player's (VSHELL: the MSN fixes
## the squad's size; a campaign fills them from the player's garage and crew, battle config "squad").
static func wingman_slots(mission: Dictionary) -> int:
	var groups := _arr(mission.get("groups"))
	if groups.is_empty() or String(groups[0].get("kind", "herc")) != "herc":
		return 0
	var ps = mission.get("player_start")
	var player_id = ps.get("herc", {}).get("id") if ps is Dictionary and ps.get("herc") is Dictionary else null
	var hercs := _arr(mission.get("hercs"))
	var n := 0
	for mi in _arr(groups[0].get("members")):
		if int(mi) >= 0 and int(mi) < hercs.size() and hercs[int(mi)].get("id") != player_id:
			n += 1
	return n


# ------------------------------------------------------------------ setup

func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	battle = p_battle
	m = mission
	mission_vars = vars.duplicate() if vars.size() > 0 else PackedInt32Array()
	if mission_vars.size() < NVARS:
		mission_vars.resize(NVARS)
	var ps: Dictionary = m.get("player_start") if m.get("player_start") is Dictionary else {}
	player_unit = _player_herc_index(ps)
	_load_nav_points(ps)
	_build_nav_markers()
	_init_regions()
	_add_timers()
	_briefing_radio = MissionAnnouncer.new(get_sink(), MissionAnnouncer.Discipline.FIFO)
	rules.load_objectives(_arr(m.get("objectives")))
	command_radio = ES2CommandRadio.new(self)
	_build_structures()


func _player_herc_index(ps: Dictionary) -> int:
	var ph = ps.get("herc")
	var index := -1
	if ph is Dictionary:
		for i in _arr(m.get("hercs")).size():
			if m.hercs[i].get("id") == ph.get("id"):
				index = i
	return index


func _load_nav_points(ps: Dictionary) -> void:
	for wp in _arr(ps.get("waypoints")):
		nav_points.append(on_ground(to_godot(wp)))
	if nav_points.is_empty() and ps.get("position") != null:
		nav_points.append(on_ground(to_godot(ps.position)))


## The mission's objectives line, the first message of the mission (host).
func _say_objectives() -> void:
	var brief: Dictionary = m.get("texts", {}) if m.get("texts") is Dictionary else {}
	var objs: Array = _arr(brief.get("objectives"))
	if not objs.is_empty():
		var line := "Objectives: " + " ".join(objs).replace("\n", " ").strip_edges()
		_briefing_radio.apply_say(MissionMessage.make_message(line, OBJECTIVES_MESSAGE_SECONDS, MissionMessage.CHANNEL_INFO))


## The point dropped onto the terrain (heightmap packs); flat packs keep y.
func on_ground(p: Vector3) -> Vector3:
	var q := p
	if battle and battle.is_inside_tree():
		q.y = MapBuilder.ground_height(battle, p)
	return q


## The point a unit starts at: on the terrain's collision, which on a steep square of the coarse heightmap rises above the
## bilinear height (MapTerrain.make_collision_height), and half a metre up.
func on_unit_ground(p: Vector3) -> Vector3:
	var q := p
	if battle and battle.is_inside_tree():
		q.y = MapTerrain.make_collision_height(battle, p)
	return q + Vector3.UP * UNIT_LIFT


func _build_structures() -> void:
	var bases = Assets.load_json("gameplay/bases.json", "es2")
	var rows: Array = bases.get("records", bases.get("bases", [])) if bases is Dictionary else []
	var slot := _structure_slots()
	var list: Array = _arr(m.get("structures"))
	for i in list.size():
		var s: Dictionary = list[i]
		var team := _slot_team(slot, i)
		var t := int(s.get("type", 0))
		var row = rows[t] if t >= 0 and t < rows.size() else null
		var xf := _es2_structure_transform(s, slot.get(i))
		var name := String(row.get("name", "Structure")) if row is Dictionary else "Structure"
		_add_structure(i, ES2UnitCatalog.structure_shape(row, t, team),
			xf, team, ES2UnitCatalog.row_number(row, "hp", DEFAULT_STRUCTURE_HP), name)
		command_radio.watch_structure(structures.back())


## Like ES1, but a structure without its own heading takes the group's, and it sits on the terrain.
func _es2_structure_transform(s: Dictionary, group_slot) -> Transform3D:
	var pos := Vector3.ZERO
	var yaw := heading_to_yaw(s.get("heading"))
	if s.get("position") != null:
		pos = to_godot(s.position)
	elif group_slot != null:
		var g: Dictionary = group_slot[0]
		pos = to_godot(g.position) if g.get("position") != null else Vector3.ZERO
		if s.get("heading") == null:
			yaw = heading_to_yaw(g.get("heading"))
		pos += _formation_offset("base", int(g.get("formation", 0)), group_slot[1], yaw)
	return Transform3D(Basis(Vector3.UP, yaw), on_ground(pos))


## ES2 formations (ES1 table as fallback); out-of-table Herc slots fan out 30 m apart.
func _formation_offset(kind: String, form: int, k: int, yaw: float) -> Vector3:
	var table = Assets.load_json("gameplay/formations.json", "es2")
	if not table is Dictionary:
		table = Assets.load_json("gameplay/formations.json", "es1")
	var key := _formation_key(kind)
	var formation := Formation.make_from_table_entry(table, key, form, yaw, true)
	if kind == "mech" and table is Dictionary and not (table.get(key, []) as Array).is_empty():
		formation.overflow_fan = Formation.ES2_FAN_SPACING
	return make_slot_offset(formation, kind, k)


# ------------------------------------------------------------------ units (host)

func spawn_units() -> void:
	_spawn_start_groups(0)   # group 0 also holds the player's squadmates
	start_wingman_radio(group_units.get(0, []))
	_say_objectives()


## The briefing's objective lines, done once the mission status is complete (ES2Objectives).
func make_objective_lines() -> Array:
	var texts: Dictionary = m.get("texts", {}) if m.get("texts") is Dictionary else {}
	var complete := rules != null and rules.is_complete()
	var out := []
	for line in _arr(texts.get("objectives")):
		var text := str(line).replace("
", " ").strip_edges()
		if text != "":
			out.append({"text": text, "done": complete})
	if out.is_empty():
		out.append({"text": "Complete the mission objectives", "done": complete})
	return out


func radio_pack() -> String:
	return "es2"


func player_spawn(k: int) -> Transform3D:
	var xf := super.player_spawn(k)
	xf.origin = on_unit_ground(xf.origin)
	return xf


func _spawn_dormant_group(gi: int, arrival: int) -> void:
	_spawn_group(gi, arrival)


func _spawn_group(gi: int, arrival := 0) -> void:
	var g: Dictionary = m.groups[gi]
	var ai := orders.make_ai_order(orders.current_order(gi))
	var path := _group_path(g, ai)
	var spawn := {"gi": gi, "g": g, "path": path, "ai": ai, "arrival": arrival,
		"base": _group_base_position(g, path), "yaw": _group_yaw(g, path), "skill": _es2_skill()}
	_apply_arrival(spawn)
	group_units[gi] = _spawn_members(spawn)
	orders.start_group(gi)


## The current order's path, else the group's own path, on the ground.
func _group_path(g: Dictionary, ai: AIOrder) -> Array[Vector3]:
	var path: Array[Vector3] = []
	for p in ai.path:
		path.append(p)
	if path.is_empty():
		for p in _arr(g.get("path_points")):
			path.append(on_ground(to_godot(p)))
	return path


## Region param 2..5: the group arrives at a distance around the player, facing them (DBSIM 0x4236c4).
func _apply_arrival(spawn: Dictionary) -> void:
	var me := _living_player()
	if not _arrivals.has(spawn.arrival) or me == null:
		return
	var place: Dictionary = _arrivals[spawn.arrival].placement
	var ang: float = me.global_rotation.y + place.bearing + randf_range(-place.spread, place.spread)
	spawn.base = me.global_position + Basis(Vector3.UP, ang) * Vector3(0, 0, -place.distance)
	spawn.yaw = yaw_towards(spawn.base, me.global_position)


## Pilot skill from the header's difficulty word (raw word 7).
func _es2_skill() -> float:
	var raw: Array = _arr(m.get("header", {}).get("raw"))
	return clampf(0.35 + 0.1 * float(raw[7] if raw.size() > 7 else 2), 0.2, 0.9)


func _spawn_members(spawn: Dictionary) -> Array:
	var gi: int = spawn.gi
	var leader: Herc = battle.player if gi == 0 and battle.player else null   # squadmates fly on the player's wing
	var units := []
	var k := 1 if gi == 0 else 0     # slot 0 of the player squad is the player
	var flyer_group := _kind_code(spawn.g) == KIND_FLYER
	for mi in _arr(spawn.g.get("members")):
		if gi == 0 and int(mi) == player_unit:
			continue      # the player (roster) takes this slot
		if flyer_group:
			if int(mi) < _arr(m.get("flyers")).size():
				var fl := _spawn_flyer(spawn, int(mi), k)
				if fl:
					units.append(fl)
				k += 1
			continue
		var unit := _spawn_herc(spawn, int(mi), k, leader, _make_wingman(gi, k))
		if unit == null:
			continue
		if leader == null and not _is_flying_herc(m.hercs[int(mi)]):
			leader = unit     # flying hercs never lead the walkers
		units.append(unit)
		k += 1
	return units


static func _is_flying_herc(h: Dictionary) -> bool:
	var tname := String(h.get("type_name", DEFAULT_HERC_TYPE))
	return tname in FLYING_HERCS or bool(Packs.vehicle(vehicle_for(tname)).get("flyer", false))


func _spawn_flyer(spawn: Dictionary, mi: int, k: int) -> Herc:
	var g: Dictionary = spawn.g
	var yaw: float = spawn.yaw
	var fpos := on_ground(spawn.base + _formation_offset("flyer", int(g.get("formation", 0)), k, yaw))
	var fl: Herc = battle.spawn_ai(vehicle_for("SKIMMER"), int(g.get("team", 1)), Transform3D(Basis(Vector3.UP, yaw), fpos),
		["es2:LAS200"], "Skimmer", {"skill": spawn.skill, "group": spawn.gi, "path": spawn.path, "flyer": true})
	if fl:
		fl.set_meta("flyer_index", mi)
		unit_index["flyer:%d" % mi] = fl
	return fl


## The campaign's wingman for player-squad slot `k` (battle config "squad": a garage Herc and its
## pilot), {} when the slot keeps the mission's own Herc.
func _make_wingman(gi: int, k: int) -> Dictionary:
	var squad: Array = battle.config.get("squad", []) if gi == 0 else []
	return squad[k - 1] if k >= 1 and k - 1 < squad.size() else {}


## Spawns herc record `mi`; a `wingman` ({vehicle, loadout, name, skill, garage}) replaces its Herc,
## weapons and pilot.
func _spawn_herc(spawn: Dictionary, mi: int, k: int, leader: Herc, wingman := {}) -> Herc:
	var hercs: Array = _arr(m.get("hercs"))
	var h: Dictionary = hercs[mi] if mi < hercs.size() else {}
	if h.is_empty():
		return null
	var g: Dictionary = spawn.g
	var yaw: float = spawn.yaw
	var tname := String(h.get("type_name", DEFAULT_HERC_TYPE))
	var vid := str(wingman.get("vehicle", vehicle_for(tname)))
	var pos: Vector3 = to_godot(h.position) if h.get("position") != null and spawn.arrival < 2 \
		else spawn.base + _formation_offset("mech", int(g.get("formation", 0)), k, yaw)
	var alerted := int(h.get("flag0", 0)) != 0
	var flying := _is_flying_herc(h)
	var info := {"skill": clampf(spawn.skill + (0.05 if alerted else 0.0), 0.2, 0.95), "group": spawn.gi,
		"order": ES2GroupOrders.make_es1_code(spawn.ai), "path": spawn.path, "leader": leader.net_id if leader else 0,
		"formation_slot": k, "health": int(h.get("health", 100))}
	if flying:
		info["flyer"] = true
	var loadout: Array = loadout_for(vid, _arr(h.get("weapons")), _arr(h.get("ammo")))
	if not wingman.is_empty():
		loadout = wingman.loadout
		info.skill = float(wingman.skill)
		info.health = 100        # the garage Herc's own condition applies (BattleSpawner)
		info["garage"] = wingman.garage
	var unit: Herc = battle.spawn_ai(vid, int(g.get("team", 1)), Transform3D(Basis(Vector3.UP, yaw), on_unit_ground(pos)),
		loadout, str(wingman.get("name", "")), info)
	if unit == null:
		return null
	unit.set_meta("herc_index", mi)
	unit_index["herc:%d" % mi] = unit
	_set_pilot_start(unit, spawn.ai, alerted)
	return unit


static func _set_pilot_start(unit: Herc, ai: AIOrder, alerted: bool) -> void:
	for p in unit.get_children():
		if p is AIPilot:
			p.loop_path = ai.loop
			if alerted and p.order == AIPilot.Order.SLEEP:
				p.order = AIPilot.Order.SEARCH     # block word 0: starts alerted


# ------------------------------------------------------------------ triggers & rules (host)

func _physics_process(delta: float) -> void:
	if _over or not multiplayer.is_server():
		return
	kit.clock.apply_advance(delta)
	_apply_fired_timers(kit.timers.apply_tick(delta))
	var dt := kit.clock.make_step(delta, RULES_INTERVAL)
	if dt <= 0.0:
		return
	_briefing_radio.apply_tick(dt)
	rules.update_detection()
	_check_regions()
	_update_nav()
	orders.update()
	rules.update_scan(dt)
	rules.check_end(dt)


## One timer per mission timer record, armed at once unless a region arms it; it fires its regions once. A record with
## no delay never fires.
func _add_timers() -> void:
	var defs: Array = _arr(m.get("timers"))
	for i in defs.size():
		var delay := float(defs[i].get("delay", 0))
		var timer := MissionTimer.make_timer(delay if delay > 0.0 else INF, MissionTimer.Mode.ONE_SHOT, _arr(defs[i].get("fire")))
		timer.armed = defs[i].get("trigger") == null
		kit.timers.apply_add(i, timer)


func _apply_fired_timers(fire_lists: Array) -> void:
	for fire_list in fire_lists:
		for ri in fire_list:
			fire_region(int(ri))


func get_timer_count() -> int:
	return _arr(m.get("timers")).size()


## True while timer `i` counts or has run out (it was armed); false while it waits for its region.
func is_timer_armed(i: int) -> bool:
	var timer := kit.timers.get_timer(i)
	return timer == null or timer.armed


func fire_region(ri: int) -> void:
	if ri < 0 or ri >= regions.size():
		return
	var r: Dictionary = regions[ri]
	if r.fired:
		return
	r.fired = true
	var d: Dictionary = r.def
	for a in _arr(d.get("on_fire")):
		_var_op(int(a[0]), int(a[1]), TABLE_REGION)
	# region text ids (w34..w38) are discarded by the sim (DBSIM 0x424a8e): only the message word speaks
	command_radio.announce_region(d)
	_wake_groups(d, int(d.get("param", 0)))
	var defs: Array = _arr(m.get("timers"))
	for i in defs.size():
		if defs[i].get("trigger") != null and int(defs[i].trigger) == ri and kit.timers.get_timer(i) != null:
			kit.timers.get_timer(i).apply_arm()


## What a region reacts to: types 0..6 classes of units (6 = structures), 7+ its own target.
func _region_candidates(d: Dictionary) -> Array:
	var ty := int(d.get("type", 0))
	if ty >= 7:
		return target_nodes(d.target) if d.get("target") is Dictionary else []
	var who := []
	for v in active_vehicles():
		if _region_type_counts(ty, v):
			who.append(v)
	if ty == 6:
		for s in structures:
			if s.alive:
				who.append(s)
	return who


func _region_type_counts(ty: int, v: Node) -> bool:
	var gi := int(v.get_meta("group", 0 if v.team == 0 and not v.has_meta("ai") else -1))
	var gk := _kind_code(m.groups[gi]) if gi >= 0 and gi < _arr(m.get("groups")).size() else KIND_HERC
	match ty:
		0: return _is_human_player(v)
		1: return gi == 0
		2: return v.team == 0
		3: return v.team == 1
		4: return gk == KIND_HERC and not (v is Flyer)
		5: return v is Flyer
	return false


## Mission variable update by one of three op tables (docs/formats/es2.md 10.5):
## objective 4 =1, 5 =0, 6 +=1, 7 -=1; region 5 =0, 6 +=1; unit/group death 1 =0, 2 +=1, 13..16 =1..4.
func _var_op(v: int, op, table := TABLE_DEATH) -> void:
	match table:
		TABLE_OBJECTIVE:
			_apply_table_op(_objective_vars, OBJECTIVE_OPERANDS, v, int(op))
		TABLE_REGION:
			_apply_table_op(_region_vars, REGION_OPERANDS, v, int(op))
		_:
			super._var_op(v, op)


func _apply_table_op(vars: MissionVars, operands: Dictionary, v: int, op: int) -> void:
	vars.values = mission_vars
	if vars.apply_op(op, v, int(operands.get(op, 0))):
		mission_vars = vars.values


func _run_actions(actions, table: String) -> void:
	for a in _arr(actions):
		_var_op(int(a[0]), int(a[1]), table)


# ------------------------------------------------------------------ deaths and end

## Mission status for the HUD / a manual "end mission": 4 not complete (at risk), 5 not complete,
## 6 failed, 9 complete, 10 complete but still at risk.
func status() -> int:
	return rules.status


func on_unit_destroyed(h: Herc) -> void:
	rules.mark_detected(h)
	var rec = _unit_record(h)
	if rec is Dictionary:
		_run_actions(rec.get("on_death"), TABLE_DEATH)
		if int(rec.get("death_region", -1)) >= 0:
			fire_region(int(rec.death_region))
	var gi := int(h.get_meta("group", -1))
	if gi >= 0 and _group_wiped_out(gi):
		_run_actions(m.groups[gi].get("on_destroyed"), TABLE_DEATH)


func _on_structure_destroyed(st: Structure, _killer: Node, i: int) -> void:
	rules.mark_detected(st)     # destroyed means found (detection flag stays set)
	var s: Dictionary = m.structures[i]
	_run_actions(s.get("on_death"), TABLE_DEATH)
	if int(s.get("death_region", -1)) >= 0:
		fire_region(int(s.death_region))
	if multiplayer.is_server():
		battle.fx("structure_down", [i], true)


## End: success = objective status 9 (results.dat). The debriefing is the mission's debrief record
## re-evaluated with the final mission variables, as the shell does after the sim.
## Earthsiege 2: mission var 0 is the results.dat success flag (VSHELL 0x40eae7).
func make_end_var(success: bool, _code: int) -> int:
	return 1 if success else 0


## Earthsiege 2: the debriefing the mission compiles to with the final mission variables.
func make_debriefing_text(_code: int, text: String) -> String:
	return text + _final_debriefing()


## Earthsiege 2: the debriefing's clip, chosen with the final mission variables like its text.
func make_result_extra() -> Dictionary:
	return {"debrief_clip": _debrief_clip}


func _final_debriefing() -> String:
	var name := String(m.get("name", ""))
	if name == "":
		return ""
	var camp = m.get("evaluation", {}).get("campaign")
	var again := MissionCompilerES2.load_mission(name, mission_vars, -1, int(camp) if camp != null else -2)
	_debrief_clip = int(again.get("texts", {}).get("debrief_clip", -1))
	var deb: Array = _arr(again.get("texts", {}).get("debriefings"))
	if not deb.is_empty() and String(deb[0]).strip_edges() != "":
		return "\n" + String(deb[0]).strip_edges()
	return ""
