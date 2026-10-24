extends Node
## One raider for tests/dedicated_extraction_check.gd: a client process that joins a dedicated server like a pilot who pressed Ready in
## its lobby, builds the battle it is sent, drops in, and reports with "DXC <name> <what>" lines on stdout (RaidWatch). The checker (the
## server's process) extracts him or kills him and reads the lines.
##   godot --headless --audio-driver Dummy --path game res://tests/dedicated_client.tscn -- --name=DxcA --port=47780
## Lines: JOINED <mode> <map>, BATTLE start|late, then RaidWatch's lines, KICKED <why>, FAILED <why>.

const JOIN_SECONDS := 30.0
const BATTLE_SECONDS := 300.0

var _name := "DxcA"
var _port := 47780
var _battle: Battle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--name="):
			_name = a.get_slice("=", 1)
		elif a.begins_with("--port="):
			_port = int(a.get_slice("=", 1))
	Net.player_name = _name
	Net.game_starting.connect(_on_game_starting)
	Net.session_ended.connect(func(why: String) -> void: _say("KICKED %s" % why))
	_run.call_deferred()


func _say(text: String) -> void:
	print("DXC %s %s" % [_name, text])


func _on_game_starting(cfg: Dictionary) -> void:
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = cfg
	get_tree().root.add_child(_battle)
	_say("BATTLE %s" % ("late" if bool(cfg.get("late_join", false)) else "start"))


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _fail(why: String) -> void:
	_say("FAILED %s" % why)
	get_tree().quit(1)


func _run() -> void:
	if Net.join("127.0.0.1", _port) != OK:
		_fail("join")
		return
	if not await _wait_for(func() -> bool: return Net.roster.has(Net.my_id()), JOIN_SECONDS):
		_fail("no roster entry")
		return
	_say("JOINED %s %s" % [Net.settings.get("mode", ""), Net.settings.get("map", "")])
	var fields := LobbyAnnouncer.make_fields(Net.settings, OperatorProfile.load_for(_name))
	fields["ready"] = true
	Net.set_my_infos(fields)
	if not await _wait_for(func() -> bool: return _battle != null and _battle.extraction != null, BATTLE_SECONDS):
		_fail("no battle")
		return
	var watch := RaidWatch.new(_battle, _say)
	add_child(watch)
	await watch.run()
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0)
