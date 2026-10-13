class_name ES2Objectives
extends RefCounted
## Earthsiege 2 mission rules: the detection flags (alert regions), the scan test, the objective
## tests (DBSIM 0x413280; docs/formats/es2.md 10.3) and the mission status with its automatic end.

## Detection: an enemy within 50000 original units (195 m) or targeting the unit (DBSIM +0xc flag).
const DETECT_RANGE_UNITS := 50000.0
## "Safe" (DBSIM 0x4137b4): no armed enemy within 80000 units (312 m), 100000 (390 m) if it targets u.
const SAFE_RANGE_UNITS := 80000.0
const SAFE_RANGE_TARGETING_UNITS := 100000.0
## Scan missions (header word 3): face the target within SCAN_RANGE (+ structure slack) for SCAN_TIME.
const SCAN_MODES := [3, 7]
const SCAN_RANGE := 60.0
const SCAN_RANGE_STRUCTURE_EXTRA := 20.0
const SCAN_CONE := PI / 4.0
const SCAN_TIME := 4.0
## Objective types that name the scan target.
const SCAN_TARGET_OBJECTIVES := [3, 4, 9, 10]
## Passive goals (protect 2, disarm 7, stealth 8, no-scan 9/10), see threat_over().
const PASSIVE_GOALS := [2, 7, 8, 9, 10]
## Mission status (results.dat / HUD): 4 not complete (at risk), 5 not complete, 6 failed,
## 9 complete, 10 complete but still at risk.
const STATUS_AT_RISK := 4
const STATUS_IN_PROGRESS := 5
const STATUS_FAILED := 6
const STATUS_COMPLETE := 9
const STATUS_COMPLETE_AT_RISK := 10
## Player outside the mission rectangle (7), more than OUTSIDE_FAR_UNITS outside it (8) (DBSIM 0x4135e8, es2.md 10.4).
const STATUS_OUTSIDE := 7
const STATUS_FAR_OUTSIDE := 8
const OUTSIDE_FAR_UNITS := 110000.0
## Statuses that end the mission after the grace period (table 0x49935c; 2 and 3 end at once / are not modelled).
const AUTO_END_STATUSES := [STATUS_FAILED, STATUS_OUTSIDE, STATUS_FAR_OUTSIDE, STATUS_COMPLETE]
## Statuses 6 and 9 end the mission after this grace period (DBSIM 0x4131ac).
const END_GRACE := 4.9

var rt: MissionRuntimeES2
var objectives := []              # [{def, done}]
var detected := {}                # node instance id -> true (an enemy came within 195 m / targeted it)
var scan_flag := false
var status := STATUS_IN_PROGRESS
var _scan_t := 0.0
var _end_t := -1.0
var _end_status := -1
var _objectives_complete := false


func _init(runtime: MissionRuntimeES2) -> void:
	rt = runtime


func load_objectives(defs: Array) -> void:
	for o in defs:
		objectives.append({"def": o, "done": false})


# ------------------------------------------------------------------ detection and scan

## "Safe" (DBSIM 0x4137b4): no living, armed, active enemy within 312 m (390 m if it targets u).
func is_safe(u: Node3D) -> bool:
	if u == null:
		return true
	for v in rt.active_vehicles():
		if v.team == u.team or v.weapons.is_empty():
			continue
		var r := SAFE_RANGE_TARGETING_UNITS if v.target == u else SAFE_RANGE_UNITS
		if v.global_position.distance_to(u.global_position) < r * Assets.UNIT:
			return false
	return true


## Detection flag (+0xc) and alert regions: an enemy within 195 m (or a hit, see AIPilot).
func update_detection() -> void:
	var vs := rt.active_vehicles()
	var units := vs.duplicate()
	for s in rt.structures:
		if s.alive:
			units.append(s)
	for u in units:
		var key: int = u.get_instance_id()
		if detected.has(key) or not MissionTargets.is_noticed(u, vs, DETECT_RANGE_UNITS):
			continue
		detected[key] = true
		var ar := rt.alert_region_of(u)
		if ar >= 0:
			rt.fire_region(ar)


