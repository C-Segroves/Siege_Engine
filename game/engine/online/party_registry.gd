class_name PartyRegistry
extends RefCounted
## The book of parties of a party service (the master server, or one pilot's LAN party host, PartyLanHost). A party is
## a short-lived group of pilots who ready up together and then go to one game server together (PartyFlow). Pure logic
## (no sockets; the caller passes the clock in seconds) so it can be checked without a network. Everything is kept in
## memory only: no accounts, no names beyond what a member typed, nothing written to disk; a party that nobody touched for
## IDLE_SECONDS, and a member who stopped asking for MEMBER_TIMEOUT_SECONDS, are forgotten.
##   answer(path, body, ip, now)   one request of the party API -> {code, body}
## Routes (all POST, JSON; every answer of a member's request carries the party's view):
##   /party/create   {name, summary, max}                       -> {ok, code, key, you, view...}
##   /party/join     {code, name, summary}
##   /party/state    {code, key, chat}                          the poll: the view, the chat lines after `chat`
##   /party/ready    {code, key, ready}                         the member's ready flag
##   /party/summary  {code, key, summary}                       the member's operator summary line
##   /party/destination {code, key, destination}                leader only: where the party goes (address, name, mode, map, password)
##   /party/go       {code, key}                                leader only, when everybody is ready: every member is told to connect
##   /party/say      {code, key, text}                          a chat line
##   /party/back     {code, key}                                a member is back from the raid
##   /party/kick     {code, key, target}                        leader only
##   /party/leave    {code, key}
## A member is known by a random `key` only he and the service know (a clean way to tell members apart, not a password).

const CODE_LENGTH := 5
## No 0/O, 1/I/L: a code is read aloud and typed.
const CODE_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
const DEFAULT_MAX_PARTIES := 256
const DEFAULT_MAX_MEMBERS := 8
const MIN_MEMBERS := 1
const MAX_PER_IP := 12
## A member's PC may stand still for a minute while it builds a big map, so it is forgotten only after a long silence.
const MEMBER_TIMEOUT_SECONDS := 180.0
const IDLE_SECONDS := 1800.0
const MAX_CHAT_LINES := 40
const MAX_CHAT_TEXT := 160
const MAX_NAME := 24
const MAX_SUMMARY := 80
const MAX_ADDRESS := 120
const MAX_FIELD := 40
const RATE_WINDOW_SECONDS := 60.0
const DEFAULT_RATE_LIMIT := 900   # requests per address per window: a household polls once a second per member
const KEY_BYTES := 8
const CHAT_NAME_SYSTEM := ""

var max_parties := DEFAULT_MAX_PARTIES
var rate_limit := DEFAULT_RATE_LIMIT
var _parties := {}   # code -> party Dictionary
var _hits := {}      # ip -> {start, count}
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


# ------------------------------------------------------------------ request entry

## True when `ip` may make another request now (a fixed window per address).
func allow(ip: String, now: float) -> bool:
	var h: Dictionary = _hits.get(ip, {"start": now, "count": 0})
	if now - float(h.start) >= RATE_WINDOW_SECONDS:
		h = {"start": now, "count": 0}
	h.count += 1
	_hits[ip] = h
	if _hits.size() > max_parties * 8:
		for k in _hits.keys():
			if now - float(_hits[k].start) >= RATE_WINDOW_SECONDS:
				_hits.erase(k)
	return int(h.count) <= rate_limit


## True for a path of the party API.
static func is_party_path(path: String) -> bool:
	return path.begins_with("/party/")


## Answers one request. `body` is the parsed JSON (anything); `ip` the address the connection came from.
func answer(path: String, body: Variant, ip: String, now: float) -> Dictionary:
	purge(now)
	if not body is Dictionary:
		return _fail(400, "body must be a JSON object")
	match path:
		"/party/create":
			return _create(body, ip, now)
		"/party/join":
			return _join(body, now)
	var found := _find_member(body, now)
	if found.has("error"):
		return found.error
	var party: Dictionary = found.party
	var member: Dictionary = found.member
	match path:
		"/party/state":
			return _ok(party, member, int(body.get("chat", 0)))
		"/party/ready":
			member.ready = body.get("ready", false) == true or _is_leader(party, member)
		"/party/summary":
			member.summary = MasterRegistry.make_clean_text(body.get("summary", ""), MAX_SUMMARY)
		"/party/destination":
			if not _is_leader(party, member):
				return _fail(403, "only the leader chooses the destination")
			party.destination = make_clean_destination(body.get("destination", {}))
		"/party/go":
			var refused := _apply_go(party, member, now)
			if refused != "":
				return _fail(409, refused)
		"/party/say":
			_add_chat(party, str(member.name), MasterRegistry.make_clean_text(body.get("text", ""), MAX_CHAT_TEXT))
		"/party/back":
			member.in_raid = false
			member.ready = _is_leader(party, member)
		"/party/kick":
			var refused_kick := _apply_kick(party, member, int(body.get("target", 0)))
			if refused_kick != "":
				return _fail(403, refused_kick)
		"/party/leave":
			_remove_member(party, member)
			return {"code": 200, "body": {"ok": true}}
		_:
			return _fail(404, "not found")
	return _ok(party, member, int(body.get("chat", 0)))


