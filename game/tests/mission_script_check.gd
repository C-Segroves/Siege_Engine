extends Node
## MissionScript against AAScriptVM: the Aerial Assault logic fixtures (campaign/logic.json "script": every mission and
## training) run through both machines with a stub host. The same inputs go to both; after every step the state, the flags,
## the timers, the counters and everything the host was told must be equal. Also the built-in logic on small programs.
##   AA_TEST_ROOT=<data folder with tribes_aa/> godot --headless --audio-driver Dummy --path game res://tests/mission_script_check.tscn

const PACK := "tribes_aa"
const STEP := 0.25
const FUZZ_SEEDS := 8
const FUZZ_STEPS := 1200
const WATCHDOG_SECONDS := 120.0
const DISTANCES := [2.0, 50.0, 120.0, 400.0, 1000.0]
const INPUTS := ["look_up", "look_down", "look_left", "look_right", "move_forward", "move_back", "strafe_left", "strafe_right",
	"jump", "jet", "grenade_throw", "mine_drop"]

var _fails := 0


## What the machines sense and do, recorded.
class Stub:
	extends RefCounted
	var alive := [0, 0]
	var dist := {}
	var ally_dist := 10.0
	var enemy_dist := 10000.0
	var disabled := {}
	var destroyed := 0
	var deployed := 0
	var switch := false
	var boarded := false
	var voice := false
	var inputs := {}
	var log: Array = []
	func vm_alive(team: int) -> int:
		return alive[team]
	func vm_distance(tag: String) -> float:
		return float(dist.get(tag, 1000.0))
	func vm_ally_distance() -> float:
		return ally_dist
	func vm_enemy_distance(_tag: String) -> float:
		return enemy_dist
	func vm_disabled(tag: String) -> bool:
		return bool(disabled.get(tag, false))
	func vm_destroyed() -> int:
		return destroyed
	func vm_deployed() -> int:
		return deployed
	func vm_switch() -> bool:
		return switch
	func vm_boarded() -> bool:
		return boarded
	func vm_voice_playing() -> bool:
		return voice
	func vm_input(n: String) -> float:
		return float(inputs.get(n, 0.0))
	func vm_count(_n: String) -> int:
		return 0
	func vm_objective(i: int) -> void:
		log.append(["objective", i])
	func vm_message(i: int, e: bool) -> void:
		log.append(["message", i, e])
	func vm_audio(id: int) -> void:
		log.append(["audio", id])
	func vm_destroy(tag: String) -> void:
		log.append(["destroy", tag])
	func vm_give(i: String, n: int) -> void:
		log.append(["give", i, n])
	func vm_prompt(id: int) -> void:
		log.append(["prompt", id])
	func vm_end(success: bool, id: int) -> void:
		log.append(["end", success, id])
	func vm_spawn(team: int, wave: int) -> void:
		log.append(["spawn", team, wave])
		alive[team] += 8
	func vm_order(team: int, task: int, target: String, slot: int) -> void:
		log.append(["order", team, task, target, slot])
	func vm_waypoint(tag: String, on: bool) -> void:
		log.append(["waypoint", tag, on])


