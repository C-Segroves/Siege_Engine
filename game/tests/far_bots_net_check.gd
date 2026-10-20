extends Node
## Two-process check of client-side despawn / spawn by interest (docs/DEDICATED_SERVER_SCALING.md chunk L): the host
## (interest grid on) holds one AI Herc at 600 m from the client (FAR tier), then 40 m (NEAR), then 1500 m (out of
## interest). The client must show it as a FarBots proxy without a scene node, build the node again when it comes
## close, and then keep neither a node nor a proxy.
##   godot --headless --audio-driver Dummy --path game res://tests/far_bots_net_check.tscn
## Prints "far_bots_net_check: OK|FAILED: <why>"; exit code 0 / 1.

const PORT := 47771
const CONNECT_SECONDS := 30.0
const SETTLE_SECONDS := 3.0
const PHASE_SECONDS := 7.0
const FAR_M := 600.0
const NEAR_M := 40.0
const OUT_M := 1500.0
const CLIENT_SECONDS := 60.0
const BATTLE_SCENE := "res://games/es1/battle.tscn"

var _role := "host"
var _battle: Battle
var _held_id := 0
var _held_offset := Vector3.ZERO
var _held_origin := Vector3.ZERO
var _radar_error := ""
var _seen := {}   # client: bot id -> [proxy seen, node again, gone]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
	Net.player_name = _role.capitalize()
	Net.game_starting.connect(_on_game_starting)
	if _role == "host":
		BattleNetSync.packed_in_lan = true
		BattleNetSync.interest_in_lan = true
		_run_host.call_deferred()
	else:
		_run_client.call_deferred()


func _on_game_starting(config: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)


func _finish(ok: bool, why := "") -> void:
	print("far_bots_net_check%s: %s" % ["" if _role == "host" else " client", "OK" if ok else "FAILED: " + why])
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _physics_process(_delta: float) -> void:
	if _held_id == 0 or _battle == null or not _battle.vehicles.has(_held_id):
		return
	_battle.vehicles[_held_id].global_position = _held_origin + _held_offset


# ------------------------------------------------------------------ host

func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/far_bots_net_check.tscn", "--", "--role=client"]
	var pid := OS.create_process(OS.get_executable_path(), args)
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		OS.kill(pid)
		_finish(false, "the client never joined")
		return
	MatchFlow.apply_free_for_all_teams()
	Net.start_game(MatchFlow.make_match_config({"mode": "vs", "teams": false, "ai": 2, "world_idx": 0}, []))
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	var partner := _find_pilot_of(multiplayer.get_peers()[0])
	var bot := _find_bot()
	if partner == null or bot == null:
		OS.kill(pid)
		_finish(false, "the battle has no client Herc or no AI Herc")
		return
	_held_id = bot.net_id
	_held_origin = partner.global_position
	for offset in [Vector3(FAR_M, 0.0, 0.0), Vector3(NEAR_M, 0.0, 0.0), Vector3(OUT_M, 0.0, 0.0)]:
		_held_offset = offset
		print("far_bots_net_check: bot %d held %.0f m from the client" % [_held_id, offset.length()])
		await get_tree().create_timer(PHASE_SECONDS).timeout
	_held_id = 0
	await _wait_for(func() -> bool: return not OS.is_process_running(pid), PHASE_SECONDS * 2.0)
	var client_ok := not OS.is_process_running(pid) and OS.get_process_exit_code(pid) == 0
	if OS.is_process_running(pid):
		OS.kill(pid)
	_finish(client_ok, "the client did not see the bot go far, come back and leave")


func _find_pilot_of(peer: int) -> Herc:
	for h: Herc in _battle.vehicles.values():
		if h.owner_peer == peer and not h.has_meta("ai"):
			return h
	return null


func _find_bot() -> Herc:
	for h: Herc in _battle.vehicles.values():
		if h.has_meta("ai"):
			return h
	return null


# ------------------------------------------------------------------ client

func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_for(func() -> bool: return _battle != null and _battle.player != null and _battle.far_units != null, CONNECT_SECONDS + SETTLE_SECONDS):
		_finish(false, "no client battle")
		return
	var done := await _wait_for(_observe, CLIENT_SECONDS)
	if _radar_error != "":
		_finish(false, _radar_error)
		return
	_finish(done, "sequence per bot (proxy, node again, gone): %s; parked %d restored %d" % [_seen,
		_battle.far_units.parked_total, _battle.far_units.restored_total])


## Advances each bot's sequence; true when one bot went proxy, node, gone in that order.
func _observe() -> bool:
	var units := _battle.far_units
	for id: int in units.make_bot_ids():
		var steps: Array = _seen.get(id, [false, false, false])
		var proxy := units.is_parked(id) and units.far_bots.has(id) and not _battle.vehicles.has(id)
		var node := _battle.vehicles.has(id) and not units.is_parked(id)
		var gone := units.is_parked(id) and not units.far_bots.has(id) and not _battle.vehicles.has(id)
		if not steps[0] and proxy:
			steps[0] = true
			_radar_error = _check_radar(id)
			if _radar_error != "":
				return true
		elif steps[0] and not steps[1] and node:
			steps[1] = true
		elif steps[1] and not steps[2] and gone:
			steps[2] = true
		_seen[id] = steps
		if steps[2]:
			return true
	return false


## A far bot (600 m) is a radar contact: on the scope, on the command map, T-targetable (and promoted by it); out of
## the radar's range it is none of them. Returns "" when all hold.
func _check_radar(id: int) -> String:
	var units := _battle.far_units
	var me := _battle.player
	var c := units.make_contact(id)
	if c == null:
		return "the proxy of bot %d has no radar contact" % id
	var saved := RadarContacts.make_range(me)
	var view := CommandMapView.new()
	_battle.add_child(view)
	view.setup(_battle, me)
	var err := ""
	RadarContacts.apply_range(me, 1200.0)
	if not RadarContacts.is_on_scope(me, c):
		err = "bot at 600 m not on the radar scope"
	elif not RadarContacts.make_units(get_tree()).has(c) or not view.make_units().has(c):
		err = "bot at 600 m missing from the radar list or the command map"
	elif not Targeting.make_candidates(me).has(c):
		err = "bot at 600 m is not a T candidate"
	RadarContacts.apply_range(me, 100.0)
	if err == "" and (RadarContacts.is_on_scope(me, c) or view.make_units().has(c) or Targeting.make_candidates(me).has(c)):
		err = "bot at 600 m shows although out of the 100 m radar range"
	RadarContacts.apply_range(me, 1200.0)
	if err == "":
		var t := Targeting.promote(me, c)
		if not (t is Herc) or not _battle.vehicles.has(id) or units.is_parked(id) or units.make_contact(id) != null:
			err = "targeting the contact did not promote it to a node"
	RadarContacts.apply_range(me, saved)
	view.queue_free()
	return err