# ------------------------------------------------------------------ creating and joining

func _create(body: Dictionary, ip: String, now: float) -> Dictionary:
	if _parties.size() >= max_parties:
		return _fail(503, "the service holds no more parties")
	if _count_for_ip(ip) >= MAX_PER_IP:
		return _fail(429, "too many parties from this address")
	var party := {"code": _make_code(), "ip": ip, "touched": now, "leader": 0, "next_id": 1, "members": [],
		"destination": {}, "go": {"seq": 0, "destination": {}, "size": 0}, "chat": [], "chat_seq": 0,
		"max": clampi(int(body.get("max", DEFAULT_MAX_MEMBERS)), MIN_MEMBERS, DEFAULT_MAX_MEMBERS)}
	_parties[party.code] = party
	var member := _add_member(party, body, now)
	party.leader = member.id
	member.ready = true
	_add_chat(party, CHAT_NAME_SYSTEM, "%s created the party." % member.name)
	return _ok(party, member, 0, {"created": true})


func _join(body: Dictionary, now: float) -> Dictionary:
	var party: Dictionary = _parties.get(make_clean_code(body.get("code", "")), {})
	if party.is_empty():
		return _fail(404, "no party with that code")
	if (party.members as Array).size() >= int(party.max):
		return _fail(409, "the party is full")
	var member := _add_member(party, body, now)
	party.touched = now
	_add_chat(party, CHAT_NAME_SYSTEM, "%s joined." % member.name)
	return _ok(party, member, 0)


func _add_member(party: Dictionary, body: Dictionary, now: float) -> Dictionary:
	var member := {"id": int(party.next_id), "key": _make_key(), "seen": now, "ready": false, "in_raid": false,
		"name": MasterRegistry.make_clean_text(body.get("name", ""), MAX_NAME),
		"summary": MasterRegistry.make_clean_text(body.get("summary", ""), MAX_SUMMARY)}
	if member.name == "":
		member.name = "Pilot %d" % member.id
	party.next_id = int(party.next_id) + 1
	(party.members as Array).append(member)
	return member


func _make_code() -> String:
	while true:
		var code := ""
		for i in CODE_LENGTH:
			code += CODE_ALPHABET[_rng.randi() % CODE_ALPHABET.length()]
		if not _parties.has(code):
			return code
	return ""


func _make_key() -> String:
	var key := ""
	for i in KEY_BYTES:
		key += "%02x" % (_rng.randi() % 256)
	return key


## "k7qwm " -> "K7QWM" (only the code alphabet is kept, so a typo with a space or a dash still finds the party).
static func make_clean_code(raw: Variant) -> String:
	var out := ""
	for ch in str(raw).to_upper():
		if CODE_ALPHABET.contains(ch):
			out += ch
	return out.left(CODE_LENGTH)


# ------------------------------------------------------------------ members and the leader

func _find_member(body: Dictionary, now: float) -> Dictionary:
	var party: Dictionary = _parties.get(make_clean_code(body.get("code", "")), {})
	if party.is_empty():
		return {"error": _fail(404, "no party with that code")}
	for m in party.members:
		if str(m.key) == str(body.get("key", "")) and str(m.key) != "":
			m.seen = now
			party.touched = now
			return {"party": party, "member": m}
	return {"error": _fail(403, "you are not in that party")}


static func _is_leader(party: Dictionary, member: Dictionary) -> bool:
	return int(party.leader) == int(member.id)


func _remove_member(party: Dictionary, member: Dictionary) -> void:
	(party.members as Array).erase(member)
	_add_chat(party, CHAT_NAME_SYSTEM, "%s left." % member.name)
	if (party.members as Array).is_empty():
		_parties.erase(party.code)
		return
	if _is_leader(party, member):
		var next: Dictionary = party.members[0]
		party.leader = next.id
		next.ready = true
		_add_chat(party, CHAT_NAME_SYSTEM, "%s is the leader now." % next.name)


func _apply_kick(party: Dictionary, leader: Dictionary, target_id: int) -> String:
	if not _is_leader(party, leader):
		return "only the leader removes members"
	if target_id == int(leader.id):
		return "the leader cannot be removed"
	for m in party.members:
		if int(m.id) == target_id:
			_remove_member(party, m)
			return ""
	return "no such member"


