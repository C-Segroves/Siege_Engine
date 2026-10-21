class_name TVScriptHost
extends RefCounted
## The Vengeance half of the mission script machine (maps/<id>/script.json, tools/tv_script.py; docs/formats/tribes_vengeance.md
## "Mission scripts"): the actions the UnrealScript Script actors use, registered on a MissionTask, over `game` (TVMissionRuntime).
## It owns what the script says and shows: the shared variable table (names lower case, no "global." prefix), the spoken lines
## (an announcer; speak tells the script how long the radio stays busy), the objectives (states 0 added, 1 done, 2 failed,
## 3 removed) and the countdown. What reaches the placed soldiers, triggers and the player is the game's, called as:
##   apply_enable(label, on)  apply_destroy(label)  apply_spawn_point(label, on)  apply_teleport(label, to_label)
##   apply_damage(label, amount)  apply_end(success)  has_overlay()  make_speaker_name(label)  nav_points, nav_index
## Messages come in through tasks.fire(): "MessageLevelStart", "MessagePlayerStart", "MessageTriggerEnter" / "...Exit" (label of
## the trigger), "MessageDeath" (label of the dead), "MessageSquadDeath", "MessageAISpawned", "MessageCountDownExpired".

const SPEAK_GAP := 0.25
const PROMPT_SECONDS := 6.0
const TEXT_SECONDS_BASE := 1.0
const TEXT_SECONDS_PER_CHAR := 0.05
const SOUND_NEAR_MIN := 8.0
const SOUND_FAR_MIN := 150.0
const SOUND_NEAR_SHARE := 0.1
const COUNTDOWN_ID := "countdown"
const STATE_FROM_CODE := {0: Objective.State.ACTIVE, 1: Objective.State.DONE, 2: Objective.State.FAILED}

var tasks: MissionTask
var vars := {}
var game: Object

var _actors: Dictionary
var _announcer: MissionAnnouncer
var _objectives := ObjectiveSet.new()
var _markers := {}               # objective name -> actor labels its markers sit on
var _timers := MissionTimers.new()


## What the radio does with a spoken line: the text goes to the overlay, the voice to the speech channel.
class SpeechSink:
	extends MissionSink
	var _game: Object
	var _player: AudioStreamPlayer

	func _init(p_game: Object, p_player: AudioStreamPlayer) -> void:
		_game = p_game
		_player = p_player

	func apply_message(message: MissionMessage) -> void:
		if message.text != "" and _game.has_overlay():
			_game.battle.overlay.show_radio(message.speaker, message.text)

	## The voice's id is the loaded stream.
	func apply_voice(voice: MissionVoice) -> void:
		_player.stream = voice.id
		_player.play()

	func is_voice_playing() -> bool:
		return _player.playing


func _init(p_game: Object, p_scripts: Array, p_actors: Dictionary, p_speech: AudioStreamPlayer) -> void:
	game = p_game
	_actors = p_actors
	_announcer = MissionAnnouncer.new(SpeechSink.new(game, p_speech), MissionAnnouncer.Discipline.CUT)
	tasks = MissionTask.new(p_scripts)
	tasks.tester = make_tests_pass
	_register_ops()


## Moves the countdown and the radio on; the countdown running out raises the script message.
func apply_tick(delta: float) -> void:
	_announcer.apply_tick(delta)
	if not _timers.apply_tick(delta).is_empty():
		tasks.fire("MessageCountDownExpired", "all")


func make_countdown() -> float:
	return _timers.make_time_left(COUNTDOWN_ID)


## The objectives as records {name, text, state (0 open, 1 done, 2 failed), markers}.
func make_objective_records() -> Array:
	var out := []
	for o in _objectives.get_objectives():
		out.append({"name": o.id, "text": o.text, "state": STATE_FROM_CODE.find_key(o.state), "markers": _markers.get(o.id, [])})
	return out


func make_objective_lines() -> Array:
	var out := []
	for o in _objectives.get_objectives():
		out.append({"text": o.text + (" (failed)" if o.is_failed() else ""), "done": o.is_done()})
	var left := make_countdown()
	if left > 0.0:
		out.append({"text": "Time left: %d s" % int(ceil(left)), "done": false})
	if out.is_empty():
		out.append({"text": "Follow the mission.", "done": false})
	return out


## ActionIf: the tests are ORed; no tests = true. Unknown engine calls compare false.
func make_tests_pass(tests: Array) -> bool:
	if tests.is_empty():
		return true
	for t in tests:
		if _make_test_pass(t):
			return true
	return false


