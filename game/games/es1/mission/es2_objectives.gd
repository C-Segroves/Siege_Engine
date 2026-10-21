class_name ES2Objectives
extends RefCounted
## Earthsiege 2 mission rules: the detection flags (alert regions), the scan test, the objective
## tests (DBSIM 0x413280; docs/formats/es2.md 10.3) and the mission status with its automatic end.

## Detection and "safe" (DBSIM 0x4137b4, armed enemies only here): the ranges are EsRanges'.
## Scan missions (header word 3): face the target within SCAN_RANGE (+ structure slack) for SCAN_TIME.
const SCAN_MODES := [3, 7]
const SCAN_RANGE := 60.0
const SCAN_RANGE_STRUCTURE_EXTRA := 20.0
const SCAN_CONE_DEGREES := 45.0
const SCAN_TIME := 4.0
## The scan's own lines: a progress line every 4th rules tick, then the completion.
const SCAN_PROGRESS_TICKS := 4
const SCAN_PROGRESS_TEXT := "Scanning target... %d%%"
const SCAN_PROGRESS_SECONDS := 1.0
const SCAN_DONE_TEXT := "Scan complete."
const SCAN_DONE_SECONDS := 4.0
## The mission's header word 3 names the mission type.
const HEADER_MODE_WORD := 3
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
## The end lines and codes.
const CODE_KILLED := 2
const TEXT_KILLED := "You have been killed."
const TEXT_COMPLETE := "Mission objectives complete."
const TEXT_FAILED := "You have failed your mission."
const TEXT_LEFT_AREA := "You have left the mission area."
const STATUS_MESSAGE_SECONDS := 5.0

var rt: MissionRuntimeES2
var objectives := []              # [{def, done}], in the order of the goals of the set
var detected := {}                # node instance id -> true (an enemy came within 195 m / targeted it)
var scan_flag: bool:
	get: return _scan != null and _scan.is_done()
var status := STATUS_IN_PROGRESS
var world: ES2MissionWorld
var _goals := ObjectiveSet.new()
var _scan: ScanObjective = null
var _killed_rule := PlayerKilledRule.new(CODE_KILLED, TEXT_KILLED)
var _left_rule := LeftAreaRule.new(0, TEXT_LEFT_AREA, END_GRACE)
var _ender: MissionEnder
## The end-forcing status held now, and for how long (the grace counts from the change of status).
var _held_status := -1
var _held_seconds := 0.0
var _objectives_complete := false


func _init(runtime: MissionRuntimeES2) -> void:
	rt = runtime
	_left_rule.code_source = get_status


## Builds the goals of the set (a required one completes the mission, an optional one hit fails it), the scan of the
## scan missions and the way out (needs the battle: its sink).
func load_objectives(defs: Array) -> void:
	world = ES2MissionWorld.new(rt)
	_ender = MissionEnder.new(rt.end_mission, world.sink.is_voice_playing)
	for o in defs:
		var entry := {"def": o, "done": false}
		var goal := ConditionObjective.new(str(objectives.size()), _make_goal_text(o), _is_goal_hit.bind(entry))
		goal.required = bool(o.get("required", true))
		objectives.append(entry)
		_goals.apply_add(goal)
	if get_mission_mode() in SCAN_MODES:
		_scan = _make_scan()


func get_status() -> int:
	return status


func get_mission_mode() -> int:
	var raw: Array = MissionRuntime._arr(rt.m.get("header", {}).get("raw"))
	return int(raw[HEADER_MODE_WORD]) if raw.size() > HEADER_MODE_WORD else 0


static func _make_goal_text(o: Dictionary) -> String:
	return String(o.get("text", "")) if o.get("text") != null else ""


## The scan: face the target within range for SCAN_TIME (one stage, no text of its own), with its progress lines.
func _make_scan() -> ScanObjective:
	var scan := ScanObjective.new("scan", "", "", SCAN_RANGE, [{"seconds": SCAN_TIME, "text": ""}])
	scan.cone_degrees = SCAN_CONE_DEGREES
	scan.progress_format = SCAN_PROGRESS_TEXT
	scan.progress_every = SCAN_PROGRESS_TICKS
	scan.progress_seconds = SCAN_PROGRESS_SECONDS
	scan.complete_text = SCAN_DONE_TEXT
	scan.complete_seconds = SCAN_DONE_SECONDS
	return scan


# ------------------------------------------------------------------ detection and scan

## "Safe" (DBSIM 0x4137b4): no living, armed, active enemy within 312 m (390 m if it targets u).
func is_safe(u: Node3D) -> bool:
	if u == null:
		return true
	for v in rt.active_vehicles():
		if v.team != u.team and not v.weapons.is_empty() and EsRanges.is_in_safe_range(v, u):
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
		if detected.has(key) or not MissionTargets.is_noticed(u, vs, EsRanges.DETECT_RANGE_UNITS):
			continue
		detected[key] = true
		var ar := rt.alert_region_of(u)
		if ar >= 0:
			rt.fire_region(ar)


