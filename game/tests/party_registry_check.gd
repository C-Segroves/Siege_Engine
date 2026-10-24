extends Node
## The party service (docs/design/party.md section 2) without sockets: PartyRegistry's rules (create, join by code, ready, the leader's
## Go and its refusals, leader hand-over, kick, chat cursor, expiry, limits, rate limit), the master server's routes, the roster key
## helpers and how a party stays on one team (PartyRoster, TeamAssignment, MatchFlow, RaidTeams).
##   godot --headless --audio-driver Dummy --path game res://tests/party_registry_check.tscn
## Prints "party_registry_check: PASS" or "FAIL (n)"; exit code 0 / 1.

const LEADER_IP := "198.51.100.10"
const MEMBER_IP := "198.51.100.11"
const PAD_SECONDS := 5.0

var _failures := 0
var _registry := PartyRegistry.new()


func _ready() -> void:
	_check_create_and_join()
	_check_go()
	_check_leaders_and_members()
	_check_chat_and_expiry()
	_check_limits()
	_check_master_routes()
	_check_roster_helpers()
	_check_teams()
	print("party_registry_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _call(path: String, body: Dictionary, now := 100.0, ip := LEADER_IP) -> Dictionary:
	return _registry.answer(path, body, ip, now)


## A new party led by "Dad"; returns {code, key} of the leader.
func _make_party(r: PartyRegistry = null) -> Dictionary:
	var reg := r if r != null else _registry
	var made := reg.answer("/party/create", {"name": "Dad", "summary": "Light armour"}, LEADER_IP, 100.0)
	return {"code": made.body.code, "key": made.body.key}


func _join(code: String, who: String, now := 100.0) -> Dictionary:
	var joined := _call("/party/join", {"code": code, "name": who, "summary": "kit of %s" % who}, now, MEMBER_IP)
	return {"code": code, "key": joined.body.get("key", ""), "res": joined}


func _check_create_and_join() -> void:
	var lead := _make_party()
	var code: String = lead.code
	_expect(code.length() == PartyRegistry.CODE_LENGTH and not code.contains("0") and not code.contains("O"), "a party gets a short readable code (%s)" % code)
	var kid := _join(code.to_lower(), "Kid1")
	_expect(kid.res.code == 200 and kid.res.body.members.size() == 2, "a member joins by the code (typed in lower case)")
	_expect(_call("/party/join", {"code": "ZZZZZ", "name": "X"}).code == 404, "an unknown code is refused")
	var view: Dictionary = _call("/party/state", {"code": code, "key": kid.key, "chat": 0}).body
	_expect(view.leader == view.members[0].id and view.you == view.members[1].id and not view.members[1].ready, "the view names the leader and 'you'; the new member is not ready")
	_expect(not str(view).contains(lead.key), "a view never shows another member's key")
	_expect(_call("/party/state", {"code": code, "key": "nope"}).code == 403, "a wrong key is refused")


func _check_go() -> void:
	var lead := _make_party()
	var kid := _join(lead.code, "Kid1")
	var go := {"code": lead.code, "key": lead.key}
	_expect(_call("/party/go", go).code == 409 and _call("/party/go", go).body.error.contains("destination"), "Go needs a destination")
	var dest := {"address": "192.0.2.50:47700", "name": "Katabatic raid", "mode": "extraction", "map": "Katabatic", "password": ""}
	_expect(_call("/party/destination", {"code": lead.code, "key": kid.key, "destination": dest}).code == 403, "only the leader chooses the destination")
	_expect(_call("/party/destination", {"code": lead.code, "key": lead.key, "destination": {"address": "bad address"}}).body.destination.is_empty(), "a destination with spaces is not taken")
	_expect(_call("/party/destination", {"code": lead.code, "key": lead.key, "destination": dest}).body.destination.address == "192.0.2.50:47700", "the leader sets the destination")
	var refused := _call("/party/go", go)
	_expect(refused.code == 409 and refused.body.error.contains("Kid1"), "Go waits for the member who is not ready (%s)" % refused.body.get("error"))
	_expect(_call("/party/go", {"code": lead.code, "key": kid.key}).code == 409, "a member cannot press Go")
	_call("/party/ready", {"code": lead.code, "key": kid.key, "ready": true})
	var sent := _call("/party/go", go)
	_expect(sent.code == 200 and sent.body.go.seq == 1 and sent.body.go.size == 2 and sent.body.go.destination.name == "Katabatic raid", "everybody ready: Go counts up and carries the destination and the size")
	var after: Dictionary = _call("/party/state", {"code": lead.code, "key": kid.key}).body
	_expect(after.go.seq == 1 and after.members.all(func(m: Dictionary) -> bool: return m.in_raid), "the members are away on the trip")
	_expect(not after.members[1].ready and after.members[0].ready, "the ready flags are cleared (the leader's stays)")
	_expect(_call("/party/go", go).code == 409, "a second Go waits for the members to come back")
	_call("/party/back", {"code": lead.code, "key": kid.key})
	_call("/party/back", go)
	_call("/party/ready", {"code": lead.code, "key": kid.key, "ready": true})
	_expect(_call("/party/go", go).body.go.seq == 2, "after they are back and ready, Go goes again")


func _check_leaders_and_members() -> void:
	var lead := _make_party()
	var kid := _join(lead.code, "Kid1")
	var kid2 := _join(lead.code, "Kid2")
	var view: Dictionary = _call("/party/kick", {"code": lead.code, "key": lead.key, "target": 2}).body
	_expect(view.members.size() == 2 and view.members.all(func(m: Dictionary) -> bool: return m.name != "Kid1"), "the leader removes a member")
	_expect(_call("/party/state", {"code": lead.code, "key": kid.key}).code == 403, "the removed member is out")
	_expect(_call("/party/kick", {"code": lead.code, "key": kid2.key, "target": 1}).code == 403, "a member cannot remove anybody")
	_call("/party/leave", {"code": lead.code, "key": lead.key})
	var now: Dictionary = _call("/party/state", {"code": lead.code, "key": kid2.key}).body
	_expect(now.members.size() == 1 and now.leader == now.you and now.members[0].ready, "the leader leaves: the oldest member leads")
	_call("/party/leave", {"code": lead.code, "key": kid2.key})
	_expect(_registry.find(lead.code).is_empty(), "the last member leaving closes the party")


func _check_chat_and_expiry() -> void:
	var lead := _make_party()
	var kid := _join(lead.code, "Kid1")
	var said: Dictionary = _call("/party/say", {"code": lead.code, "key": kid.key, "text": "  ready when you are \u0007 "}).body
	_expect(said.chat.any(func(l: Dictionary) -> bool: return l.name == "Kid1" and l.text == "ready when you are"), "a chat line is cleaned and carries the name")
	var cursor: int = said.chat_seq
	var later: Dictionary = _call("/party/state", {"code": lead.code, "key": lead.key, "chat": cursor}).body
	_expect(later.chat.is_empty(), "the poll sends only the lines after the cursor")
	for i in PartyRegistry.MAX_CHAT_LINES + 5:
		_call("/party/say", {"code": lead.code, "key": kid.key, "text": "line %d" % i})
	_expect(_registry.find(lead.code).chat.size() == PartyRegistry.MAX_CHAT_LINES, "the chat keeps the last %d lines" % PartyRegistry.MAX_CHAT_LINES)
	var t := 100.0 + PartyRegistry.MEMBER_TIMEOUT_SECONDS + 1.0
	_call("/party/state", {"code": lead.code, "key": lead.key}, t)
	var after := _registry.find(lead.code)
	_expect(after.members.size() == 1 and after.members[0].name == "Dad", "a member who stopped asking is dropped (the party goes on)")
	_registry.purge(t + PartyRegistry.IDLE_SECONDS + PAD_SECONDS)
	_expect(_registry.find(lead.code).is_empty(), "a party nobody touched for a long time is forgotten")



func _check_limits() -> void:
	var r := PartyRegistry.new()
	r.max_parties = 3
	for i in 3:
		r.answer("/party/create", {"name": "P%d" % i}, "198.51.100.%d" % (20 + i), 100.0)
	_expect(r.answer("/party/create", {"name": "P"}, "198.51.100.99", 100.0).code == 503, "the service holds only max_parties")
	var one := PartyRegistry.new()
	for i in PartyRegistry.MAX_PER_IP:
		one.answer("/party/create", {"name": "P"}, LEADER_IP, 100.0)
	_expect(one.answer("/party/create", {"name": "P"}, LEADER_IP, 100.0).code == 429, "one address cannot make endless parties")
	var full := PartyRegistry.new()
	var made := full.answer("/party/create", {"name": "Dad", "max": 2}, LEADER_IP, 100.0)
	full.answer("/party/join", {"code": made.body.code, "name": "K1"}, MEMBER_IP, 100.0)
	_expect(full.answer("/party/join", {"code": made.body.code, "name": "K2"}, MEMBER_IP, 100.0).code == 409, "a full party refuses")
	var limited := PartyRegistry.new()
	limited.rate_limit = 5
	var allowed := 0
	for i in 8:
		allowed += 1 if limited.allow(LEADER_IP, 100.0) else 0
	_expect(allowed == 5 and limited.allow(LEADER_IP, 100.0 + PartyRegistry.RATE_WINDOW_SECONDS + 1.0), "the rate limit counts per address and window")
	_expect(_registry.answer("/party/create", [1, 2], LEADER_IP, 100.0).code == 400, "a body that is not an object is refused")


func _check_master_routes() -> void:
	var master := MasterServer.new()
	master.autostart = false
	master.parties.rate_limit = 4
	var made := master.answer({"method": "POST", "path": "/party/create", "headers": {}, "body": JSON.stringify({"name": "Dad"}), "ip": LEADER_IP})
	var body: Variant = JSON.parse_string(str(made.body))
	_expect(made.code == 200 and body is Dictionary and str(body.code).length() == PartyRegistry.CODE_LENGTH, "the master answers POST /party/create")
	_expect(master.answer({"method": "GET", "path": "/party/state", "headers": {}, "body": "", "ip": LEADER_IP}).code == 405, "the party routes are POST only")
	_expect(master.answer({"method": "GET", "path": "/servers", "headers": {}, "body": "", "ip": LEADER_IP}).code == 200, "the game list still answers")
	master.cfg.auth_token = "secret"
	var open := master.answer({"method": "POST", "path": "/party/create", "headers": {}, "body": JSON.stringify({"name": "Kid"}), "ip": MEMBER_IP})
	_expect(open.code == 200, "a party needs no token even when the master requires one to register")
	var codes := []
	for i in 6:
		codes.append(master.answer({"method": "POST", "path": "/party/state", "headers": {}, "body": "{}", "ip": "198.51.100.77"}).code)
	_expect(codes.has(429), "the party routes have a rate limit of their own")
	master.free()


func _check_roster_helpers() -> void:
	var roster := {1: {"name": "A", "party": {"id": "K7QWM", "size": 3}}, 2: {"name": "B", "party": {"id": "K7QWM", "size": 3}}, 3: {"name": "C"},
		4: {"name": "D", "party": {"id": "ZZZZZ", "size": 1}}}
	_expect(PartyRoster.make_party_id(roster[1]) == "K7QWM" and PartyRoster.make_party_id(roster[3]) == "", "the roster key names the party")
	_expect(PartyRoster.make_party_size(roster[1]) == 3 and PartyRoster.make_party_size(roster[3]) == 1, "and its size")
	var groups := PartyRoster.make_groups(roster)
	_expect(groups.size() == 1 and groups["K7QWM"].size() == 2, "only parties of two or more pilots are groups")
	_expect(RaidTeams.make_group_key(1, roster[1]) == "p:K7QWM" and RaidTeams.make_group_key(3, roster[3]) == "s:3", "a raid groups a party, a lone pilot is his own group")


func _check_teams() -> void:
	var teams := RaidTeams.new()
	var a := teams.allocate("p:K7QWM")
	var b := teams.allocate("s:9")
	_expect(a == RaidTeams.make_first_team() and b == a + 1 and teams.allocate("p:K7QWM") == a, "a group keeps its team; the next group gets the next one")
	teams.release_unused(["s:9"])
	_expect(teams.allocate("s:10") == a and teams.team_of("s:9") == b, "a group with nobody left frees its team for the next one")
	_expect(RaidTeams.make_first_team() + RaidTeams.make_slot_count() == int(ExtractionRules.data().get("faction_team_base")), "the player teams end where the factions' teams begin")
	# a team versus match puts a party on one team
	var settings := LobbySettings.make({"mode": "vs", "game_mode": {"id": "team_deathmatch", "team_based": true}, "team_count": 2})
	var roster := {}
	for i in 5:
		roster[i + 2] = {"name": "P%d" % i, "team": TeamAssignment.UNASSIGNED}
	for i in [0, 2, 4]:
		roster[i + 2]["party"] = {"id": "K7QWM", "size": 3}
	var picked := TeamAssignment.make_assign_all(roster, settings)
	_expect(picked[2] == picked[4] and picked[4] == picked[6], "Assign all keeps a party on one team")
	# free for all: a party shares a team, the others have their own
	Net.roster = roster.duplicate(true)
	MatchFlow.apply_free_for_all_teams()
	_expect(Net.roster[2].team == Net.roster[4].team and Net.roster[4].team == Net.roster[6].team and Net.roster[3].team != Net.roster[2].team \
		and Net.roster[3].team != Net.roster[5].team, "free for all: a party is one team, every other pilot has his own")
	Net.roster = {}
