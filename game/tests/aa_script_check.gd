extends Node
## Aerial Assault scripted missions (campaign/logic.json "script", AAScriptVM): the state machines play out with a stub host.
## Checks that every object a script names is on the mission's map, that the voice prompts exist as audio files, and the exact
## timers and failure rules read from the executable: the Gen Defender's three straying warnings, Dystopia's time limits and ally
## rule, Bastion's and Scorched Earth's straying from the allies, the wave triggers of Gen Defender and Onslaught.
##   AA_TEST_ROOT=<data folder with tribes_aa/> godot --headless --audio-driver Dummy --path game res://tests/aa_script_check.tscn

const PACK := "tribes_aa"
const P := 0x05000000
const STEP := 0.25
const WATCHDOG_SECONDS := 60.0
const PSEUDO := ["player", "TURRETS", "GENS", ""]

var _fails := 0


## What the machine senses and does, recorded.
class Stub:
	extends RefCounted
	var alive := [0, 0]
	var dist := {}                       # tag -> metres from the player (default 1000)
	var ally_dist := 10.0
	var enemy_dist := 10000.0
	var disabled := {}
	var destroyed := 0
	var deployed := 0
	var switch := false
	var boarded := false
	var log: Array = []                  # ["prompt", id] / ["end", success, id] / ["spawn", team, wave] / ["order", ...]
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
	var inputs := {}                     # name -> strength
	var voice := false
	func vm_input(n: String) -> float:
		return float(inputs.get(n, 0.0))
	func vm_count(_n: String) -> int:
		return 0
	func vm_objective(i: int) -> void:
		log.append(["objective", i])
	func vm_message(i: int, _e: bool) -> void:
		log.append(["message", i])
	func vm_audio(id: int) -> void:
		log.append(["audio", id])
	func vm_destroy(tag: String) -> void:
		log.append(["destroy", tag])
	func vm_give(_i: String, _n: int) -> void:
		pass
	func vm_prompt(id: int) -> void:
		log.append(["prompt", id])
	func vm_end(success: bool, id: int) -> void:
		log.append(["end", success, id])
	func vm_spawn(team: int, wave: int) -> void:
		log.append(["spawn", team, wave])
		alive[team] += 8                # more than any wave threshold
	func vm_order(team: int, task: int, target: String, slot: int) -> void:
		log.append(["order", team, task, target, slot])
	func vm_waypoint(tag: String, on: bool) -> void:
		log.append(["waypoint", tag, on])
	func ended() -> Array:
		for e in log:
			if e[0] == "end":
				return e
		return []
	func audios() -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == "audio").map(func(e: Array) -> int: return e[1] - P)
	func objectives() -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == "objective").map(func(e: Array) -> int: return e[1])
	func prompts() -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == "prompt").map(func(e: Array) -> int: return e[1] - P)
	func spawns() -> Array:
		return log.filter(func(e: Array) -> bool: return e[0] == "spawn")


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
	var root := OS.get_environment("AA_TEST_ROOT")
	if root != "":
		Assets.refresh()
		Assets.data_root = root
		Packs.reload()
	if not Assets.has_pack(PACK):
		print("aa_script_check: Aerial Assault is not imported, skipped")
		get_tree().quit(0)
		return
	var j = Assets.load_json(AAScript.LOGIC_FILE, PACK)
	if not (j is Dictionary) or not (j.missions as Dictionary).values().any(func(r: Dictionary) -> bool: return r.has("script")):
		print("aa_script_check: no mission scripts in logic.json (re-import), skipped")
		get_tree().quit(0)
		return
	_check_voice_format(j)
	for folder in (j.missions as Dictionary):
		var rec: Dictionary = j.missions[folder]
		if rec.has("script"):
			_check_script_objects(folder, rec)
	_check_gen_defender(_script(j, "MISSION11"))
	_check_dystopia(_script(j, "MISSION07"))
	_check_bastion(_script(j, "MISSION13"))
	_check_scorched_earth(_script(j, "MISSION08"))
	_check_onslaught(_script(j, "MISSION06"))
	_check_death_from_above(_script(j, "MISSION10"))
	_check_spawn_tags()
	_check_trainings(j)
	print("aa_script_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _script(j: Dictionary, folder: String) -> Dictionary:
	return j.missions[folder].script


func _run_for(stub: Stub, script: Dictionary, seconds: float) -> AAScriptVM:
	var vm := AAScriptVM.new(stub, script)
	var t := 0.0
	while t < seconds and not vm.finished:
		vm.step(STEP)
		t += STEP
	return vm


# ------------------------------------------------------------------ data

func _check_voice_format(j: Dictionary) -> void:
	var v: Dictionary = j.get("voice", {})
	_expect(str(v.get("bank", "")) == "training" and int(v.get("index_shift", 0)) == 1, "voice ids index the TRAINING bank (id / 2)")


## Every tag a script names exists on the map; every prompt it can play is an exported file.
func _check_script_objects(folder: String, rec: Dictionary) -> void:
	var map := MapBuilder.load_map("%s:%s" % [PACK, folder.substr(0, 1) + folder.substr(1).to_lower()])
	var tags := {}
	var prompts := {}
	_collect(rec.script, tags, prompts)
	var missing := []
	for tag in tags:
		if str(tag) in PSEUDO:
			continue
		var found: Array[Vector3] = AAScript.make_tag_positions(map, str(tag))
		if str(tag) == "TURRET1" or str(tag).begins_with("TURRET") or str(tag).begins_with("GEN"):
			found = AAScript.make_tag_positions(map, str(tag))
		if found.is_empty():
			missing.append(tag)
	_expect(missing.is_empty(), "%s: every tag of the script is on the map (missing %s)" % [folder, str(missing)])
	var absent := 0
	for id in prompts:
		if not FileAccess.file_exists(Assets.path("audio/training/%03d.ogg" % ((int(id) & 0xFFFFFF) >> 1), PACK)):
			absent += 1
	_expect(absent == 0, "%s: its %d voice prompts are exported (%d missing)" % [folder, prompts.size(), absent])
	var d: int = int(rec.script.get("death", 0))
	_expect(d == 0 and rec.type == "training" or d >= P and d < P + 0x400, "%s: the death prompt is of the bank (a training has none)" % folder)


func _collect(node: Variant, tags: Dictionary, prompts: Dictionary) -> void:
	if node is Dictionary:
		for k in node:
			if str(k) == "death":
				prompts[int(node[k])] = true
			_collect(node[k], tags, prompts)
	elif node is Array:
		var a: Array = node
		if not a.is_empty() and a[0] is String:
			match str(a[0]):
				"near", "far", "enemy_near", "disabled", "became_disabled", "became_enabled", "waypoint", "clear":
					tags[str(a[1])] = true
				"order":
					if a[3] != null:
						tags[str(a[3])] = true
				"prompt", "audio", "fail", "success":
					prompts[int(a[1])] = true
		for x in a:
			_collect(x, tags, prompts)


func _check_spawn_tags() -> void:
	_expect(AAScript.parse_spawn_tag("DERM_1L_1M_2W").wave == 1, "tag W counts from 1 (2W = the second wave)")
	_expect(AAScript.parse_spawn_tag("DERM_1H").wave == 0 and AAScript.parse_spawn_tag("DERM_1H_1W").wave == 0, "no W and 1W are wave 0")


# ------------------------------------------------------------------ Gen Defender (c11)

func _check_gen_defender(script: Dictionary) -> void:
	# straying from the generators: three warnings ten seconds apart, then the failure
	var s := Stub.new()
	s.dist = {"GEN1": 500.0, "GEN2": 500.0}
	var vm := _run_for(s, script, 40.0)
	_expect(s.prompts().slice(0, 3) == [0x14C, 0x14A, 0x150], "Gen Defender: ally order prompt, then the two straying warnings (%s)" % str(s.prompts()))
	_expect(s.ended() == ["end", false, P | 0x142], "Gen Defender: a third stretch away fails (%s)" % str(s.ended()))
	_expect(vm.finished, "the machine stops at the failure")
	# staying near resets the timer: 9 s away, 1 s near, 9 s away: no warning
	s = Stub.new()
	s.dist = {"GEN1": 500.0, "GEN2": 500.0}
	vm = AAScriptVM.new(s, script)
	for _k in 36:
		vm.step(STEP)
	s.dist = {"GEN1": 50.0, "GEN2": 50.0}
	vm.step(STEP)
	s.dist = {"GEN1": 500.0, "GEN2": 500.0}
	for _k in 36:
		vm.step(STEP)
	_expect(s.prompts() == [0x14C], "Gen Defender: coming back resets the straying timer (%s)" % str(s.prompts()))
	# both generators down fails at once; one down does not
	s = Stub.new()
	s.disabled = {"GEN1": true}
	vm = _run_for(s, script, 2.0)
	_expect(not vm.finished, "Gen Defender: one disabled generator is not the end")
	s.disabled = {"GEN1": true, "GEN2": true}
	vm.step(STEP)
	_expect(s.ended() == ["end", false, P | 0x142], "Gen Defender: both generators disabled fails")
	# the waves: enemies 90 s after the start, intruders at the generator, the next waves 45 s after each is thinned out
	s = Stub.new()
	s.dist = {"GEN1": 50.0, "GEN2": 50.0}
	vm = _run_for(s, script, 89.0)
	_expect(s.spawns() == [["spawn", 0, 0]], "Gen Defender: the allies spawn at the start (%s)" % str(s.spawns()))
	vm = _run_for_more(vm, STEP * 8)
	_expect(s.spawns().size() == 2 and s.spawns()[1] == ["spawn", 1, 0], "Gen Defender: the first BioDerms come after 90 s (%s)" % str(s.spawns()))
	s.enemy_dist = 50.0
	vm.step(STEP)
	_expect(vm.state == 2 and s.prompts().has(0x136), "Gen Defender: an enemy within 100 m of the generator starts the fight")
	s.alive[1] = 1
	vm.step(STEP)
	_expect(s.prompts().has(0x14E), "Gen Defender: one enemy left announces the next wave")
	vm = _run_for_more(vm, 44.0)
	_expect(s.spawns().size() == 2, "Gen Defender: nothing before 45 s")
	vm = _run_for_more(vm, 2.0)
	_expect(s.spawns().size() == 3 and s.spawns()[2] == ["spawn", 1, 1], "Gen Defender: wave 1 after 45 s (%s)" % str(s.spawns()))
	s.alive[1] = 4
	vm.step(STEP)
	_expect(s.prompts().has(0x140), "Gen Defender: five or fewer left announces the last wave")
	vm = _run_for_more(vm, 46.0)
	_expect(s.spawns().size() == 4 and s.spawns()[3] == ["spawn", 1, 2], "Gen Defender: wave 2 (%s)" % str(s.spawns()))
	s.alive[1] = 0
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0x152], "Gen Defender: the last wave dead wins (%s)" % str(s.ended()))