## The leader presses Go: refused (with the reason) unless a destination is chosen and everybody is ready.
func _apply_go(party: Dictionary, leader: Dictionary, now: float) -> String:
	if not _is_leader(party, leader):
		return "only the leader presses Go"
	if (party.destination as Dictionary).is_empty():
		return "choose a destination first"
	var waiting := make_waiting_names(party)
	if not waiting.is_empty():
		return "waiting for %s" % ", ".join(waiting)
	var go: Dictionary = party.go
	go.seq = int(go.seq) + 1
	go.destination = (party.destination as Dictionary).duplicate(true)
	go.size = (party.members as Array).size()
	for m in party.members:
		m.in_raid = true
		m.ready = _is_leader(party, m)   # back from the raid, everybody readies up again
	_add_chat(party, CHAT_NAME_SYSTEM, "Go! Heading to %s." % str(go.destination.get("name", go.destination.get("address", "the server"))))
	party.touched = now
	return ""


## Names of the members who are not ready (or still away on the last trip).
static func make_waiting_names(party: Dictionary) -> Array:
	var out := []
	for m in party.members:
		if not bool(m.ready) or bool(m.in_raid):
			out.append(str(m.name))
	return out


# ------------------------------------------------------------------ chat

func _add_chat(party: Dictionary, sender: String, text: String) -> void:
	if text == "":
		return
	party.chat_seq = int(party.chat_seq) + 1
	(party.chat as Array).append({"seq": party.chat_seq, "name": sender, "text": text})
	while (party.chat as Array).size() > MAX_CHAT_LINES:
		(party.chat as Array).pop_front()


# ------------------------------------------------------------------ views

func _ok(party: Dictionary, member: Dictionary, chat_after: int, extra := {}) -> Dictionary:
	var body := make_view(party, member, chat_after)
	body.merge(extra)
	return {"code": 200, "body": body}


## What a member sees: the members (never their keys), the destination, the Go counter and the chat after `chat_after`.
static func make_view(party: Dictionary, member: Dictionary, chat_after: int) -> Dictionary:
	var members := []
	for m in party.members:
		members.append({"id": m.id, "name": m.name, "ready": m.ready, "summary": m.summary, "in_raid": m.in_raid,
			"leader": int(m.id) == int(party.leader)})
	var lines := (party.chat as Array).filter(func(l: Dictionary) -> bool: return int(l.seq) > chat_after)
	return {"ok": true, "code": party.code, "key": member.key, "you": member.id, "leader": party.leader, "max": party.max,
		"members": members, "destination": party.destination, "go": party.go, "chat": lines, "chat_seq": party.chat_seq,
		"waiting": make_waiting_names(party)}


## Only the known destination fields, each a short clean string.
static func make_clean_destination(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {}
	var address := MasterRegistry.make_clean_text(raw.get("address", ""), MAX_ADDRESS)
	if address == "" or " " in address:
		return {}
	return {"address": address, "name": MasterRegistry.make_clean_text(raw.get("name", ""), MAX_FIELD),
		"mode": MasterRegistry.make_clean_text(raw.get("mode", ""), MAX_FIELD),
		"map": MasterRegistry.make_clean_text(raw.get("map", ""), MAX_FIELD),
		"password": MasterRegistry.make_clean_text(raw.get("password", ""), MAX_FIELD)}


# ------------------------------------------------------------------ housekeeping

## Forgets silent members and idle parties.
func purge(now: float) -> void:
	for code in _parties.keys():
		var party: Dictionary = _parties[code]
		if now - float(party.touched) > IDLE_SECONDS:
			_parties.erase(code)
			continue
		for m in (party.members as Array).duplicate():
			if now - float(m.seen) > MEMBER_TIMEOUT_SECONDS and _parties.has(code):
				_remove_member(party, m)


func size() -> int:
	return _parties.size()


## The party `code` (a copy), {} when unknown.
func find(code: String) -> Dictionary:
	return (_parties.get(make_clean_code(code), {}) as Dictionary).duplicate(true)


## [{code, members, max, leader name}] of every party (the LAN host announces its one party with it).
func make_summaries() -> Array:
	var out := []
	for code in _parties:
		var party: Dictionary = _parties[code]
		var leader_name := ""
		for m in party.members:
			if int(m.id) == int(party.leader):
				leader_name = str(m.name)
		out.append({"code": code, "members": (party.members as Array).size(), "max": party.max, "leader": leader_name})
	return out


func _count_for_ip(ip: String) -> int:
	return _parties.values().filter(func(p: Dictionary) -> bool: return p.ip == ip).size()


static func _fail(code: int, why: String) -> Dictionary:
	return {"code": code, "body": {"ok": false, "error": why}}
