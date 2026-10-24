extends Node
## A dedicated extraction server on Katabatic (docs/SERVER_DEPLOY.md "Extraction servers"), end to end on this machine: this process IS the
## server (a DedicatedServer in mode "extraction" with fast timers), the raiders are client processes (tests/dedicated_client.tscn).
##   1. nobody is there: no world is simulated. Raider A joins and readies: the world opens, A is dropped in by transport.
##   2. Raider B joins later, while A is in the raid (join in progress): B builds the battle, is sent the world, drops in on his
##      own transport; both see each other; they are on different teams.
##   3. A is extracted (the server extracts him) and B is killed: each gets his result, the results screen, and leaves.
##   4. Nobody is left: the world closes after raid_empty_seconds (a reset). Raider C joins: a new world opens and he drops in.
## Needs the game data next to game/ (Tribes 2). Uses ports 47780 (game) and 47782 (match list); run it alone.
##   godot --headless --audio-driver Dummy --path game res://tests/dedicated_extraction_check.tscn
## Prints "dedicated_extraction_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const PORT := 47780
const LIST_PORT := 47782
const EMPTY_SECONDS := 8.0
const START_SECONDS := 150.0
const LAND_SECONDS := 300.0
const RESULT_SECONDS := 90.0
const DISCONNECT_SECONDS := 100.0   # a client that is killed, not closed, is dropped after ENet's peer timeout (Net.PEER_TIMEOUT_MAX_MS)
const CLIENT_SCENE := "res://tests/dedicated_client.tscn"
const PROTECTION_SECONDS := 100000.0

var _failures := 0
var _server: DedicatedServer
var _raid: RaidServer
var _children: Array[TestProcess] = []
var _protecting := true