func _run_for_more(vm: AAScriptVM, seconds: float) -> AAScriptVM:
	var t := 0.0
	while t < seconds and not vm.finished:
		vm.step(STEP)
		t += STEP
	return vm


# ------------------------------------------------------------------ Dystopia (c07)

func _check_dystopia(script: Dictionary) -> void:
	var s := Stub.new()
	var vm := _run_for(s, script, 300.0)
	_expect(s.ended() == ["end", false, P | 0xF4], "Dystopia: 240 s without reaching the first waypoint fails (%s)" % str(s.ended()))
	_expect(s.prompts().has(0xE4) and s.prompts().has(0xEC), "Dystopia: reminders at 60 s and 120 s")
	_expect(s.spawns() == [["spawn", 1, 0], ["spawn", 1, 1]], "Dystopia: both BioDerm waves are there from the start")
	s = Stub.new()
	s.dist = {"WAYPT1": 150.0}
	vm = _run_for(s, script, 2.0)
	_expect(vm.state == 2 and s.spawns().any(func(e: Array) -> bool: return e[1] == 0), "Dystopia: within 200 m of the waypoint the allies come")
	s.alive = [6, 4]
	vm.step(STEP)
	s.alive[0] = 2
	vm.step(STEP)
	_expect(s.ended() == ["end", false, P | 0xF2], "Dystopia: fewer than three allies fails")
	s = Stub.new()
	s.dist = {"WAYPT1": 150.0}
	vm = _run_for(s, script, 2.0)
	s.alive = [6, 0]
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0xF6], "Dystopia: no BioDerm left wins")