func mark_detected(n: Node) -> void:
	detected[n.get_instance_id()] = true


## Scan missions (header word 3 = 3 / 7): face the player squad's order target closely for 4 s.
func update_scan(dt: float) -> void:
	var raw: Array = MissionRuntime._arr(rt.m.get("header", {}).get("raw"))
	var mode := int(raw[3]) if raw.size() > 3 else 0
	if scan_flag or not (mode in SCAN_MODES):
		return
	var me := rt._living_player()
	if me == null:
		return
	var near := _facing_scan_target(me)
	_scan_t = _scan_t + dt if near else 0.0
	if near and int(_scan_t / dt) % 4 == 1:
		rt.battle.fx("message", ["Scanning target... %d%%" % mini(100, int(_scan_t * 25.0)), 1.0], true)
	if _scan_t >= SCAN_TIME:
		scan_flag = true
		rt.battle.fx("message", ["Scan complete.", 4.0], true)


func _scan_targets() -> Array:
	var o = rt.orders.current_order(0)
	if o is Dictionary and o.get("target") is Dictionary:
		var tgts := rt.target_nodes(o.target)
		if not tgts.is_empty():
			return tgts
	var out := []
	for ob in objectives:
		if int(ob.def.get("type", 0)) in SCAN_TARGET_OBJECTIVES:
			out += rt.target_nodes(ob.def.get("target"))
	return out


func _facing_scan_target(me: Node3D) -> bool:
	var near := false
	for t in _scan_targets():
		if is_instance_valid(t) and t.alive and t != me:
			var to: Vector3 = t.global_position - me.global_position
			var fwd: Vector3 = -me.aim_basis().z
			var reach := SCAN_RANGE + SCAN_RANGE_STRUCTURE_EXTRA * float(t is Structure)
			if to.length() < reach and Vector2(fwd.x, fwd.z).angle_to(Vector2(to.x, to.z)) < SCAN_CONE:
				near = true
	return near


func _detected_any(t) -> bool:
	for n in rt.target_nodes(t):
		if is_instance_valid(n) and detected.has(n.get_instance_id()):
			return true
	return false


func _harmless_all(t) -> bool:
	var nodes := rt.target_nodes(t)
	if nodes.is_empty():
		return false
	for n in nodes:
		if not is_instance_valid(n) or not n.alive or n is Structure:
			continue
		if n is Herc and not n.weapons.is_empty():
			return false
	return true


# ------------------------------------------------------------------ objective tests

## Remake rule for "passive" goals (protect 2, disarm 7, stealth 8, no-scan 9/10): the original evaluates them at
## face value, which is already true before the threat arrives (dormant attackers). Here they only hold
## once no hostile group is dormant and no hostile Herc/flyer is alive any more.
func threat_over() -> bool:
	for gi in rt.dormant_groups:
		if int(rt.m.groups[gi].get("team", 1)) != 0:
			return false
	for v in rt.active_vehicles():
		if v.team != 0:
			return false
	return true


## Objective test (DBSIM 0x413280; docs/formats/es2.md 10.3).
func goal_met(o: Dictionary) -> bool:
	if o.get("required", true) and int(o.get("type", 0)) in PASSIVE_GOALS and not threat_over():
		return false
	return _goal_at_face_value(o)


func _goal_at_face_value(o: Dictionary) -> bool:
	var t = o.get("target")
	match int(o.get("type", 0)):
		0:
			return _path_goal_met(t, o)
		1:
			return rt.target_state(t) == "dead"
		2:
			return _protect_goal_met(t)
		3, 4:
			return scan_flag
		6:
			return _detected_any(t)
		7:
			return _harmless_all(t)
		8:
			return not rt.target_nodes(t).is_empty() and not _detected_any(t)
		9, 10:
			return not scan_flag
	return false


func _path_goal_met(t, o: Dictionary) -> bool:
	var gi := rt.group_of(t)
	if gi == 0 or gi < 0:
		return rt.nav_index >= rt.nav_points.size()
	return rt.orders.group_done_paths.get(gi, []).has(int(o.get("path", -1)))