func _register_ops() -> void:
	tasks.register_op("speak", _exec_speak)
	tasks.register_op("obj_add", func(_t: MissionTask.Task, a: Dictionary) -> void:
		_apply_objective(str(a.name), str(a.get("text", "")), a.get("markers", []), 0))
	tasks.register_op("obj_status", func(_t: MissionTask.Task, a: Dictionary) -> void:
		_apply_objective(str(a.name), "", [], 1 if int(a.status) == 1 else 2))
	tasks.register_op("obj_remove", func(_t: MissionTask.Task, a: Dictionary) -> void:
		_apply_objective(str(a.get("name", "")), "", [], 3))
	tasks.register_op("var", func(_t: MissionTask.Task, a: Dictionary) -> void: _apply_assign(a))
	tasks.register_op("random", _exec_random)
	tasks.register_op("enable", _exec_switch)
	tasks.register_op("disable", _exec_switch)
	tasks.register_op("destroy", func(_t: MissionTask.Task, a: Dictionary) -> void: game.apply_destroy(str(a.target)))
	tasks.register_op("goal", func(_t: MissionTask.Task, a: Dictionary) -> void:
		game.apply_goal(str(a.target), str(a.mode), str(a.get("name", "")), a.get("goal") if a.get("goal") is Dictionary else {}))
	tasks.register_op("spawn_on", _exec_spawn_point)
	tasks.register_op("spawn_off", _exec_spawn_point)
	tasks.register_op("teleport", func(_t: MissionTask.Task, a: Dictionary) -> void: game.apply_teleport(str(a.target), str(a.to)))
	tasks.register_op("damage", func(_t: MissionTask.Task, a: Dictionary) -> void: game.apply_damage(str(a.target), float(a.amount)))
	tasks.register_op("prompt", _exec_prompt)
	tasks.register_op("sound", _exec_sound)
	tasks.register_op("countdown", func(_t: MissionTask.Task, a: Dictionary) -> void: _apply_countdown(float(a.s)))
	tasks.register_op("next", func(_t: MissionTask.Task, _a: Dictionary) -> void: _apply_end(true))
	tasks.register_op("fail", func(_t: MissionTask.Task, _a: Dictionary) -> void: _apply_end(false))


func _apply_end(success: bool) -> void:
	tasks.ended = true
	game.apply_end(success)


func _exec_switch(_t: MissionTask.Task, a: Dictionary) -> void:
	var on := str(a.op) == "enable"
	if not tasks.apply_script_enabled(str(a.target), on):
		game.apply_enable(str(a.target), on)


func _exec_spawn_point(_t: MissionTask.Task, a: Dictionary) -> void:
	game.apply_spawn_point(str(a.target), str(a.op) == "spawn_on")


func _exec_random(_t: MissionTask.Task, a: Dictionary) -> void:
	vars["rand"] = str(randi_range(int(float(a.min)), int(float(a.max))))
	vars["random"] = vars["rand"]


func _exec_prompt(_t: MissionTask.Task, a: Dictionary) -> void:
	var text := str(a.get("text", ""))
	if text != "" and game.has_overlay():
		game.battle.overlay.show_message(text, PROMPT_SECONDS)


func _exec_sound(_t: MissionTask.Task, a: Dictionary) -> void:
	var radius := float(a.get("radius", 0.0))
	var pos: Vector3 = game.battle.player.global_position if game.battle.player != null else Vector3.ZERO
	var where: Array = _actors.get(str(a.get("at", "")), [])
	if not where.is_empty():
		pos = Vector3(float(where[0]), float(where[1]), float(where[2]))
	var distances := Vector2(maxf(radius * SOUND_NEAR_SHARE, SOUND_NEAR_MIN), maxf(radius, SOUND_FAR_MIN))
	Sfx.play_at_range("%s:%s" % [TVMissionRuntime.TV_PACK, str(a.stem)], pos, 0.0, distances)


# ------------------------------------------------------------------ speech

func _exec_speak(t: MissionTask.Task, a: Dictionary) -> void:
	var seconds := _make_say(str(a.tag), str(a.get("text", "")), str(a.get("target", "")))
	if bool(a.get("wait", true)) and seconds > 0.0:
		t.wait = seconds + SPEAK_GAP


## Says a line (the tag's speech file, the text on the radio overlay) and returns the seconds the radio stays busy (0 = unknown).
func _make_say(tag: String, text: String, target: String) -> float:
	var stream := _load_voice(tag)
	var busy := stream.get_length() if stream != null else 0.0
	if text != "" and game.has_overlay():
		busy = maxf(busy, TEXT_SECONDS_BASE + text.length() * TEXT_SECONDS_PER_CHAR)
	var voice: MissionVoice = MissionVoice.make_voice(stream) if stream != null else null
	_announcer.apply_say(MissionMessage.make_message(text, busy, MissionMessage.CHANNEL_RADIO, game.make_speaker_name(target), voice))
	return _announcer.make_busy_seconds()