# ------------------------------------------------------------------ Bastion (c13), Scorched Earth (c08)

func _check_bastion(script: Dictionary) -> void:
	var s := Stub.new()
	s.alive = [6, 5]
	s.ally_dist = 500.0
	_run_for(s, script, 50.0)
	_expect(s.prompts().slice(0, 3) == [0x160, 0x166, 0x15C], "Bastion: orders, then the two warnings about leaving the team (%s)" % str(s.prompts()))
	_expect(s.ended() == ["end", false, P | 0x15A], "Bastion: 15 s more away from the assault team fails (%s)" % str(s.ended()))
	s = Stub.new()
	s.alive = [6, 5]
	s.dist = {"WAYPT1": 100.0}
	var vm := _run_for(s, script, 2.0)
	_expect(vm.state == 2 and s.prompts().has(0x164), "Bastion: within 200 m of the waypoint the battle starts")
	s.alive[1] = 0
	vm.step(STEP)
	_expect(s.prompts().has(0x15E) and not vm.finished, "Bastion: all BioDerms dead before the switch asks for the switch")
	s.switch = true
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0x168], "Bastion: the switch with no BioDerm left wins (%s)" % str(s.ended()))


func _check_scorched_earth(script: Dictionary) -> void:
	var s := Stub.new()
	s.alive = [4, 6]
	s.ally_dist = 500.0
	_run_for(s, script, 30.0)
	_expect(s.prompts().has(0x112) and s.prompts().has(0x102), "Scorched Earth: warnings for straying from the allies (%s)" % str(s.prompts()))
	_expect(s.ended() == ["end", false, P | 0x110], "Scorched Earth: failing after 10 s more (%s)" % str(s.ended()))
	s = Stub.new()
	var vm := _run_for(s, script, 1.0)
	_expect(s.ended() == ["end", false, P | 0x110] or s.alive[0] > 0, "Scorched Earth: the allies spawn at the start")
	s = Stub.new()
	vm = AAScriptVM.new(s, script)
	vm.step(STEP)
	s.alive[0] = 4
	s.dist = {"WAYPT1": 100.0}
	vm.step(STEP)
	_expect(vm.state == 2, "Scorched Earth: within 150 m of the waypoint the turrets are next")
	s.switch = true
	s.alive[1] = 0
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0x114], "Scorched Earth: the switch and no BioDerm left wins")


