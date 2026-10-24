extends Node
## Parties, end to end on this machine (docs/design/party.md). This process is the infrastructure: a master server (the online party
## service) and a dedicated extraction server on Katabatic; the pilots are client processes that run the real launcher on the party
## screen (tests/party_client.tscn).
##   1. Online party: the leader creates it, two members join by its code, chat, ready up; the leader chooses the server by address
##      and presses Go: the three clients connect, are admitted as one party - one team, one transport - and drop in. One is
##      extracted, one killed, one extracted: each gets his results screen, Continue returns to the party screen, and the party is
##      still there with every member back.
##   2. LAN party: the leader hosts it on his PC (PartyLanHost, it is announced by broadcast and this process hears it), a member joins
##      by the code and the leader's address, ready, Go: both land together on the running server, one squad, one transport.
## Needs the game data next to game/ (Tribes 2). Uses ports 47720 (master), 47790 (game), 47792 (match list), 47703 (the LAN party host)
## and 47701 (LAN discovery); run it alone.
##   godot --headless --audio-driver Dummy --path game res://tests/party_check.tscn
## `-- --only=online` or `--only=lan` runs one of the two. Prints "party_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const MASTER_PORT := 47720
const GAME_PORT := 47790
const LIST_PORT := 47792
const CLIENT_SCENE := "res://tests/party_client.tscn"
const PROTECTION_SECONDS := 100000.0
const STEP_SECONDS := 90.0
const LAND_SECONDS := 420.0
const RESULT_SECONDS := 120.0
const SERVER_ADDRESS := "127.0.0.1:%d" % GAME_PORT

var _failures := 0
var _master: MasterServer
var _server: DedicatedServer
var _raid: RaidServer
var _children: Array[TestProcess] = []
var _protecting := true