static func _load_voice(tag: String) -> AudioStream:
	var file := Assets.path("audio/voice/%s.ogg" % tag, TVMissionRuntime.TV_PACK)
	return AudioStreamOggVorbis.load_from_file(file) if FileAccess.file_exists(file) else null


# ------------------------------------------------------------------ objectives and countdown

func _apply_objective(name: String, text: String, markers: Array, code: int) -> void:
	var found := _objectives.get_objective(name) as ScriptObjective
	if code == 3:
		_objectives.apply_remove(name)
		_markers.erase(name)
	elif found == null:
		if code != 0:
			return
		_objectives.apply_add(ScriptObjective.new(name, text if text != "" else make_pretty_name(name)))
		_markers[name] = markers
	else:
		found.apply_state(STATE_FROM_CODE[code])
		if code == 0:
			_markers[name] = markers
			if text != "":
				found.apply_text(text)
	_aim_markers()


## The nav markers follow the latest open objective that has some (its actors' positions).
func _aim_markers() -> void:
	var points: Array[Vector3] = []
	var list := _objectives.get_objectives()
	for i in range(list.size() - 1, -1, -1):
		if list[i].state != Objective.State.ACTIVE:
			continue
		for label in _markers.get(list[i].id, []):
			var at: Array = _actors.get(str(label), [])
			if not at.is_empty():
				points.append(Vector3(float(at[0]), float(at[1]), float(at[2])))
		if not points.is_empty():
			break
	game.nav_points = points
	game.nav_index = 0


## A countdown of `seconds` or less stops the countdown.
func _apply_countdown(seconds: float) -> void:
	if seconds > 0.0:
		_timers.apply_add(COUNTDOWN_ID, MissionTimer.make_timer(seconds))
	else:
		_timers.apply_cancel(COUNTDOWN_ID)


## "objCaptureDaniel" -> "Capture Daniel".
static func make_pretty_name(name: String) -> String:
	var s := name
	for prefix in ["obj_", "obj", "OBJ_"]:
		if s.begins_with(prefix) and s.length() > prefix.length():
			s = s.substr(prefix.length())
			break
	var out := ""
	for i in s.length():
		var ch := s[i]
		if i > 0 and ch >= "A" and ch <= "Z" and s[i - 1] >= "a" and s[i - 1] <= "z":
			out += " "
		out += ch
	return out.replace("_", " ").strip_edges().capitalize()


# ------------------------------------------------------------------ variables

func _apply_assign(a: Dictionary) -> void:
	var name := str(a.name)
	var raw := str(a.value)
	var rhs: String = str(vars.get(raw.to_lower(), raw))      # a variable name on the right reads its value
	match str(a.kind):
		"init":
			if not vars.has(name):
				vars[name] = rhs
		"set":
			vars[name] = rhs
		"inc":
			vars[name] = _num_text(_num(vars.get(name, "0")) + 1.0)
		"dec":
			vars[name] = _num_text(_num(vars.get(name, "0")) - 1.0)
		"add":
			vars[name] = _num_text(_num(vars.get(name, "0")) + _num(rhs))
		"sub":
			vars[name] = _num_text(_num(vars.get(name, "0")) - _num(rhs))
		"mul":
			vars[name] = _num_text(_num(vars.get(name, "0")) * _num(rhs))
		"div":
			var d := _num(rhs)
			vars[name] = _num_text(_num(vars.get(name, "0")) / d) if d != 0.0 else "0"


func _make_test_pass(t: Dictionary) -> bool:
	var l = _make_side(t.lhs)
	var r = _make_side(t.rhs)
	if l == null or r == null:
		return false
	var ls := str(l)
	var rs := str(r)
	if ls.is_valid_float() and rs.is_valid_float():
		return is_equal_approx(_num(ls), _num(rs))
	return ls.to_lower() == rs.to_lower()


func _make_side(s: Dictionary) -> Variant:
	if s.has("var"):
		return str(vars.get(str(s["var"]), ""))
	if s.has("call"):
		return tasks.instigator if str(s.call) == "get message value" else null
	var lit := str(s.get("lit", ""))
	return str(vars[lit.to_lower()]) if vars.has(lit.to_lower()) else lit


static func _num(v: Variant) -> float:
	var s := str(v)
	return s.to_float() if s.is_valid_float() else (1.0 if s.to_lower() == "true" else 0.0)


static func _num_text(x: float) -> String:
	return str(int(x)) if is_equal_approx(x, round(x)) else str(x)