func mark_detected(n: Node) -> void:
	detected[n.get_instance_id()] = true


## Scan missions (header word 3 = 3 / 7): face the player squad's order target closely for 4 s.
func update_scan(dt: float) -> void:
	if _scan == null or _scan.is_done() or rt._living_player() == null:
		return
	_scan.apply_tick(world, dt)


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


## True when a scan target other than `me` lies within `reach` (a structure's slack added) of `me` and inside the cone.
## The cone is +-cone (es2.md 10.2 mode 3/7: facing +-45 degrees), so the angle is absolute.
func is_facing_scan_target(me: Node3D, reach: float, cone: float) -> bool:
	var near := false
	for t in _scan_targets():
		if is_instance_valid(t) and t.alive and t != me:
			var to: Vector3 = t.global_position - me.global_position
			var fwd: Vector3 = -me.aim_basis().z
			var range := reach + SCAN_RANGE_STRUCTURE_EXTRA * float(t is Structure)
			if to.length() < range and absf(Vector2(fwd.x, fwd.z).angle_to(Vector2(to.x, to.z))) < cone:
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


## The condition of a goal: its test, running the objective's mission variable changes once, when first hit.
func _is_goal_hit(entry: Dictionary) -> bool:
	var o: Dictionary = entry.def
	var hit := goal_met(o)
	if hit and not entry.done:
		entry.done = true
		for a in MissionRuntime._arr(o.get("actions")):
			rt._var_op(int(a[0]), int(a[1]), MissionRuntimeES2.TABLE_OBJECTIVE)
	return hit


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


## Seconds the status "left the mission area" (7 / 8) has held (0 for any other status).
func get_area_seconds() -> float:
	return _held_seconds if status in [STATUS_OUTSIDE, STATUS_FAR_OUTSIDE] else 0.0


## Evaluates the objectives (running their actions once), updates the status and hands the end to the MissionEnder: at once
## when the player is dead, else after the status that ends the mission has held the grace period. `dt` = time since the last check.
func check_end(dt: float) -> void:
	var killed := _killed_rule.make_verdict(world, dt)
	if killed != null:
		_apply_verdict(killed, dt)
		return
	var outcome := _evaluate_objectives()
	_objectives_complete = outcome.complete and not outcome.failed
	var me := rt._living_player()
	status = _status_for(outcome.failed, outcome.complete, is_safe(me))
	var area := make_area_status(rt.battle.bounds.make_outside_distance(me.global_position) if rt.battle.get("bounds") else 0.0)
	if area != 0:
		status = area
	_hold_status(dt)
	_apply_verdict(_make_end_verdict(String(outcome.fail_text), dt), dt)


func _apply_verdict(verdict: MissionVerdict, dt: float) -> void:
	_ender.apply_verdict(verdict)
	_ender.apply_tick(dt)


## {failed, complete, fail_text}: a hit optional (failure) condition fails, every required one completes.
func _evaluate_objectives() -> Dictionary:
	_goals.apply_tick(world, 0.0)
	var out := {"failed": false, "complete": true, "fail_text": ""}
	for g in _goals.get_objectives():
		if g.required:
			if not g.is_done():
				out.complete = false
		elif g.is_done():
			out.failed = true
			out.fail_text = g.text
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


## Counts how long the status has held while it is one that ends the mission (a change of status starts the grace over
## and announces the end that is coming).
func _hold_status(dt: float) -> void:
	if status not in AUTO_END_STATUSES:
		_held_status = -1
		_held_seconds = 0.0
		return
	if _held_status != status:
		_held_status = status
		_held_seconds = 0.0
		var line := TEXT_COMPLETE if status == STATUS_COMPLETE else _make_failure_line()
		world.sink.apply_message(MissionMessage.make_message(line, STATUS_MESSAGE_SECONDS, MissionMessage.CHANNEL_INFO))
	_held_seconds += dt


## The ruling once the status has held END_GRACE: the left area (the rule), the won mission, or the failed one with the
## failing condition's text.
func _make_end_verdict(fail_text: String, dt: float) -> MissionVerdict:
	var left := _left_rule.make_verdict(world, dt)
	if left != null:
		return left
	if _held_seconds < END_GRACE:
		return null
	if status == STATUS_COMPLETE:
		return MissionVerdict.make_win(STATUS_COMPLETE, TEXT_COMPLETE)
	if status == STATUS_FAILED:
		var why := "\n" + fail_text.strip_edges() if fail_text.strip_edges() != "" else ""
		return MissionVerdict.make_loss(status, _make_failure_line() + why)
	return null


func _make_failure_line() -> String:
	return TEXT_LEFT_AREA if status in [STATUS_OUTSIDE, STATUS_FAR_OUTSIDE] else TEXT_FAILED