# ------------------------------------------------------------------ Onslaught (c06), Death From Above (c10)

func _check_onslaught(script: Dictionary) -> void:
	var s := Stub.new()
	var vm := _run_for(s, script, 130.0)
	_expect(s.ended() == ["end", false, P | 0xDA], "Onslaught: no vehicle after 120 s fails (%s)" % str(s.ended()))
	s = Stub.new()
	s.boarded = true
	vm = _run_for(s, script, 1.0)
	_expect(vm.state == 2 and s.prompts().has(0xCA), "Onslaught: the vehicle starts the drive")
	s.dist = {"WAYPT1": 90.0}
	vm.step(STEP)
	_expect(vm.state == 3 and s.prompts().has(0xCC), "Onslaught: within 100 m of the waypoint the siege starts")
	vm = _run_for_more(vm, 184.0)
	_expect(s.spawns().is_empty(), "Onslaught: the first wave waits for 185 s")
	vm = _run_for_more(vm, 2.0)
	_expect(s.spawns() == [["spawn", 1, 0]], "Onslaught: wave 0 after 185 s (%s)" % str(s.spawns()))
	s.alive[1] = 5
	vm.step(STEP)
	_expect(s.spawns().size() == 2 and s.spawns()[1] == ["spawn", 1, 1], "Onslaught: five left brings wave 1")
	s.alive[1] = 3
	vm.step(STEP)
	_expect(s.spawns().size() == 3 and s.spawns()[2] == ["spawn", 1, 2], "Onslaught: three left brings wave 2")
	s.alive[1] = 0
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0xDC], "Onslaught: the last wave dead wins")
	# two deployed turrets cut the preparation short
	s = Stub.new()
	s.boarded = true
	vm = _run_for(s, script, 1.0)
	s.dist = {"WAYPT1": 90.0}
	vm.step(STEP)
	s.deployed = 2
	vm = _run_for_more(vm, 8.0)
	_expect(s.spawns() == [["spawn", 1, 0]], "Onslaught: two deployed turrets bring the first wave within seconds (%s)" % str(s.spawns()))


