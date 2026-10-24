class_name MasterRegistry
extends RefCounted
## The book of a master server: the game servers that registered, kept alive by heartbeats. Pure logic (no sockets, the
## caller passes the clock in seconds) so it can be checked without a network.
##   register(ip, body, now)   a server announces itself        -> {code, body}
##   heartbeat(ip, body, now)  it is still there, with fresh numbers
##   unregister(ip, body)      it closed
##   list(now)                 the live entries
## An entry is keyed by the address the master OBSERVES (`ip`, from the connection, never from the body: a server behind
## NAT cannot know its own) plus the port it declares. Only that same address can update or remove it. Nothing personal or
## secret is stored: name, mode, map, counts, a password-protected flag and the ports. `auth_token` (optional) is checked by the caller.

const TTL_SECONDS := 90.0
const HEARTBEAT_SECONDS := 30.0
const MAX_ENTRIES := 512
const MAX_PER_IP := 8
const RATE_WINDOW_SECONDS := 60.0
const DEFAULT_RATE_LIMIT := 60   # requests per address per window
const MAX_NAME := 48
const MAX_FIELD := 32
const MAX_PLAYERS_FIELD := 256
const TRANSPORTS := ["enet", "ws"]

var ttl := TTL_SECONDS
var rate_limit := DEFAULT_RATE_LIMIT
var _entries := {}   # "ip:port" -> entry
var _hits := {}      # ip -> {start: float, count: int}


## True when `ip` may make another request now (a fixed window per address).
func allow(ip: String, now: float) -> bool:
	var h: Dictionary = _hits.get(ip, {"start": now, "count": 0})
	if now - float(h.start) >= RATE_WINDOW_SECONDS:
		h = {"start": now, "count": 0}
	h.count += 1
	_hits[ip] = h
	if _hits.size() > MAX_ENTRIES * 4:
		_forget_old_hits(now)
	return int(h.count) <= rate_limit


func _forget_old_hits(now: float) -> void:
	for k in _hits.keys():
		if now - float(_hits[k].start) >= RATE_WINDOW_SECONDS:
			_hits.erase(k)


func register(ip: String, body: Variant, now: float) -> Dictionary:
	var entry := make_clean_entry(body)
	if entry.has("error"):
		return _fail(400, str(entry.error))
	var key := make_key(ip, int(entry.port))
	if not _entries.has(key):
		if _entries.size() >= MAX_ENTRIES:
			return _fail(503, "the list is full")
		if _count_for_ip(ip) >= MAX_PER_IP:
			return _fail(429, "too many servers from this address")
	entry["ip"] = ip
	entry["expires"] = now + ttl
	_entries[key] = entry
	return {"code": 200, "body": {"ok": true, "id": key, "ip": ip, "heartbeat_seconds": HEARTBEAT_SECONDS, "ttl_seconds": ttl}}


func heartbeat(ip: String, body: Variant, now: float) -> Dictionary:
	var entry := make_clean_entry(body)
	if entry.has("error"):
		return _fail(400, str(entry.error))
	var key := make_key(ip, int(entry.port))
	if not _entries.has(key) or float(_entries[key].expires) < now:
		_entries.erase(key)
		return _fail(404, "not registered")   # the master restarted or the entry expired: register again
	entry["ip"] = ip
	entry["expires"] = now + ttl
	_entries[key] = entry
	return {"code": 200, "body": {"ok": true}}


func unregister(ip: String, body: Variant) -> Dictionary:
	if not body is Dictionary or not _is_port(body.get("port")):
		return _fail(400, "port missing")
	var key := make_key(ip, int(body.port))
	if not _entries.erase(key):
		return _fail(404, "not registered")
	return {"code": 200, "body": {"ok": true}}


## The live entries (expired ones are dropped first), without the internal expiry; `age` = seconds since the last heartbeat.
func list(now: float) -> Array:
	purge(now)
	var out := []
	for key in _entries:
		var e: Dictionary = (_entries[key] as Dictionary).duplicate()
		e["age"] = int(round(ttl - (float(e.expires) - now)))
		e.erase("expires")
		out.append(e)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.name) < str(b.name))
	return out


func purge(now: float) -> int:
	var gone := 0
	for key in _entries.keys():
		if float(_entries[key].expires) < now:
			_entries.erase(key)
			gone += 1
	return gone


func size() -> int:
	return _entries.size()


static func make_key(ip: String, port: int) -> String:
	return "%s:%d" % [ip, port]


func _count_for_ip(ip: String) -> int:
	return _entries.values().filter(func(e: Dictionary) -> bool: return e.ip == ip).size()


static func _fail(code: int, why: String) -> Dictionary:
	return {"code": code, "body": {"ok": false, "error": why}}


static func _is_port(v: Variant) -> bool:
	return (v is int or v is float) and int(v) == float(v) and int(v) >= 1 and int(v) <= 65535


static func _is_number(v: Variant) -> bool:
	return v is int or v is float


static func _clean_text(v: Variant, max_len: int) -> String:
	if not v is String:
		return ""
	var out := ""
	for ch in (v as String).strip_edges():
		if ch.unicode_at(0) >= 32 and ch.unicode_at(0) != 127:   # no control characters
			out += ch
	return out.left(max_len)


## Validates a register / heartbeat body: only the known fields are kept, each with its type and range checked.
## Returns the clean entry, or {"error": why}.
static func make_clean_entry(body: Variant) -> Dictionary:
	if not body is Dictionary:
		return {"error": "body must be a JSON object"}
	if not _is_port(body.get("port")):
		return {"error": "port must be 1-65535"}
	var name := _clean_text(body.get("name", ""), MAX_NAME)
	if name == "":
		return {"error": "name is required"}
	var max_players: Variant = body.get("max", 0)
	var players: Variant = body.get("players", 0)
	if not _is_number(max_players) or int(max_players) < 1 or int(max_players) > MAX_PLAYERS_FIELD:
		return {"error": "max must be 1-%d" % MAX_PLAYERS_FIELD}
	if not _is_number(players) or int(players) < 0 or int(players) > int(max_players):
		return {"error": "players must be 0-max"}
	var transport := str(body.get("transport", "enet"))
	if transport not in TRANSPORTS:
		return {"error": "transport must be enet or ws"}
	var list_port: Variant = body.get("list_port", 0)
	if not _is_number(list_port) or int(list_port) < 0 or int(list_port) > 65535:
		return {"error": "list_port must be 0-65535"}
	return {"name": name, "game": _clean_text(body.get("game", ""), MAX_FIELD), "mode": _clean_text(body.get("mode", ""), MAX_FIELD),
		"map": _clean_text(body.get("map", ""), MAX_NAME), "players": int(players), "max": int(max_players),
		"password": body.get("password", false) == true, "in_game": body.get("in_game", false) == true,
		"version": _clean_text(body.get("version", ""), MAX_FIELD), "transport": transport,
		"port": int(body.port), "list_port": int(list_port)}