## The Aerial Assault half of the machine as a MissionScriptHost over a Stub (what the game's adapter will be).
class StubHost:
	extends MissionScriptHost
	var s: Stub
	func _init(p_stub: Stub) -> void:
		s = p_stub
		register_condition("enemies", func(c: Array) -> bool: return MissionScript.compare(s.vm_alive(1), str(c[1]), float(c[2])))
		register_condition("allies", func(c: Array) -> bool: return MissionScript.compare(s.vm_alive(0), str(c[1]), float(c[2])))
		register_condition("near", func(c: Array) -> bool: return s.vm_distance(str(c[1])) < float(c[2]))
		register_condition("far", func(c: Array) -> bool: return s.vm_distance(str(c[1])) > float(c[2]))
		register_condition("ally_far", func(c: Array) -> bool: return s.vm_ally_distance() > float(c[1]))
		register_condition("enemy_near", func(c: Array) -> bool: return s.vm_enemy_distance(str(c[1])) < float(c[2]))
		register_condition("disabled", func(c: Array) -> bool: return s.vm_disabled(str(c[1])))
		register_condition("destroyed", func(c: Array) -> bool: return MissionScript.compare(s.vm_destroyed(), str(c[1]), float(c[2])))
		register_condition("deployed", func(c: Array) -> bool: return MissionScript.compare(s.vm_deployed(), str(c[1]), float(c[2])))
		register_condition("switch", func(_c: Array) -> bool: return s.vm_switch())
		register_condition("boarded", func(_c: Array) -> bool: return s.vm_boarded())
		register_condition("voice_playing", func(_c: Array) -> bool: return s.vm_voice_playing())
		register_condition("input", func(c: Array) -> bool:
			return s.vm_input(str(c[1])) >= float(c[2]) if c.size() > 2 else s.vm_input(str(c[1])) > 0.0)
		register_condition("count", func(c: Array) -> bool: return MissionScript.compare(s.vm_count(str(c[1])), str(c[2]), float(c[3])))
		register_edge("became_disabled", "became_enabled", s.vm_disabled)
		register_action("spawn", func(a: Array) -> void: s.vm_spawn(1 if str(a[1]) == "enemies" else 0, int(a[2])))
		register_action("order", func(a: Array) -> void:
			s.vm_order(1 if str(a[1]) == "enemies" else 0, int(a[2]), a[3] if a[3] != null else "", int(a[4])))
		register_action("waypoint", func(a: Array) -> void: s.vm_waypoint(str(a[1]), true))
		register_action("clear", func(a: Array) -> void: s.vm_waypoint(str(a[1]), false))
		register_action("destroy", func(a: Array) -> void: s.vm_destroy(str(a[1])))
		register_action("give", func(a: Array) -> void: s.vm_give(str(a[1]), int(a[2])))
	func apply_prompt(id: int) -> void:
		s.vm_prompt(id)
	func apply_audio(id: int) -> void:
		s.vm_audio(id)
	func apply_objective(i: int) -> void:
		s.vm_objective(i)
	func apply_message(i: int, is_error: bool) -> void:
		s.vm_message(i, is_error)
	func apply_end(success: bool, id: int) -> void:
		s.vm_end(success, id)


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	_check_builtins()
	_check_task()
	_check_edges()
	var root := OS.get_environment("AA_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	var j = Assets.load_json(AAScript.LOGIC_FILE, PACK) if Assets.has_pack(PACK) else null
	if j is Dictionary and (j.missions as Dictionary).values().any(func(r: Dictionary) -> bool: return r.has("script")):
		for folder in (j.missions as Dictionary):
			if (j.missions[folder] as Dictionary).has("script"):
				_check_parity(folder, j.missions[folder].script)
	else:
		print("mission_script_check: Aerial Assault logic is not imported, parity skipped")
	print("mission_script_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


# ------------------------------------------------------------------ the built-ins on small programs

class Recorder:
	extends MissionScriptHost
	var log: Array = []
	func apply_prompt(id: int) -> void:
		log.append(["prompt", id])
	func apply_objective(i: int) -> void:
		log.append(["objective", i])
	func apply_message(i: int, e: bool) -> void:
		log.append(["message", i, e])
	func apply_end(success: bool, id: int) -> void:
		log.append(["end", success, id])


func _check_builtins() -> void:
	var program := {"initial": 1, "states": {
		"1": {"enter": [["objective", 3]], "timers": [{"name": "t", "while": ["flag", "run"]}], "rules": [
			{"when": ["time", ">=", 1.0], "do": [["flag", "run"], ["add", "n", 2]]},
			{"when": ["and", ["timer", "t", ">=", 1.0], ["counter", "n", ">=", 2]], "do": [["prompt", 7], ["state", 2]]}]},
		"2": {"enter": [["objective_by", "n", [10, 11]], ["info", 4]], "rules": [
			{"when": ["or", ["flag", "nope"], ["not", ["flag", "nope"]]], "do": [["success", 9], ["error", 5]]}]}},
		"events": {"boom": [["error", 6], ["fail", 8]]}}
	var host := Recorder.new()
	var m := MissionScript.new(host, program)
	for _i in 3:
		m.step(0.5)
	_expect(m.state == 1 and host.log == [["objective", 3]], "state 1: the enter action runs once, the timer counts only while its flag holds")
	m.step(0.5)
	_expect(m.state == 2 and host.log.slice(1) == [["prompt", 7], ["objective", 10], ["message", 4, false]],
		"the timer and counter rule moves on; flags, timers and counters of state 1 are gone (%s)" % str(host.log))
	_expect(m.flags.is_empty() and m.counters.is_empty() and m.state_time == 0.0, "entering a state clears its flags, counters and clock")
	m.step(0.5)
	_expect(m.finished and host.log.slice(-1) == [["end", true, 9]] and m.state_name() == "", "success ends the script and stops the tick (%s)" % str(host.log))
	m.step(0.5)
	_expect(host.log.size() == 5, "a finished script does nothing more")
	host = Recorder.new()
	m = MissionScript.new(host, program)
	m.notify("boom")
	_expect(host.log == [["message", 6, true], ["end", false, 8]] and m.finished, "an event runs its actions (%s)" % str(host.log))
	host = Recorder.new()
	m = MissionScript.new(host, program)
	m.fail(55)
	m.fail(56)
	_expect(host.log == [["end", false, 55]], "fail(voice) ends once")
	var edge := MissionScript.new(Recorder.new(), {"states": {"1": {"rules": []}}})
	edge.step(0.1)
	_expect(MissionScript.compare(1.0, "==", 1.0) and not MissionScript.compare(1.0, "!=", 1.0) and not MissionScript.compare(1.0, "?", 1.0), "compare knows its operators")


func _check_edges() -> void:
	var s := Stub.new()
	var host := StubHost.new(s)
	var program := {"states": {"1": {"rules": [
		{"when": ["became_disabled", "G"], "do": [["prompt", 1]]},
		{"when": ["became_enabled", "G"], "do": [["prompt", 2]]}]}}}
	var m := MissionScript.new(host, program)
	m.step(0.25)
	s.disabled["G"] = true
	m.step(0.25)
	m.step(0.25)
	s.disabled["G"] = false
	m.step(0.25)
	_expect(s.log == [["prompt", 1], ["prompt", 2]], "registered edges hold for one tick after the change (%s)" % str(s.log))


# ------------------------------------------------------------------ parity with AAScriptVM

func _collect_tags(node: Variant, tags: Dictionary) -> void:
	if node is Array:
		var a: Array = node
		if not a.is_empty() and a[0] is String and a.size() > 1 and str(a[0]) in ["near", "far", "enemy_near", "disabled", "became_disabled", "became_enabled"]:
			tags[str(a[1])] = true
		for x in a:
			_collect_tags(x, tags)
	elif node is Dictionary:
		for k in node:
			_collect_tags(node[k], tags)


## One round of random inputs, the same for both stubs. Distances favour "near" so the scripts get past their first state.
func _randomise(rng: RandomNumberGenerator, tags: Array, stubs: Array, near_bias: float) -> void:
	var dist := {}
	for t in tags:
		dist[t] = DISTANCES[rng.randi() % DISTANCES.size()] if rng.randf() > near_bias else 2.0
	var fields := {
		"ally_dist": [10.0, 500.0][rng.randi() % 2], "enemy_dist": [50.0, 10000.0][rng.randi() % 2],
		"switch": rng.randf() < 0.3, "boarded": rng.randf() < 0.6, "voice": rng.randf() < 0.3,
		"destroyed": rng.randi() % 4, "deployed": rng.randi() % 4,
		"inputs": {INPUTS[rng.randi() % INPUTS.size()]: [0.3, 1.0][rng.randi() % 2]},
	}
	var toggled: String = str(tags[rng.randi() % tags.size()]) if not tags.is_empty() and rng.randf() < 0.1 else ""
	var kills := rng.randf() < 0.1
	var victim: int = rng.randi() % 2
	for st in stubs:
		st.dist = dist.duplicate()
		for f in fields:
			st.set(f, fields[f])
		if toggled != "":
			st.disabled[toggled] = not bool(st.disabled.get(toggled, false))
		if kills:
			st.alive[victim] = maxi(st.alive[victim] - 3, 0)


func _check_parity(folder: String, script: Dictionary) -> void:
	var tag_set := {}
	_collect_tags(script, tag_set)
	var tags := tag_set.keys()
	var diverged := ""
	var states_seen := {}
	var ended := 0
	for seed in FUZZ_SEEDS:
		var rng := RandomNumberGenerator.new()
		rng.seed = seed * 7919 + 1
		var a := Stub.new()
		var b := Stub.new()
		var old_vm := AAScriptVM.new(a, script)
		var new_vm := MissionScript.new(StubHost.new(b), script)
		for n in FUZZ_STEPS:
			_randomise(rng, tags, [a, b], [0.3, 0.8, 0.97][seed % 3])
			old_vm.step(STEP)
			new_vm.step(STEP)
			diverged = _diff(old_vm, new_vm, a, b)
			if diverged != "":
				diverged = "seed %d step %d: %s" % [seed, n, diverged]
				break
			states_seen[old_vm.state] = true
			if n % 97 == 96 and not old_vm.finished:
				old_vm.notify("turret_destroyed")
				new_vm.notify("turret_destroyed")
		if diverged != "":
			break
		if old_vm.finished:
			ended += 1
		old_vm.fail(5)
		new_vm.fail(5)
		if str(a.log) != str(b.log):
			diverged = "fail(voice) differs"
			break
	_expect(diverged == "", "%s: MissionScript equals AAScriptVM over %d fuzzed runs (%d states reached, %d ended) %s" % [
		folder, FUZZ_SEEDS, states_seen.size(), ended, diverged])


func _diff(old_vm: AAScriptVM, new_vm: MissionScript, a: Stub, b: Stub) -> String:
	if old_vm.state != new_vm.state or old_vm.finished != new_vm.finished:
		return "state %d/%s vs %d/%s" % [old_vm.state, old_vm.finished, new_vm.state, new_vm.finished]
	if str(old_vm.flags) != str(new_vm.flags) or str(old_vm.timers) != str(new_vm.timers) or str(old_vm.counters) != str(new_vm.counters):
		return "flags / timers / counters differ"
	if not is_equal_approx(old_vm.state_time, new_vm.state_time):
		return "state_time differs"
	if str(a.log) != str(b.log):
		return "the host was told different things"
	return ""


## The sequential executor: waits, blocking and plain calls, if / loop / for / exit_loop, a registered op, the step cap.
func _check_task() -> void:
	var said: Array = []
	var scripts := [
		{"label": "main", "name": "S0", "message": "Start", "by": ["all"], "enabled": true, "actions": [
			{"op": "say", "word": "a"}, {"op": "exec", "script": "sub", "block": true}, {"op": "say", "word": "d"},
			{"op": "for", "from": 1, "to": 3, "actions": [{"op": "say", "word": "f"}]},
			{"op": "loop", "actions": [{"op": "say", "word": "l"}, {"op": "exit_loop"}]},
			{"op": "if", "tests": [1], "then": [{"op": "say", "word": "yes"}], "else": [{"op": "say", "word": "no"}]}]},
		{"label": "sub", "name": "S1", "message": "", "by": [], "enabled": true, "actions": [
			{"op": "say", "word": "b"}, {"op": "wait", "s": 1.0}, {"op": "say", "word": "c"}]},
		{"label": "spin", "name": "S2", "message": "Spin", "by": [], "enabled": true, "actions": [
			{"op": "loop", "actions": [{"op": "say", "word": "s"}]}]},
		{"label": "off", "name": "S3", "message": "Off", "by": [], "enabled": false, "actions": [{"op": "say", "word": "off"}]}]
	var task := MissionTask.new(scripts)
	task.register_op("say", func(_t: MissionTask.Task, a: Dictionary) -> void: said.append(str(a.word)))
	task.tester = func(tests: Array) -> bool: return tests == [1]
	_expect(task.fire("Start", "x") == 1 and task.fire("Off") == 0, "fire starts the enabled scripts of a message")
	task.tick(0.1)
	task.tick(0.1)
	_expect(said == ["a", "b"] and task.is_running(), "a blocking call holds the caller while the callee waits (%s)" % str(said))
	task.tick(0.5)
	_expect(said == ["a", "b"], "the wait holds")
	task.tick(0.5)
	task.tick(0.1)
	_expect(said == ["a", "b", "c", "d", "f", "f", "f", "l", "yes"] and not task.is_running(), "the caller goes on after the callee: for, loop, if (%s)" % str(said))
	said.clear()
	task.apply_script_enabled("off", true)
	_expect(task.fire("Off") == 1, "a disabled script can be enabled")
	task.fire("Spin")
	task.tick(0.1)
	_expect(said.size() == 1 + MissionTask.MAX_STEPS_PER_TICK / 2, "a loop without a wait stops at the step cap (%d)" % said.size())