func _ready() -> void:
	await _run()
	for p in _children:
		p.poll()
		if _failures > 0:
			print("  client %d output (last lines):\n    %s" % [p.pid, "\n    ".join(PackedStringArray(p.lines.filter(func(l: String) -> bool: return l.begins_with("DXC ") or "ERROR" in l).slice(-12)))])
		var context := p.find_context("SCRIPT ERROR")
		if not context.is_empty():
			print("  first script error of client %d:\n    %s" % [p.pid, "\n    ".join(PackedStringArray(context))])
		p.kill()
	print("dedicated_extraction_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> bool:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1
	return ok


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		for p in _children:
			p.poll()
		if _protecting:
			DedicatedFixture.apply_protection(_raid, PROTECTION_SECONDS)
		if cond.call():
			return true
		await get_tree().create_timer(0.2).timeout
	return cond.call()


func _start_server() -> bool:
	_server = load("res://server/dedicated_server.tscn").instantiate()
	_server.autostart = false
	_server.cfg = ServerConfig.DEFAULTS.duplicate()
	_server.cfg.merge({"name": "DXC server", "port": PORT, "list_port": LIST_PORT, "mode": "extraction", "map": "Katabatic", "max_players": 8,
		"bots": 2, "ai": 0, "raid_fast": 1, "raid_empty_seconds": EMPTY_SECONDS, "party_wait_seconds": 6.0, "results_hold_seconds": 2.0,
		"stats_seconds": 0.0}, true)
	add_child(_server)
	_server.start()
	_raid = _server.get_node_or_null("RaidServer") as RaidServer
	return _raid != null and Net.is_host() and Net.dedicated


func _start_client(pilot: String, extra: Array = []) -> TestProcess:
	var p := TestProcess.start(CLIENT_SCENE, ["--name=%s" % pilot, "--port=%d" % PORT] + extra)
	if p != null:
		_children.append(p)
	return p


func _peer_of(pilot: String) -> int:
	for peer in Net.roster:
		if str(Net.roster[peer].get("name", "")) == pilot:
			return int(peer)
	return 0


func _run() -> void:
	if not _expect(_start_server(), "the extraction server starts (mode %s)" % ServerConfig.MODES[2]):
		return
	await get_tree().create_timer(1.0).timeout
	_expect(_raid.phase == RaidServer.Phase.IDLE and _raid.battle == null, "no world is simulated while nobody is there")
	_expect(Net.settings.mode == "extraction" and str(Net.settings.map).contains("Katabatic"), "the lobby settings say extraction on Katabatic (%s)" % Net.settings.get("map"))
	var a := _start_client("DxcA")
	var b: TestProcess
	if not _expect(a != null, "raider A starts"):
		return
	_expect(await _wait_for(func() -> bool: return a.has_line("DXC DxcA JOINED"), START_SECONDS), "A joined the server")
	_expect(await _wait_for(func() -> bool: return _raid.phase == RaidServer.Phase.OPEN and is_instance_valid(_raid.battle), START_SECONDS),
		"A's Ready opens the world")
	var battle := _raid.battle
	var first_world_id := battle.get_instance_id()
	_expect(bool(battle.config.get("persistent", false)) and ExtractionRules.is_extraction(battle.config), "the world is a persistent extraction raid")
	_expect(await _wait_for(func() -> bool: return a.has_line("DXC DxcA LANDED"), LAND_SECONDS), "A dropped in and landed (%s)" % [a.find_line("DXC DxcA FAILED")])
	_expect(battle.extraction.make_raid_peers().size() == 1, "the raid has one raider")
	# B joins a raid that is running
	b = _start_client("DxcB")
	_expect(await _wait_for(func() -> bool: return b.has_line("DXC DxcB BATTLE late"), START_SECONDS), "B was sent into the running raid (late join)")
	_expect(await _wait_for(func() -> bool: return b.has_line("DXC DxcB LANDED"), LAND_SECONDS), "B dropped in and landed (%s)" % [b.find_line("DXC DxcB FAILED")])
	var peer_a := _peer_of("DxcA")
	var peer_b := _peer_of("DxcB")
	_expect(_raid.pilots.size() == 2 and _raid.pilots[peer_a].entry.team != _raid.pilots[peer_b].entry.team, "A and B are on different teams")
	_expect(await _wait_for(func() -> bool: return _sees_both(a) and _sees_both(b), 30.0), "each raider sees the other (A: %s | B: %s)" % [_last_sees(a), _last_sees(b)])
	_expect(not a.has_line("DXC DxcA FAILED") and not b.has_line("DXC DxcB FAILED"), "no raider reported a failure")
	# one extracts, one dies
	var soldier_b := battle.occupancy.soldier_of(peer_b)
	_protecting = false
	battle.extraction.apply_extract(peer_a)
	soldier_b.spawn_protection = 0.0
	soldier_b.apply_spawn_protection()
	soldier_b.apply_hit(0.0, 1.0e6, null, soldier_b.global_position)
	_expect(await _wait_for(func() -> bool: return a.has_line("DXC DxcA RESULT extracted"), RESULT_SECONDS), "A got the extraction result")
	_expect(await _wait_for(func() -> bool: return b.has_line("DXC DxcB RESULT dead"), RESULT_SECONDS), "B got the death result")
	_expect(await _wait_for(func() -> bool: return a.has_line("DXC DxcA RESULTS EXTRACTED"), RESULT_SECONDS), "A's results screen says EXTRACTED")
	_expect(await _wait_for(func() -> bool: return b.has_line("DXC DxcB RESULTS KILLED IN ACTION"), RESULT_SECONDS), "B's results screen says KILLED IN ACTION")
	_expect(await _wait_for(func() -> bool: return _raid.pilots.is_empty() and Net.roster.is_empty(), 30.0), "both left the server after their results")
	# nobody is left: the world resets
	_expect(await _wait_for(func() -> bool: return _raid.phase == RaidServer.Phase.IDLE and not is_instance_id_valid(first_world_id), EMPTY_SECONDS * 4.0 + 10.0),
		"the empty world is closed after raid_empty_seconds")
	await get_tree().create_timer(2.0).timeout
	# a new world for the next raider
	var c := _start_client("DxcC")
	_expect(await _wait_for(func() -> bool: return c.has_line("DXC DxcC LANDED"), START_SECONDS + LAND_SECONDS), "C opened a new world and dropped in")
	var second := _raid.battle
	_expect(is_instance_valid(second) and second.get_instance_id() != first_world_id and second.extraction.containers.size() > 0, "the new world is a fresh raid with caches")
	c.kill()
	_expect(await _wait_for(func() -> bool: return _raid.pilots.is_empty(), DISCONNECT_SECONDS), "C leaving is noticed (a killed client times out)")
	_expect(await _wait_for(func() -> bool: return _raid.phase == RaidServer.Phase.IDLE, EMPTY_SECONDS * 4.0 + 10.0), "the world closes again")
	_expect(not _raid.pilots.has(_peer_of("DxcC")), "nobody is left in the raid server")


func _last_sees(p: TestProcess) -> String:
	var found := p.find_lines("DXC ")
	found = found.filter(func(l: String) -> bool: return " SEES " in l)
	return str(found.back()) if not found.is_empty() else ""


func _sees_both(p: TestProcess) -> bool:
	var line := _last_sees(p)
	return "DxcA:" in line and "DxcB:" in line
