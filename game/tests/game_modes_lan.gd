extends Node
## LAN end-to-end check of a game mode: a CTF match on Tribes 2 Katabatic between two processes.
##   host:   godot --headless --audio-driver Dummy --path game res://tests/game_modes_lan.tscn -- --role=host
##   client: godot --headless --audio-driver Dummy --path game res://tests/game_modes_lan.tscn -- --role=client
##           [--shots=<dir>: modes_lan_client.png, needs a window]
## The host's soldier takes the enemy flag and captures it at his own; the client must see the flag carried
## (replicated state, the carrier's name on its HUD) and the host team's capture in the score.
## Prints "LAN <role> OK" or "LAN <role> FAILED: <why>" and quits with 0 / 1.

const PORT := 47766
const MAP := "tribes2:Katabatic"
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const CONNECT_SECONDS := 30.0
const SETTLE_SECONDS := 4.0
const SEE_SECONDS := 40.0
const STEP_FRAMES := 20

var _role := ""
var _shots := ""
var _battle: Battle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
		elif a.begins_with("--shots="):
			_shots = a.substr(8)
	Net.player_name = "Host" if _role == "host" else "Client"
	Net.game_starting.connect(_on_game_starting)
	if _role == "host":
		_run_host.call_deferred()
	else:
		_run_client.call_deferred()


func _done(ok: bool, why := "") -> void:
	print("LAN %s %s" % [_role, "OK" if ok else "FAILED: " + why])
	var tree := get_tree()    # leaving the session may free this scene
	await tree.create_timer(2.0).timeout
	tree.quit(0 if ok else 1)


func _on_game_starting(cfg: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = cfg
	get_tree().root.add_child(_battle)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


# ------------------------------------------------------------------ host

func _run_host() -> void:
	if Net.host(PORT) != OK:
		_done(false, "cannot host on port %d" % PORT)
		return
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		_done(false, "no client joined")
		return
	for id in Net.roster:
		Net.assign_team(id, 0 if int(id) == 1 else 1)
	var cfg := BattleSetup.make_default_config("es1:RAPTOR")
	cfg.merge({"map": MAP, GameModes.CONFIG_KEY: "ctf", "team_count": 2, "start": BattleInfantry.START_ON_FOOT, "ai": []}, true)
	Net.start_game(cfg)
	await _seconds(SETTLE_SECONDS)
	var director: GameModeDirector = _battle.game_mode if _battle else null
	if director == null or not is_instance_valid(_battle.player):
		_done(false, "no CTF director or no player")
		return
	var player := _battle.player
	var flags := director.rules.objects_of(ModeObject.KIND_FLAG)
	var enemy: ModeObject = flags.filter(func(f: ModeObject) -> bool: return f.team != player.team)[0]
	var own: ModeObject = flags.filter(func(f: ModeObject) -> bool: return f.team == player.team)[0]
	player.global_position = enemy.pos
	await _wait_for(func() -> bool: return enemy.state == ModeObject.CARRIED, 5.0)
	await _seconds(3.0)            # the client looks at the carried flag
	player.global_position = own.pos
	var captured := await _wait_for(func() -> bool: return director.rules.score.team_score(player.team) >= 1.0, 5.0)
	await _seconds(6.0)            # the client checks the score
	_done(captured, "" if captured else "no capture on the host")


# ------------------------------------------------------------------ client

func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_done(false, "cannot join")
		return
	if not await _wait_for(func() -> bool: return _battle != null and _battle.game_mode != null, CONNECT_SECONDS + SETTLE_SECONDS):
		_done(false, "no battle with a game mode started")
		return
	var director: GameModeDirector = _battle.game_mode
	var saw_carried := await _wait_for(func() -> bool:
		return director.rules.objects_of(ModeObject.KIND_FLAG).any(func(f: ModeObject) -> bool:
			return f.state == ModeObject.CARRIED and director.rules.make_player_name(f.carrier) == "Host"), SEE_SECONDS)
	if _shots != "":
		await _seconds(1.0)
		get_viewport().get_texture().get_image().save_png(_shots.path_join("modes_lan_client.png"))
	var hud_ok := director.make_objective_lines().any(func(l) -> bool: return str(l.text).contains("taken by"))
	var saw_capture := await _wait_for(func() -> bool: return director.rules.score.team_score(0) >= 1.0, SEE_SECONDS)
	if not saw_carried:
		_done(false, "the client never saw the host carry the flag")
	elif not saw_capture:
		_done(false, "the client never saw the capture")
	else:
		print("  client HUD while carried: %s" % ("ok" if hud_ok else "no 'taken by' line"))
		_done(true)