func _check_death_from_above(script: Dictionary) -> void:
	var s := Stub.new()
	_run_for(s, script, 250.0)
	_expect(s.ended() == ["end", false, P | 0x130], "Death From Above: no vehicle after 240 s fails (%s)" % str(s.ended()))
	_expect(s.prompts().has(0x120), "Death From Above: a reminder after 120 s")
	s = Stub.new()
	s.boarded = true
	var vm := _run_for(s, script, 1.0)
	s.dist = {"WAYPT1": 150.0}
	vm.step(STEP)
	_expect(vm.state == 3, "Death From Above: within 200 m of the waypoint the attack starts")
	s.alive = [0, 5]
	vm = _run_for_more(vm, 2.0)
	s.switch = true
	s.alive[1] = 0
	vm.step(STEP)
	_expect(s.ended() == ["end", true, P | 0x132], "Death From Above: the switch and no BioDerm left wins (%s)" % str(s.ended()))


# ------------------------------------------------------------------ the trainings (ct1 .. ct5)

func _check_trainings(j: Dictionary) -> void:
	var texts: Dictionary = j.get("texts", {})
	for n in range(1, 6):
		var folder := "TRAINING%d" % n
		var rec: Dictionary = j.missions.get(folder, {})
		_expect(not rec.is_empty() and rec.type == "training" and rec.has("script"), "%s: has its lessons" % folder)
		if rec.is_empty():
			continue
		var shown := {}
		_collect_texts(rec.script, shown)
		var missing := shown.keys().filter(func(k: Variant) -> bool: return not texts.has(str(k)))
		_expect(missing.is_empty(), "%s: every lesson text is in logic.json (missing %s)" % [folder, str(missing)])
	_check_training1(j.missions.TRAINING1.script)
	_check_training3(j.missions.TRAINING3.script)


func _collect_texts(node: Variant, out: Dictionary) -> void:
	if node is Array:
		var a: Array = node
		if a.size() >= 2 and str(a[0]) == "objective":
			out[int(a[1])] = true
		elif a.size() >= 3 and str(a[0]) == "objective_by":
			for k in a[2]:
				out[int(k)] = true
		for x in a:
			_collect_texts(x, out)
	elif node is Dictionary:
		for k in node:
			_collect_texts(node[k], out)


