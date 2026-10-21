extends Node
## Two-process LAN check of the Cybrid siege (engine/extraction/siege): the host runs the hidden chain, the client digs a
## relay with its own interact offer (RPC to the host), then sees on its own machine: the broadcast, the countdown and the
## truce, a radio fragment the host told it, the siege state with the safe area's wall, Cybrid soldiers with the made-up
## look and on its radar, a far Cybrid as a proxy, an exfil closed for good, and a siege extraction that pays its bonus.
## One command; the host role starts the client as a child process (ports 47700 / 47701 are the shared LAN test ports).
##   godot --headless --audio-driver Dummy --path game res://tests/cybrid_siege_lan.tscn
## Prints "cybrid_siege_lan[ <role>]: OK|FAILED: <why>"; exit code 0 / 1.

const PORT := 47701
const MAP := "tribes2:varuna"
const SEED := 4242
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const CONNECT_SECONDS := 30.0
const UNSTOW_SECONDS := 240.0
const STEP_SECONDS := 40.0
## The client checks what the siege shows it for this long before the host extracts it.
const EFFECTS_SECONDS := 45.0
const WARNING_SECONDS := 2.0
const SETTLE_SECONDS := 3.0
const CHILD_SECONDS := 400.0
const NEAR_TROOPER := Vector3(60.0, 0.0, 0.0)
## Far enough to be a far-bot proxy on the client (interest scoped snapshots), near enough to stay in its interest.
const FAR_TROOPER := Vector3(600.0, 0.0, 0.0)
## Where the client steps after a dig: close enough to hear the hum, too far to reach the plate.
const STEP_AWAY := Vector3(8.0, 0.0, 0.0)
const HINT_TEXT := "...the static says three words..."
const ROLE_HOST := "host"
const ROLE_CLIENT := "client"

var _role := ROLE_HOST
var _battle: Battle
var _money_before := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
	Net.player_name = "QA Siege %s" % _role.capitalize()
	Net.game_starting.connect(_on_game_starting)
	if _role == ROLE_HOST:
		BattleNetSync.packed_in_lan = true   # the far-bot proxies need the interest-scoped path a dedicated server uses
		BattleNetSync.interest_in_lan = true
		_run_host.call_deferred()
	else:
		_run_client.call_deferred()


func _on_game_starting(config: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)


func _finish(ok: bool, why := "") -> void:
	print("cybrid_siege_lan%s: %s" % ["" if _role == ROLE_HOST else " " + _role, "OK" if ok else "FAILED: " + why])
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func _is_up(soldier: Infantry) -> bool:
	return soldier != null and is_instance_valid(soldier) and soldier.alive and not soldier.stowed


func _wait_unstowed() -> bool:
	if not await _wait_for(func() -> bool: return _battle != null and _battle.extraction != null and _battle.player != null, CONNECT_SECONDS * 2.0):
		return false
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	var ok := await _wait_for(func() -> bool: return _is_up(_battle.player as Infantry), UNSTOW_SECONDS)
	if ok:
		(_battle.player as Infantry).spawn_protection = 100000.0
	return ok


# ------------------------------------------------------------------ host

func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	var pid := OS.create_process(OS.get_executable_path(), ["--headless", "--audio-driver", "Dummy", "--log-file", _log_path(), "--path",
		ProjectSettings.globalize_path("res://"), "res://tests/cybrid_siege_lan.tscn", "--", "--role=" + ROLE_CLIENT])
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		_kill(pid)
		_finish(false, "the client never joined")
		return
	for id in Net.roster:
		Net.assign_team(int(id), 0)
	Net.start_game(_make_config())
	var why := await _drive_siege()
	var client_ok := await _wait_for(func() -> bool: return not OS.is_process_running(pid), CHILD_SECONDS) and OS.get_process_exit_code(pid) == 0
	_kill(pid)
	if why == "" and not client_ok:
		why = "the client failed: " + _client_report()
	_finish(why == "", why)


static func _kill(pid: int) -> void:
	if OS.is_process_running(pid):
		OS.kill(pid)


func _make_config() -> Dictionary:
	MatchFlow.apply_extraction_roster(true)
	var cfg := MatchFlow.make_extraction_config({"world_idx": 0, "teams": true, "ai": 0, InfantryBots.CONFIG_KEY: 0})
	cfg.merge({"map": MAP, "respawn": true, ExtractionRules.FAST_CONFIG_KEY: true, "extraction_seed": SEED}, true)
	return cfg


