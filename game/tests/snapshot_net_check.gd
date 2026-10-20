extends Node
## Two-process LAN check of the packed snapshot path (docs/DEDICATED_SERVER_SCALING.md chunk E): the host sends
## SnapshotCodec deltas (interest grid off, or on with --interest), the client's puppet of the host's Herc ends up
## where the host put it, and the host's per-client baseline got acknowledged. One command; the host role starts
## the client as a child process.
##   godot --headless --audio-driver Dummy --path game res://tests/snapshot_net_check.tscn [-- --interest]
## Prints "snapshot_net_check: OK|FAILED: <why>"; exit code 0 / 1.

const PORT := 47768
const CONNECT_SECONDS := 30.0
const SETTLE_SECONDS := 3.0
const NEAR_M := 50.0
const SEE_SECONDS := 20.0
const SEE_TOLERANCE_M := 3.0
const HOLD_SECONDS := 6.0
const BATTLE_SCENE := "res://games/es1/battle.tscn"

var _role := "host"
var _interest := false
var _battle: Battle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
		elif a == "--interest":
			_interest = true
	Net.player_name = _role.capitalize()
	Net.game_starting.connect(_on_game_starting)
	if _role == "host":
		BattleNetSync.packed_in_lan = true
		BattleNetSync.interest_in_lan = _interest
		_run_host.call_deferred()
	else:
		_run_client.call_deferred()


func _on_game_starting(config: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)


func _finish(ok: bool, why := "") -> void:
	print("snapshot_net_check%s: %s" % ["" if _role == "host" else " client", "OK" if ok else "FAILED: " + why])
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


static func _find_host_herc(battle: Battle) -> Herc:
	return _find_herc_of(battle, 1)


static func _find_herc_of(battle: Battle, peer: int) -> Herc:
	for h: Herc in battle.vehicles.values():
		if h.owner_peer == peer and not h.has_meta("ai"):
			return h
	return null


func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/snapshot_net_check.tscn", "--", "--role=client"]
	var pid := OS.create_process(OS.get_executable_path(), args)
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		OS.kill(pid)
		_finish(false, "the client never joined")
		return
	MatchFlow.apply_free_for_all_teams()
	Net.start_game(MatchFlow.make_match_config({"mode": "vs", "teams": false, "ai": 2, "world_idx": 0}, []))
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	var herc := _find_host_herc(_battle) if _battle else null
	if herc == null:
		OS.kill(pid)
		_finish(false, "the host has no Herc")
		return
	var partner := _find_herc_of(_battle, multiplayer.get_peers()[0])
	if partner == null:
		OS.kill(pid)
		_finish(false, "the client has no Herc")
		return
	herc.global_position = partner.global_position + Vector3(NEAR_M, 0.0, 0.0)
	print("snapshot_net_check: host Herc at %s" % herc.global_position)
	await _wait_for(_is_acknowledged, SEE_SECONDS)
	var verdict := _judge_stream()
	await _wait_for(func() -> bool: return not OS.is_process_running(pid), SEE_SECONDS)
	var client_ok := not OS.is_process_running(pid) and OS.get_process_exit_code(pid) == 0
	if OS.is_process_running(pid):
		OS.kill(pid)
	_finish(verdict == "" and client_ok, verdict if verdict != "" else "the client did not see the host's Herc")


func _is_acknowledged() -> bool:
	var sync: BattleNetSync = _battle.get_node("NetSync")
	var peers := multiplayer.get_peers()
	return sync.stream != null and not peers.is_empty() and sync.stream.make_baseline(peers[0]).has_confirmed()


## Empty when the host's stream sent packets, the client acknowledged them and no baseline went stale.
func _judge_stream() -> String:
	var sync: BattleNetSync = _battle.get_node("NetSync")
	if sync.stream == null or sync.stream.packets_sent == 0:
		return "no packed snapshot was sent"
	var peers := multiplayer.get_peers()
	if peers.is_empty() or not sync.stream.make_baseline(peers[0]).has_confirmed():
		return "the client never acknowledged a snapshot"
	if sync.stream.full_state_resets > 0:
		return "a baseline went stale %d times" % sync.stream.full_state_resets
	print("snapshot_net_check: %d packets, %d records, interest %s" % [sync.stream.packets_sent, sync.stream.records_sent,
		"on" if sync.stream.grid.enabled else "off"])
	return ""


func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_for(func() -> bool: return _battle != null and _battle.player != null and _find_host_herc(_battle) != null, CONNECT_SECONDS + SETTLE_SECONDS):
		_finish(false, "no battle with the host's Herc")
		return
	var herc := _find_host_herc(_battle)
	var mine := _battle.player
	var seen := await _wait_for(func() -> bool:
		return herc.global_position.distance_to(mine.global_position) < NEAR_M + SEE_TOLERANCE_M * 2.0, SEE_SECONDS)
	await get_tree().create_timer(HOLD_SECONDS).timeout   # stays connected while the host judges its stream
	_finish(seen, "the puppet of the host's Herc stayed at %s (mine at %s)" % [herc.global_position, mine.global_position])
