extends Node
## Headless check of the campaign radio (ChatChannels.RADIO):
##   Godot --headless --audio-driver Dummy --path game res://tests/radio_check.tscn
## Earthsiege: a campaign wingman's kill is called on the radio (text from the pilot tables).
## Earthsiege 2: a training region speaks its COMMAND<lesson> message; a campaign wingman's kill is called.
## Starsiege: a script say() with a speaker-tagged string and one naming an AI vehicle.
## Every line must reach battle.overlay.chat_log with a speaker, and the radio filter must hide / show it.
## Texts are compared against the pack's own tables (no original text in this file).

const SETTLE_FRAMES := 20
const WAIT_FRAMES := 120
const ES1_MISSION := "B0_C0_0A"
const ES2_TRAINING := "es2:TRAIN1"
const ES2_CAMPAIGN := "es2:C1_01"
const SS_MISSION := "starsiege:HA0"
const OWN_TEXT := "radio check line"
const KILL_DAMAGE := 1e9

var _errors := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	await _check_es1()
	await _check_es2_training()
	await _check_es2_wingman()
	await _check_starsiege()
	print("radio_check: %s" % ("OK" if _errors == 0 else "FAILED (%d)" % _errors))
	get_tree().quit(1 if _errors else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_errors += 1
		printerr("radio_check: FAIL ", what)


# ------------------------------------------------------------------ battles

func _start_battle(config: Dictionary) -> Node:
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	config.merge({"mode": "mission", "respawn": false})
	battle.config = config
	get_tree().root.add_child(battle)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	return battle


func _end_battle(battle: Node) -> void:
	battle.queue_free()
	await get_tree().process_frame
	await get_tree().process_frame


func _roster(vehicle: String) -> Dictionary:
	return {1: {"name": "Tester", "vehicle": vehicle, "team": 0, "loadout": []}}


## Waits until a radio line satisfying `accept` is in the chat log; returns it ({} on time-out).
func _wait_radio(battle: Node, accept: Callable) -> Dictionary:
	for i in WAIT_FRAMES:
		for e in battle.overlay.chat_log.entries:
			if e.channel == ChatChannels.RADIO and accept.call(e):
				return e
		await get_tree().physics_frame
	return {}


## The radio filter hides radio lines and shows them again.
func _check_filter(battle: Node, label: String) -> void:
	var log: ChatLog = battle.overlay.chat_log
	var hidden := log.make_shown({ChatChannels.RADIO: false, ChatChannels.SYSTEM: true})
	var shown := log.make_shown({ChatChannels.RADIO: true})
	_expect(not hidden.any(func(e): return e.channel == ChatChannels.RADIO), "%s: radio filter off hides radio" % label)
	_expect(shown.any(func(e): return e.channel == ChatChannels.RADIO), "%s: radio filter on shows radio" % label)


## Every text of a pack's pilot tables (to compare chat lines with).
static func _pilot_texts(pack: String) -> Array:
	var texts := []
	for n in WingmanRadio.PILOT_TABLES:
		var rows = Assets.load_json(RadioTable.TABLE_PATH % ("pilot%d" % n), pack)
		for r in (rows if rows is Array else []):
			texts.append(RadioTable.make_clean_text(str(r.text)))
	return texts


static func _first_hostile(battle: Node, team: int) -> Herc:
	for v in battle.get_tree().get_nodes_in_group("vehicles"):
		if v is Herc and v.alive and v.team != team:
			return v
	return null


## A wingman destroys a hostile unit; its kill call (or any of its lines) must reach the chat.
func _check_wingman_kill(battle: Node, pack: String, label: String) -> void:
	var radio: WingmanRadio = battle.mission.wingman_radio
	_expect(radio != null and radio.wingman_count() > 0, "%s: wingman radio has wingmen" % label)
	if radio == null or radio.wingman_count() == 0:
		return
	var wing: Herc = radio._wingmen[0].unit
	var foe := _first_hostile(battle, wing.team)
	_expect(foe != null, "%s: a hostile unit to destroy" % label)
	if foe:
		foe.apply_hit(0.0, KILL_DAMAGE, wing, foe.global_position)
	var texts := _pilot_texts(pack)
	var e := await _wait_radio(battle, func(x): return x.sender != "" and texts.has(x.text))
	_expect(not e.is_empty(), "%s: a wingman line from the pilot tables in the chat" % label)
	if not e.is_empty():
		print("%s: radio line from %s" % [label, e.sender])
	_check_filter(battle, label)


# ------------------------------------------------------------------ games

func _check_es1() -> void:
	var squad := [{"vehicle": "es1:RAPTOR", "loadout": [], "name": "Wingman One", "skill": 0.5, "garage": {}}]
	var battle := await _start_battle({"mission_name": ES1_MISSION, "roster": _roster("es1:RAPTOR"), "squad": squad})
	await _check_wingman_kill(battle, "es1", "es1")
	await _end_battle(battle)


func _check_es2_training() -> void:
	var mdef := MissionCompiler.load_mission(ES2_TRAINING, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	var battle := await _start_battle({"mission": mdef, "roster": _roster("es2:OUTLAW")})
	var rt: MissionRuntimeES2 = battle.mission
	_expect(rt.command_radio.is_training(), "es2 training: lesson %d has a command table" % rt.command_radio.lesson)
	var ri := _first_message_region(rt)
	_expect(ri >= 0, "es2 training: a region with a message")
	if ri >= 0:
		var table := RadioTable.load_table("es2", "command%d" % rt.command_radio.lesson)
		var want: Dictionary = table.make_joined_line(int(rt.regions[ri].def.message) - 1)
		rt.regions[ri].fired = false
		rt.fire_region(ri)
		var e := await _wait_radio(battle, func(x): return x.text == want.get("text", "?"))
		_expect(not e.is_empty() and e.sender == ES2CommandRadio.INSTRUCTOR_SPEAKER,
			"es2 training: region message spoken by the instructor")
		_expect(str(want.get("voice", "")) != "" and Sfx.stream(str(want.voice)) != null, "es2 training: voice clip loads")
	_check_filter(battle, "es2 training")
	await _end_battle(battle)


static func _first_message_region(rt: MissionRuntimeES2) -> int:
	for ri in rt.regions.size():
		if int(rt.regions[ri].def.get("message", 0)) > 0:
			return ri
	return -1


func _check_es2_wingman() -> void:
	var mdef := MissionCompiler.load_mission(ES2_CAMPAIGN, PackedInt32Array(), 1, -1, {"resolve_texts": true})
	var battle := await _start_battle({"mission": mdef, "roster": _roster("es2:OUTLAW")})
	await _check_wingman_kill(battle, "es2", "es2 campaign")
	await _end_battle(battle)


func _check_starsiege() -> void:
	var battle := await _start_battle({"mission_name": SS_MISSION, "roster": _roster("starsiege:pi_eman")})
	var ms = battle.mission
	var key := _speaker_tagged_string(ms.vm.strings)
	_expect(key != "", "starsiege: a speaker-tagged string")
	if key != "":
		var want := SSRadio.make_line(str(ms.vm.strings[key]), "", "")
		ms.ss_builtin("say", [0, 0, key])
		var e := await _wait_radio(battle, func(x): return x.text == want.text)
		_expect(not e.is_empty() and e.sender == want.speaker and e.sender != "", "starsiege: tagged line has its speaker")
	var ai := _first_ai_object(ms)
	_expect(ai > 0, "starsiege: an AI vehicle to speak")
	if ai > 0:
		ms.ss_builtin("say", [0, ai, OWN_TEXT])
		var e2 := await _wait_radio(battle, func(x): return x.text == OWN_TEXT)
		_expect(not e2.is_empty() and e2.sender == str(ms.objs[ai].node.display_name), "starsiege: who names the speaker")
	_check_filter(battle, "starsiege")
	await _end_battle(battle)


static func _speaker_tagged_string(strings: Dictionary) -> String:
	for k in strings:
		var line := SSRadio.make_line(str(strings[k]), "", "")
		if str(k).begins_with("IDSTR_H") and line.speaker != "":
			return str(k)
	return ""


static func _first_ai_object(ms) -> int:
	for id in ms.objs:
		var n = ms.objs[id].node
		if ms.objs[id].kind in ["herc", "tank", "flyer"] and n != null and is_instance_valid(n) and n.has_meta("ai"):
			return int(id)
	return 0