func _client_peer() -> int:
	for id in Net.roster:
		if int(id) != 1:
			return int(id)
	return 0


## Puts the client's soldier at `p` (host side: the host's simulation is the truth) and scans once.
func _put_client(p: Vector3) -> void:
	var s := _battle.occupancy.soldier_of(_client_peer())
	s.global_position = _battle.extraction.make_ground_point(p) + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO
	_battle.extraction.siege.host.apply_tick(1.0)


## Holds the client's soldier at `p` (the relays lie on slopes where he would slide off).
func _pin_client(p: Vector3) -> void:
	var s := _battle.occupancy.soldier_of(_client_peer())
	s.global_position = _battle.extraction.make_ground_point(p) + Vector3.UP * 0.5
	s.velocity = Vector3.ZERO


## "" when the whole siege ran and reached the client; else why not.
func _drive_siege() -> String:
	if not await _wait_unstowed():
		return "the host's soldier never left the dropship"
	var client := _client_peer()
	if not await _wait_for(func() -> bool: return _is_up(_battle.occupancy.soldier_of(client)), UNSTOW_SECONDS):
		return "the client's soldier never left the dropship"
	var x := _battle.extraction
	var host := x.siege.host
	if host == null:
		return "no siege on this map"
	var guest := _battle.occupancy.soldier_of(client)   # the sites' garrisons would shoot him
	guest.spawn_protection = 100000.0
	guest.apply_spawn_protection()
	var why := await _drive_chain(x, host, client)
	if why != "":
		return why
	why = await _drive_warning(x, host, client)
	if why != "":
		return why
	return await _drive_siege_effects(x, host, client)


func _drive_chain(x: ExtractionDirector, host: SiegeHost, client: int) -> String:
	for i in 3:
		var at: Vector3 = host.relays.points[host.chain.order[i]] + Vector3(1, 0, 0)
		var dug := func() -> bool:
			_pin_client(at)
			return host.chain.progress == i + 1 or host.phase != SiegePhase.ARMED
		if not await _wait_for(dug, STEP_SECONDS):
			var cs := _battle.occupancy.soldier_of(client)
			return "the client's dig of relay %d never reached the host (band %d, soldier at %s, relay at %s)" % [i, host.relays.make_band(client), cs.global_position, at]
		_put_client(at + STEP_AWAY)
		await get_tree().create_timer(1.0).timeout
	return "" if host.phase == SiegePhase.WARNING else "three digs did not start the warning"


func _drive_warning(x: ExtractionDirector, host: SiegeHost, client: int) -> String:
	x.siege.tell_hint(client, 0, HINT_TEXT)
	await get_tree().create_timer(WARNING_SECONDS).timeout   # the client sees the countdown before it is fast-forwarded
	for i in 100:
		host.apply_tick(1.0)
		if host.phase == SiegePhase.SIEGE:
			break
	if host.phase != SiegePhase.SIEGE:
		return "the countdown never ended"
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	return ""


func _drive_siege_effects(x: ExtractionDirector, host: SiegeHost, client: int) -> String:
	var soldier := _battle.occupancy.soldier_of(client)
	var pack := SiegeSpawner.make_infantry_pack()
	var near := host.spawner._spawn_trooper(pack, "LIGHT", soldier.global_position + NEAR_TROOPER, 0.5)
	var far := host.spawner._spawn_trooper(pack, "LIGHT", soldier.global_position + FAR_TROOPER, 0.5)
	if near == null or far == null:
		return "the host could not field Cybrid troopers"
	host.spawner.spawn_wave(2)
	host.timeline.apply_tick(float(host.timeline.closings[0].at_s) - host.timeline.siege_s + 1.0)
	await get_tree().create_timer(EFFECTS_SECONDS).timeout
	x.apply_extract(client)
	return ""


# ------------------------------------------------------------------ the client

func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_unstowed():
		_finish(false, "no raid with this soldier up")
		return
	_money_before = ExtractionProfile.load_for(Net.player_name).money
	var why := await _check_as_client()
	_finish(why == "", why)


