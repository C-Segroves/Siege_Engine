class_name PartyClient
extends Node
## The local pilot's membership of one party: talks to the party service (the master server or a LAN party host, base URL
## `base`) with small POST requests and polls its state once a second. A node of the scene root (PartySession), so it keeps
## polling while a screen changes or a raid is played; the party screen only shows `view`.
##   create(base, name, summary) / join(base, code, name, summary)  -> changed
##   set_ready / set_summary / set_destination / say / go / return_to_party / kick / leave
## `go_received(destination, size)` fires once per Go of the leader (also for the leader himself).

signal changed
signal go_received(destination: Dictionary, size: int)
signal failed(reason: String)
signal ended(reason: String)

const POLL_SECONDS := 1.0
const MAX_POLL_FAILURES := 15
const REQUEST_TIMEOUT_SECONDS := 4.0

var base := ""
## True when the party service is a pilot's LAN party host (PartyLanHost), false for the master server.
var lan := false
var code := ""
var key := ""
## The last view the service sent (PartyRegistry.make_view); {} outside a party.
var view := {}
## Every chat line received since joining: [{seq, name, text}].
var chat: Array = []
var _chat_seq := 0
var _go_seen := 0
var _wait := 0.0
var _polling := false
var _failures := 0
var _active := false


func is_in_party() -> bool:
	return _active and code != ""


func am_leader() -> bool:
	return is_in_party() and int(view.get("leader", -1)) == int(view.get("you", -2))


func my_id() -> int:
	return int(view.get("you", 0))


## The party's members as the service sent them: [{id, name, ready, summary, in_raid, leader}].
func members() -> Array:
	return view.get("members", [])


func destination() -> Dictionary:
	return view.get("destination", {})


## The LAN party hosts' kind of base URL: "http://ip:port".
static func make_base_url(host: String, port: int) -> String:
	return "http://%s:%d" % [host, port]


# ------------------------------------------------------------------ joining

func create(p_base: String, pilot_name: String, summary: String) -> void:
	_enter(p_base)
	_post("/party/create", {"name": pilot_name, "summary": summary}, _on_entered)


func join(p_base: String, p_code: String, pilot_name: String, summary: String) -> void:
	_enter(p_base)
	_post("/party/join", {"code": p_code, "name": pilot_name, "summary": summary}, _on_entered)


func _enter(p_base: String) -> void:
	_reset()
	base = p_base.rstrip("/")


func _on_entered(code_http: int, data: Variant) -> void:
	if code_http != 200 or not data is Dictionary or not bool(data.get("ok", false)):
		var reason := _make_reason(code_http, data)
		_reset()
		failed.emit(reason)
		return
	code = str(data.code)
	key = str(data.key)
	_active = true
	_wait = POLL_SECONDS
	_take_view(data)


# ------------------------------------------------------------------ actions

func set_ready(on: bool) -> void:
	_act("/party/ready", {"ready": on})


func set_summary(text: String) -> void:
	_act("/party/summary", {"summary": text})


## Leader: where the party goes ({address, name, mode, map, password}).
func set_destination(destination_info: Dictionary) -> void:
	_act("/party/destination", {"destination": destination_info})


func say(text: String) -> void:
	_act("/party/say", {"text": text})


## Leader: everybody is told to connect (the service refuses unless all are ready).
func go() -> void:
	_act("/party/go", {})


## A member is back from the raid and is in the party again.
func return_to_party() -> void:
	_act("/party/back", {})


func kick(member_id: int) -> void:
	_act("/party/kick", {"target": member_id})


func leave() -> void:
	if is_in_party():
		_post("/party/leave", _make_body({}), func(_c: int, _d: Variant) -> void: pass)
	_reset()
	ended.emit("You left the party.")


func _act(path: String, extra: Dictionary) -> void:
	if not is_in_party():
		return
	_post(path, _make_body(extra), _on_acted)


func _on_acted(code_http: int, data: Variant) -> void:
	if not _active:
		return
	if code_http == 200 and data is Dictionary:
		_take_view(data)
	else:
		_after_failure(code_http, data)


func _make_body(extra: Dictionary) -> Dictionary:
	var body := {"code": code, "key": key, "chat": _chat_seq}
	body.merge(extra)
	return body


# ------------------------------------------------------------------ polling

func _process(delta: float) -> void:
	if not is_in_party() or _polling:
		return
	_wait -= delta
	if _wait <= 0.0:
		_wait = POLL_SECONDS
		_polling = true
		_post("/party/state", _make_body({}), _on_polled)


func _on_polled(code_http: int, data: Variant) -> void:
	_polling = false
	if not _active:
		return
	if code_http == 200 and data is Dictionary:
		_failures = 0
		_take_view(data)
	elif code_http == 403 or code_http == 404:
		_end(_make_reason(code_http, data))
	else:
		_failures += 1
		if _failures >= MAX_POLL_FAILURES:
			_end("Lost the party service at %s." % base)


func _after_failure(code_http: int, data: Variant) -> void:
	if code_http == 403 or code_http == 404:
		_end(_make_reason(code_http, data))
	else:
		failed.emit(_make_reason(code_http, data))
		_take_if_view(data)


func _take_if_view(data: Variant) -> void:
	if data is Dictionary and data.has("members"):
		_take_view(data)


func _take_view(data: Dictionary) -> void:
	view = data
	for line in data.get("chat", []):
		if int(line.seq) > _chat_seq:
			_chat_seq = int(line.seq)
			chat.append(line)
	var go_info: Dictionary = data.get("go", {})
	if int(go_info.get("seq", 0)) > _go_seen:
		_go_seen = int(go_info.seq)
		go_received.emit(go_info.get("destination", {}), int(go_info.get("size", 1)))
	changed.emit()


func _end(reason: String) -> void:
	_reset()
	ended.emit(reason)


func _reset() -> void:
	_active = false
	code = ""
	key = ""
	view = {}
	chat = []
	_chat_seq = 0
	_go_seen = 0
	_failures = 0
	_polling = false


func _post(path: String, body: Dictionary, done: Callable) -> void:
	JsonHttp.send(self, HTTPClient.METHOD_POST, base + path, body, PackedStringArray(), func(http_code: int, data: Variant, _ms: int) -> void:
		done.call(http_code, data), REQUEST_TIMEOUT_SECONDS)


static func _make_reason(http_code: int, data: Variant) -> String:
	if data is Dictionary and str(data.get("error", "")) != "":
		return str(data.error).left(1).to_upper() + str(data.error).substr(1) + "."
	return "No answer from the party service." if http_code == 0 else "The party service answered %d." % http_code
