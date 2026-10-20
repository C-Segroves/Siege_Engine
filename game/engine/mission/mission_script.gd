class_name MissionScript
extends RefCounted
## A data state machine for scripted missions and trainings, generalised from the Aerial Assault script machine: states with
## enter actions, rules (a condition and actions), timers, shared rule groups and event handlers. Everything the machine
## senses or does beyond its built-ins goes through the `host` (MissionScriptHost).
##
## Built-in conditions: time, timer, flag, counter, not, and, or, with comparisons ">" ">=" "<" "<=" "==" "!=".
## Built-in actions: state, flag, unflag, reset, min_time, add, success, fail, prompt, audio, objective, objective_by,
## info, error. Games register the rest (spawn, order, near ...) on the host.
## A rule fires every tick its condition holds (one-shot rules guard themselves with a flag); fail / success / state end
## the tick. Flags, timers and counters belong to a state and are cleared when the state changes.

var host: MissionScriptHost
var program: Dictionary = {}
var state := 0
var state_time := 0.0
var flags := {}
var timers := {}
var counters := {}              # named counters (the training lessons count their switches)
var finished := false
var _entered := false
var _stop := false
var _edges := {}                # rise name -> tag -> {now, rise, fall}: the sensed states of the last tick


func _init(p_host: MissionScriptHost, p_program: Dictionary) -> void:
	host = p_host
	program = p_program
	state = int(p_program.get("initial", 1))


## The record of the current state.
func current() -> Dictionary:
	return (program.get("states", {}) as Dictionary).get(str(state), {})


## The line of the objectives panel of the current state.
func state_text() -> String:
	return str(current().get("text", ""))


func state_name() -> String:
	return str(current().get("name", ""))


## One rules tick of `dt` seconds of simulation time.
func step(dt: float) -> void:
	if finished:
		return
	if not _entered:
		_enter()
		if finished:
			return
	state_time += dt
	_apply_timers(dt)
	_update_edges()
	_stop = false
	for r in _rules():
		if _stop or finished:
			break
		if _cond(r.when):
			_do(r["do"])


## An event of the game ("turret_destroyed"): runs the actions the script lists for it ("events").
func notify(event: String) -> void:
	if finished:
		return
	var actions: Array = (program.get("events", {}) as Dictionary).get(event, [])
	_stop = false
	for a in actions:
		_act(a)
		if finished:
			return


## Ends the script as failed (the player died: the script's own "death" prompt).
func fail(voice: int) -> void:
	if not finished:
		finished = true
		host.apply_end(false, voice)


func _enter() -> void:
	_entered = true
	state_time = 0.0
	flags.clear()
	timers.clear()
	counters.clear()
	_edges.clear()
	_stop = false
	for t in _timers():
		timers[str(t.name)] = 0.0
	_update_edges()
	for e in current().get("enter", []):
		_act(e)
		if finished:
			return


func _apply_timers(dt: float) -> void:
	for t in _timers():
		var name := str(t.name)
		if _cond(t.get("while", ["not", ["flag", ""]])):
			timers[name] = float(timers.get(name, 0.0)) + dt
		else:
			timers[name] = 0.0


func _timers() -> Array:
	var out: Array = (current().get("timers", []) as Array).duplicate()
	for g in current().get("use", []):
		out.append_array(_group(g).get("timers", []))
	return out


## The rules in the order they run: the mission's, those of the shared groups the state uses, the state's own.
func _rules() -> Array:
	var out: Array = (program.get("always", []) as Array).duplicate()
	for g in current().get("use", []):
		out.append_array(_group(g).get("rules", []))
	out.append_array(current().get("rules", []))
	return out


func _group(name: Variant) -> Dictionary:
	return (program.get("shared", {}) as Dictionary).get(str(name), {})


func _set_state(n: int) -> void:
	state = n
	_entered = false
	_enter()
	_stop = true


func _do(actions: Array) -> void:
	for a in actions:
		_act(a)
		if _stop or finished:
			return