func _ready() -> void:
	await _run()
	for p in _children:
		p.poll()
		if _failures > 0:
			print("  client %d output (last lines):\n    %s" % [p.pid, "\n    ".join(PackedStringArray(p.lines.filter(func(l: String) -> bool: return (l.begins_with("PTY ") and " SEES " not in l) or "ERROR" in l).slice(-24)))])
		var context := p.find_context("SCRIPT ERROR")
		if not context.is_empty():
			print("  first script error of client %d:\n    %s" % [p.pid, "\n    ".join(PackedStringArray(context))])
		p.kill()
	print("party_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
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
		if _protecting and _raid != null:
			DedicatedFixture.apply_protection(_raid, PROTECTION_SECONDS)
		if cond.call():
			return true
		await get_tree().create_timer(0.2).timeout
	return cond.call()


func _start_infrastructure() -> bool:
	_master = MasterServer.new()
	_master.autostart = false
	_master.cfg = MasterServer.DEFAULTS.duplicate()
	_master.cfg.merge({"port": MASTER_PORT, "bind": "127.0.0.1"}, true)
	add_child(_master)
	_master.start()
	_server = DedicatedFixture.start_extraction_server(self, {"name": "Party server", "port": GAME_PORT, "list_port": LIST_PORT,
		"party_wait_seconds": 15.0, "raid_empty_seconds": 180.0})
	_raid = _server.get_node_or_null("RaidServer") as RaidServer
	Net.start_discovery()
	return _raid != null and Net.is_host()


func _start_client(pilot: String, role: String, extra: Array) -> TestProcess:
	var args := ["--name=%s" % pilot, "--role=%s" % role, "--master=127.0.0.1:%d" % MASTER_PORT, "--server=%s" % SERVER_ADDRESS]
	var p := TestProcess.start(CLIENT_SCENE, args + extra)
	if p != null:
		_children.append(p)
	return p


func _code_of(p: TestProcess, pilot: String) -> String:
	var line := p.find_line("PTY %s PARTY CODE " % pilot)
	return line.get_slice(" ", 4) if line != "" else ""


func _peer_of(pilot: String) -> int:
	for peer in _raid.pilots:
		if str(_raid.pilots[peer].entry.get("name", "")) == pilot:
			return int(peer)
	return 0


func _run() -> void:
	if not _expect(_start_infrastructure(), "the master and the extraction server start"):
		return
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.get_slice("=", 1)
	if only != "lan":
		await _run_online_party()
	if only != "online":
		await _run_lan_party()


# ------------------------------------------------------------------ online party: three pilots through the master

func _run_online_party() -> void:
	print("-- online party (the master's party service)")
	var lead := _start_client("PtyLead", "leader", ["--kind=online", "--expect=3", "--no-discovery"])
	if not _expect(lead != null, "the leader starts"):
		return
	_expect(await _wait_for(func() -> bool: return _code_of(lead, "PtyLead") != "", STEP_SECONDS), "the leader created a party on the master (%s)" % [lead.find_line("PTY PtyLead FAILED")])
	var code := _code_of(lead, "PtyLead")
	_expect(not _master.parties.find(code).is_empty(), "the master holds the party %s" % code)
	var kid1 := _start_client("PtyKid1", "member", ["--kind=online", "--code=%s" % code, "--no-discovery"])
	var kid2 := _start_client("PtyKid2", "member", ["--kind=online", "--code=%s" % code, "--no-discovery"])
	_expect(await _wait_for(func() -> bool: return kid1.has_line("PTY PtyKid1 JOINED") and kid2.has_line("PTY PtyKid2 JOINED"), STEP_SECONDS), "two members joined by the code")
	_expect(await _wait_for(func() -> bool: return kid1.has_line("PTY PtyKid1 CHAT ok") and kid2.has_line("PTY PtyKid2 CHAT ok"), STEP_SECONDS), "they read the leader's chat line")
	_expect(await _wait_for(func() -> bool: return kid1.has_line("PTY PtyKid1 READY") and kid2.has_line("PTY PtyKid2 READY"), STEP_SECONDS), "they pressed Ready")
	_expect(await _wait_for(func() -> bool: return lead.has_line("PTY PtyLead MEMBERS 3"), STEP_SECONDS), "the leader sees three ready members")
	_expect(await _wait_for(func() -> bool: return lead.has_line("PTY PtyLead GO"), STEP_SECONDS), "the leader chose %s and pressed Go" % SERVER_ADDRESS)
	var all := [lead, kid1, kid2]
	_expect(await _wait_for(func() -> bool: return _all_say(all, " LANDED"), LAND_SECONDS),
		"all three dropped in from the Go (%s)" % [_failed_lines(all)])
	await _check_together(["PtyLead", "PtyKid1", "PtyKid2"], all, code, "online")
	# the raid ends for each: extracted, killed, extracted
	var battle := _raid.battle
	var peers := {"PtyLead": _peer_of("PtyLead"), "PtyKid1": _peer_of("PtyKid1"), "PtyKid2": _peer_of("PtyKid2")}
	var soldier1 := battle.occupancy.soldier_of(peers.PtyKid1)
	_protecting = false
	battle.extraction.apply_extract(peers.PtyLead)
	battle.extraction.apply_extract(peers.PtyKid2)
	soldier1.spawn_protection = 0.0
	soldier1.apply_spawn_protection()
	soldier1.apply_hit(0.0, 1.0e6, null, soldier1.global_position)
	_expect(await _wait_for(func() -> bool: return (lead.has_line("PTY PtyLead RESULTS EXTRACTED") and kid2.has_line("PTY PtyKid2 RESULTS EXTRACTED")
		and kid1.has_line("PTY PtyKid1 RESULTS KILLED IN ACTION")), RESULT_SECONDS), "the results screens: extracted, killed, extracted")
	_expect(await _wait_for(func() -> bool: return _all_say(all, " BACK 3 present"), RESULT_SECONDS),
		"Continue returns every pilot to the party screen with three members")
	var party := _master.parties.find(code)
	_expect(not party.is_empty() and party.members.size() == 3 and party.members.all(func(m: Dictionary) -> bool: return not m.in_raid),
		"the party is still on the master and nobody is away")
	_expect(await _wait_for(func() -> bool: return all.all(func(p: TestProcess) -> bool: return not p.is_running()), 30.0), "the clients finished")


## The three (or two) pilots were admitted as one group: one team on the server, and every client saw them as one squad on one transport.
func _check_together(names: Array, procs: Array, code: String, kind: String) -> void:
	await _wait_for(func() -> bool: return _all_say(procs, " TEAM "), RESULT_SECONDS)   # printed a moment after LANDED
	var teams := {}
	for n: String in names:
		var peer := _peer_of(n)
		teams[n] = int(_raid.pilots[peer].entry.team) if peer != 0 else -1
	_expect(teams.values().all(func(t: int) -> bool: return t == teams.values()[0] and t >= 0), "%s: the server put the party on one team (%s)" % [kind, teams])
	_expect(names.all(func(n: String) -> bool: return str(_raid.pilots[_peer_of(n)].group) == "p:%s" % code), "%s: the server keeps them as the group of party %s" % [kind, code])
	var sorted_names := names.duplicate()
	sorted_names.sort()
	var riders_ok := true
	var team_ok := true
	for i in procs.size():
		var line: String = (procs[i] as TestProcess).find_line("PTY %s TEAM " % names[i])
		riders_ok = riders_ok and line.ends_with("RIDERS %s" % ",".join(PackedStringArray(sorted_names)))
		team_ok = team_ok and line.begins_with("PTY %s TEAM %d " % [names[i], teams[names[i]]])
	_expect(riders_ok, "%s: every client rode the same transport with the whole party (%s)" % [kind, (procs[0] as TestProcess).find_line("PTY %s TEAM " % names[0])])
	_expect(team_ok, "%s: every client knows its team as the server does" % kind)


## True when every process printed a line containing `text`.
func _all_say(procs: Array, text: String) -> bool:
	return procs.all(func(p: TestProcess) -> bool: return p.lines.any(func(l: String) -> bool: return text in l))


func _failed_lines(procs: Array) -> String:
	var out := []
	for p: TestProcess in procs:
		out.append_array(p.find_lines("PTY ").filter(func(l: String) -> bool: return " FAILED" in l))
	return "; ".join(PackedStringArray(out))


# ------------------------------------------------------------------ LAN party: the leader's PC hosts it

func _run_lan_party() -> void:
	print("-- LAN party (hosted by the leader, found by broadcast)")
	var lead := _start_client("PtyLan", "leader", ["--kind=lan", "--expect=2", "--no-discovery"])
	_expect(await _wait_for(func() -> bool: return _code_of(lead, "PtyLan") != "", STEP_SECONDS), "the leader hosts a LAN party (%s)" % [lead.find_line("PTY PtyLan FAILED")])
	var code := _code_of(lead, "PtyLan")
	var heard := await _wait_for(func() -> bool: return Net.parties.values().any(func(p: Dictionary) -> bool: return str(p.get("code", "")) == code), 15.0)
	_expect(heard, "the LAN party is announced by broadcast (this process heard it: %s)" % [Net.parties.keys()])
	_expect(_master.parties.find(code).is_empty(), "the LAN party is not on the master")
	var kid := _start_client("PtyMate", "member", ["--kind=lan", "--code=%s" % code, "--lan-host=127.0.0.1", "--no-discovery"])
	_expect(await _wait_for(func() -> bool: return kid.has_line("PTY PtyMate JOINED 2") and kid.has_line("PTY PtyMate READY"), STEP_SECONDS), "a member joined the LAN party by its code and the leader's address and is ready")
	_expect(await _wait_for(func() -> bool: return lead.has_line("PTY PtyLan GO"), STEP_SECONDS), "the leader pressed Go")
	var all := [lead, kid]
	_expect(await _wait_for(func() -> bool: return _all_say(all, " LANDED"), LAND_SECONDS),
		"both dropped in on the running server (%s)" % [_failed_lines(all)])
	await _check_together(["PtyLan", "PtyMate"], all, code, "LAN")
	var battle := _raid.battle
	battle.extraction.apply_extract(_peer_of("PtyLan"))
	battle.extraction.apply_extract(_peer_of("PtyMate"))
	_expect(await _wait_for(func() -> bool: return _all_say(all, " BACK 2 present"), RESULT_SECONDS),
		"both are back on the LAN party screen after their results")
	_expect(await _wait_for(func() -> bool: return all.all(func(p: TestProcess) -> bool: return not p.is_running()), 30.0), "the clients finished")
