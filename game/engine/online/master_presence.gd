class_name MasterPresence
extends Node
## Keeps this machine's hosted game listed on a master server: registers when started, sends a heartbeat every
## MasterRegistry.HEARTBEAT_SECONDS with the fresh player count (registering again when the master forgot it) and
## unregisters when stopped. The master only ever lists the game; the players connect to it directly.
## Used by a dedicated server (`master` setting) and by "Host online" (it also answers the match list on its list port).

var master := ""
var token := ""
var list_port := MatchListServer.DEFAULT_PORT
var interval := MasterRegistry.HEARTBEAT_SECONDS
## After a failed request the next try comes this soon (a stalled frame, such as loading the game data, makes a request time out).
var retry_seconds := 3.0
var registered := false
var last_error := ""
var _wait := 0.0
var _busy := false
var _stopped := false


## Starts listing on `p_master` ("host", "host:port" or a URL). `p_list_port` 0 = this game has no match list.
static func begin(parent: Node, p_master: String, p_token: String, p_list_port: int) -> MasterPresence:
	var p := MasterPresence.new()
	p.master = MasterClient.make_base_url(p_master)
	p.token = p_token
	p.list_port = p_list_port
	parent.add_child(p)
	return p


func _ready() -> void:
	_send("/register")


func _process(delta: float) -> void:
	_wait += delta
	if _wait >= interval and not _busy and not _stopped:
		_wait = 0.0
		_send("/heartbeat" if registered else "/register")


## Removes the listing now (the node frees itself); the request outlives this node.
func stop() -> void:
	if _stopped:
		return
	_stopped = true
	if registered and is_inside_tree():
		JsonHttp.send(get_tree().root, HTTPClient.METHOD_DELETE, master + "/unregister", {"port": Net.game_port}, _headers(), func(_c: int, _d: Variant, _m: int) -> void: pass)
	registered = false
	queue_free()


func _exit_tree() -> void:
	stop()


func make_body() -> Dictionary:
	var info := Net.make_match_info()
	var game: Variant = Net.settings.get("game_mode", {})
	info["game"] = str(game.get("id", "")) if game is Dictionary else str(game)
	info["version"] = Net.PROTOCOL
	info["list_port"] = list_port
	info.erase("proto")
	return info


func _headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + token]) if token != "" else PackedStringArray()


func _send(path: String) -> void:
	_busy = true
	JsonHttp.send(self, HTTPClient.METHOD_POST, master + path, make_body(), _headers(), func(code: int, data: Variant, _ms: int) -> void:
		_busy = false
		if code == 200:
			registered = true
			last_error = ""
		else:
			registered = false if code == 404 or code == 0 else registered
			last_error = str(data.get("error", "")) if data is Dictionary else "no answer from %s" % master
			if code != 404:
				_wait = maxf(_wait, interval - retry_seconds)
				push_warning("master %s: %s (%d)" % [master, last_error, code])
		if code == 404 and not _stopped:
			_send("/register"))   # the master lost this entry: announce again at once