func _act(a: Array) -> void:
	match str(a[0]):
		"prompt":
			host.apply_prompt(int(a[1]))
		"fail", "success":
			finished = true
			_stop = true
			host.apply_end(str(a[0]) == "success", int(a[1]))
		"state":
			_set_state(int(a[1]))
		"flag":
			flags[str(a[1])] = true
		"unflag":
			flags.erase(str(a[1]))
		"reset":
			if str(a[1]) == "time":
				state_time = 0.0
			else:
				timers[str(a[1])] = 0.0
		"min_time":
			state_time = maxf(state_time, float(a[1]))
		"audio":
			host.apply_audio(int(a[1]))
		"objective":
			host.apply_objective(int(a[1]))
		"objective_by":                      # the objective text picked by a counter: [counter name, [text indexes]]
			var list: Array = a[2]
			host.apply_objective(int(list[clampi(int(counters.get(str(a[1]), 0)), 0, list.size() - 1)]))
		"info":
			host.apply_message(int(a[1]), false)
		"error":
			host.apply_message(int(a[1]), true)
		"add":
			counters[str(a[1])] = int(counters.get(str(a[1]), 0)) + int(a[2])
		_:
			if host.has_action(str(a[0])):
				host.apply_action(a)
			else:
				push_warning("MissionScript: unknown action %s" % str(a))


func _cond(c: Array) -> bool:
	match str(c[0]):
		"time":
			return compare(state_time, str(c[1]), float(c[2]))
		"timer":
			return compare(float(timers.get(str(c[1]), 0.0)), str(c[2]), float(c[3]))
		"flag":
			return flags.has(str(c[1]))
		"counter":
			return compare(float(counters.get(str(c[1]), 0)), str(c[2]), float(c[3]))
		"not":
			return not _cond(c[1])
		"and":
			return c.slice(1).all(func(x: Array) -> bool: return _cond(x))
		"or":
			return c.slice(1).any(func(x: Array) -> bool: return _cond(x))
	return _cond_game(c)


func _cond_game(c: Array) -> bool:
	var name := str(c[0])
	if host.has_condition(name):
		return host.make_condition(c)
	for rise in host.get_edges():
		if name == rise:
			return bool(_edges.get(rise, {}).get(str(c[1]), {}).get("rise", false))
		if name == host.get_edges()[rise].fall:
			return bool(_edges.get(rise, {}).get(str(c[1]), {}).get("fall", false))
	push_warning("MissionScript: unknown condition %s" % str(c))
	return false


static func compare(a: float, op: String, b: float) -> bool:
	match op:
		">":
			return a > b
		">=":
			return a >= b
		"<":
			return a < b
		"<=":
			return a <= b
		"==":
			return is_equal_approx(a, b)
		"!=":
			return not is_equal_approx(a, b)
	return false


## Edge flags of the tags the rules watch: true for the one tick that follows the change.
func _update_edges() -> void:
	var sources := host.get_edges()
	for rise in sources:
		var sensor: Callable = sources[rise].sensor
		var by_tag: Dictionary = _edges.get(rise, {})
		for tag in _watched(rise, str(sources[rise].fall)):
			var now := bool(sensor.call(tag))
			var rec: Dictionary = by_tag.get(tag, {"now": now})
			rec["rise"] = now and not bool(rec.now)
			rec["fall"] = not now and bool(rec.now)
			rec["now"] = now
			by_tag[tag] = rec
		_edges[rise] = by_tag


func _watched(rise: String, fall: String) -> Array:
	var out := []
	for r in _rules():
		_collect_watched(r.get("when", []), [rise, fall], out)
	return out


static func _collect_watched(c: Variant, names: Array, out: Array) -> void:
	if not (c is Array) or (c as Array).is_empty():
		return
	var a: Array = c
	if str(a[0]) in names:
		if not out.has(str(a[1])):
			out.append(str(a[1]))
		return
	for x in a:
		if x is Array:
			_collect_watched(x, names, out)