## Basic armor training: the stick and button lessons in the executable's order, the five switches, the HUD tour, the success prompt.
func _check_training1(script: Dictionary) -> void:
	var s := Stub.new()
	var vm := AAScriptVM.new(s, script)
	vm.step(STEP)
	_expect(s.audios() == [0x14] and s.objectives() == [0], "Training 1 starts with the look-up lesson (%s, %s)" % [str(s.audios()), str(s.objectives())])
	vm.step(STEP)
	_expect(vm.state == 1, "Training 1 waits for the pull on the stick")
	# one input per tick: the look lesson and the strafe lesson want both directions
	for name in ["look_up", "look_down", "look_left", "look_right", "move_forward", "move_back", "strafe_left", "strafe_right", "jump"]:
		s.inputs = {name: 1.0}
		vm.step(STEP)
	s.inputs = {"jet": 0.3}
	vm.step(STEP)
	_expect(vm.state == 8, "Training 1: a light touch of the jet is not enough (state %d)" % vm.state)
	s.inputs = {"jet": 1.0}
	vm.step(STEP)
	s.inputs = {}
	_expect(s.audios() == [0x14, 0x10, 0x12, 0x1A, 0x18, 0x1C, 0x0E, 0x0C, 0x24], "Training 1: the movement lessons play in order (%s)" % str(s.audios()))
	_expect(s.objectives() == [0, 1, 2, 3, 4, 5, 6, 7], "Training 1: their texts (%s)" % str(s.objectives()))
	vm.step(STEP)
	_expect(s.objectives().back() == 8, "Training 1: the switches (text 8)")
	# the switches: each one reached drops its waypoint and moves the text on; all five end the lesson
	for k in range(1, 6):
		s.dist = {"SWITCH%d" % k: 2.0}
		vm.step(STEP)
		s.dist = {}
	_expect(s.objectives().slice(8, 13) == [8, 9, 10, 11, 12], "Training 1: the switch texts count down (%s)" % str(s.objectives()))
	for _k in 40:
		vm.step(STEP)
	_expect(s.audios().slice(9) == [0x08, 0x00, 0x02, 0x20, 0x0A, 0x1E, 0x16], "Training 1: the HUD tour (%s)" % str(s.audios().slice(9)))
	_expect(s.ended() == ["end", true, P | 0x22], "Training 1: the success prompt (%s)" % str(s.ended()))


## Advanced weapons training: the text shows only once the voice is done; grenades, mine, mortar, missiles.
func _check_training3(script: Dictionary) -> void:
	var s := Stub.new()
	s.voice = true
	var vm := AAScriptVM.new(s, script)
	vm.step(STEP)
	vm.step(STEP)
	_expect(s.objectives().is_empty(), "Training 3: the lesson text waits for the voice line to end")
	s.voice = false
	vm.step(STEP)
	_expect(s.objectives() == [37], "Training 3: then the pickup text")
	s.dist = {"PATCH": 2.0}
	vm.step(STEP)
	_expect(vm.state == 1, "Training 3: one pickup is not both")
	s.dist = {"PATCH": 2.0, "KIT": 2.0}
	vm.step(STEP)
	vm.step(STEP)
	_expect(vm.state == 2 and s.audios().has(0x46), "Training 3: both pickups start the grenade lesson")
	for item in ["grenade_throw", "grenade_throw", "grenade_throw", "mine_drop"]:
		s.inputs = {item: 1.0}
		vm.step(STEP)
		vm.step(STEP)
	s.inputs = {}
	_expect(s.audios().slice(0, 6) == [0x4E, 0x46, 0x44, 0x42, 0x48, 0x4C], "Training 3: grenades, flare, concussion, mine, mortar (%s)" % str(s.audios()))
	_expect(s.objectives().slice(0, 6) == [37, 38, 39, 40, 41, 42], "Training 3: their texts (%s)" % str(s.objectives()))