func _protect_goal_met(t) -> bool:
	if t is Dictionary and t.get("kind") == "group" and rt.target_state(t) != "alive":
		return false
	for n in rt.target_nodes(t):
		if is_instance_valid(n) and n.alive and not is_safe(n):
			return false
	return not rt.target_nodes(t).is_empty()


# ------------------------------------------------------------------ mission status and end

## True while every required objective holds and no failure condition does (the status may still be "at risk").
func is_complete() -> bool:
	return _objectives_complete


## Evaluates the objectives (running their actions once), updates the status and ends the
## mission after the grace period. `dt` = time since the last check.
func check_end(dt: float) -> void:
	var me := rt._living_player()
	if me == null:
		rt.end_mission(false, 2, "You have been killed.")
		return
	var outcome := _evaluate_objectives()
	_objectives_complete = outcome.complete and not outcome.failed
	status = _status_for(outcome.failed, outcome.complete, is_safe(me))
	var area := make_area_status(rt.battle.bounds.make_outside_distance(me.global_position) if rt.battle.get("bounds") else 0.0)
	if area != 0:
		status = area
	if status in AUTO_END_STATUSES:
		_count_down_end(dt, String(outcome.fail_text))
	else:
		_end_status = -1


## {failed, complete, fail_text}: a hit optional (failure) condition fails, every required one completes.
func _evaluate_objectives() -> Dictionary:
	var out := {"failed": false, "complete": true, "fail_text": ""}
	for ob in objectives:
		var o: Dictionary = ob.def
		var hit := goal_met(o)
		if hit and not ob.done:
			ob.done = true
			for a in MissionRuntime._arr(o.get("actions")):
				rt._var_op(int(a[0]), int(a[1]), "objective")
		if o.get("required", true):
			if not hit:
				out.complete = false
		elif hit:
			out.failed = true
			out.fail_text = String(o.get("text", "")) if o.get("text") != null else ""
	return out


## The objective status (DBSIM 0x4134e2..0x4135df, es2.md 10.3): failed 6 / complete 9 once the player is safe,
## 10 ("still at risk") while enemies are near; otherwise 5 / 4. Only 6 and 9 end the mission, so a failed
## mission waits, like a won one, until the player is safe.
static func _status_for(failed: bool, complete: bool, safe: bool) -> int:
	if failed:
		return STATUS_FAILED if safe else STATUS_COMPLETE_AT_RISK
	if complete:
		return STATUS_COMPLETE if safe else STATUS_COMPLETE_AT_RISK
	return STATUS_IN_PROGRESS if safe else STATUS_AT_RISK


## The status the player's position forces (es2.md 10.4): 8 more than 110000 units outside the mission rectangle,
## 7 outside it, else 0. `outside_m` = metres outside (BattleBounds.make_outside_distance).
static func make_area_status(outside_m: float) -> int:
	if outside_m <= 0.0:
		return 0
	return STATUS_FAR_OUTSIDE if outside_m > OUTSIDE_FAR_UNITS * Assets.UNIT else STATUS_OUTSIDE


func _count_down_end(dt: float, fail_text: String) -> void:
	var won := status == STATUS_COMPLETE
	if _end_status != status:
		_end_status = status
		_end_t = END_GRACE
		rt.battle.fx("message", ["Mission objectives complete." if won else _make_failure_line(), 5.0], true)
	_end_t -= dt
	if _end_t > 0.0:
		return
	if won:
		rt.end_mission(true, STATUS_COMPLETE, "Mission objectives complete.")
	else:
		var why := "\n" + fail_text.strip_edges() if fail_text.strip_edges() != "" and status == STATUS_FAILED else ""
		rt.end_mission(false, status, _make_failure_line() + why)


func _make_failure_line() -> String:
	return "You have left the mission area." if status in [STATUS_OUTSIDE, STATUS_FAR_OUTSIDE] else "You have failed your mission."