func _check_as_client() -> String:
	var x := _battle.extraction
	var siege := x.siege
	var me := _battle.player as Infantry
	for i in 3:
		if not await _wait_for(func() -> bool: return siege.my_band == SiegeRelays.Band.REACH and not siege.make_relay_offer(me).is_empty(), STEP_SECONDS * 2.0):
			return "relay %d: no 'in reach' offer arrived (band %d)" % [i, siege.my_band]
		(siege.make_relay_offer(me).apply as Callable).call()
		if not await _wait_for(func() -> bool: return siege.my_band != SiegeRelays.Band.REACH or siege.get_phase() != SiegePhase.ARMED, STEP_SECONDS):
			return "relay %d: the host never moved on" % i
	if not await _wait_for(func() -> bool: return siege.get_phase() == SiegePhase.WARNING, STEP_SECONDS):
		return "the warning never reached the client"
	var why := await _check_warning_and_siege(x, siege)
	if why != "":
		return why
	return await _check_extraction(x)


func _check_warning_and_siege(x: ExtractionDirector, siege: CybridSiege) -> String:
	if not await _wait_for(func() -> bool: return siege.get_phase() == SiegePhase.SIEGE, CHILD_SECONDS):
		return "the siege never started on the client"
	if not await _wait_for(func() -> bool: return siege.lines_shown >= 3, STEP_SECONDS):
		return "the broadcast reached the client in %d lines only" % siege.lines_shown
	if not siege.my_hints.has(0) or str(siege.my_hints[0]) != HINT_TEXT:
		return "the radio fragment the host told never arrived (%s)" % [siege.my_hints]
	var cybrid := CybridRules.make_cybrid_team()
	var tribe := x.faction_teams.keys().filter(func(t: int) -> bool: return ExtractionFactions.kind_of(str(x.faction_teams[t])) == ExtractionFactions.KIND_HUMAN)
	if tribe.size() < 2 or not TeamRelations.is_allied(tribe[0], tribe[1]) or not TeamRelations.is_hostile(cybrid, tribe[0]) or not TeamRelations.is_hostile(cybrid, x.make_player_team(multiplayer.get_unique_id())):
		return "the truce did not reach the client"
	if siege.zone_fx == null or float(siege.state.get("r", 0.0)) <= 0.0:
		return "no safe area on the client"
	if not await _wait_for(func() -> bool: return _find_looked_soldier() != null, STEP_SECONDS):
		return "no Cybrid soldier with the look on the client"
	var trooper := _find_looked_soldier()
	var me := _battle.player as Infantry
	if not await _wait_for(func() -> bool: return is_instance_valid(trooper) and RadarContacts.is_on_scope(me, trooper), STEP_SECONDS):
		return "the near Cybrid is not on the client's radar"
	if not await _wait_for(func() -> bool: return _find_cybrid_proxy() != null, STEP_SECONDS):
		return "the far Cybrid is not a radar proxy on the client"
	return ""


func _check_extraction(x: ExtractionDirector) -> String:
	if not await _wait_for(func() -> bool: return x.exfil_states.any(func(e: Dictionary) -> bool: return str(e.state) == ExtractionTransports.STATE_CLOSED), STEP_SECONDS):
		return "no closed exfil reached the client"
	if not await _wait_for(func() -> bool: return x.my_status == ExtractionDirector.STATUS_EXTRACTED, STEP_SECONDS * 2.0):
		return "the siege extraction never reached the client (%s)" % x.my_status
	var gained := ExtractionProfile.load_for(Net.player_name).money - _money_before
	var flat := int(CybridRules.section("exfil").bonus.flat)
	return "" if gained >= flat else "the client's profile gained %d cr, less than the bonus %d" % [gained, flat]


func _find_cybrid_proxy() -> RadarProxy:
	for p in get_tree().get_nodes_in_group(RadarProxy.GROUP):
		if (p as RadarProxy).team == CybridRules.make_cybrid_team() and (p as RadarProxy).alive:
			return p as RadarProxy
	return null


func _find_looked_soldier() -> Infantry:
	var team := CybridRules.make_cybrid_team()
	for v in _battle.vehicles.values():
		if is_instance_valid(v) and v is Infantry and v.team == team and CybridLook.is_applied(v) and (v as Infantry).alive:
			return v
	return null


# ------------------------------------------------------------------ the client's log

static func _log_path() -> String:
	return OS.get_cache_dir().path_join("cybrid_siege_lan_client.log")


static func _client_report() -> String:
	var out := []
	for line in FileAccess.get_file_as_string(_log_path()).split("\n"):
		if line.begins_with("cybrid_siege_lan") or line.contains("ERROR"):
			out.append(line.strip_edges())
	return " | ".join(out)
