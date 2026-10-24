class_name MasterServer
extends Node
## The master server ("connecting server"): a small HTTP service where game servers announce themselves and clients ask
## for the list, the way the Quake and Tribes master servers worked. It never relays game traffic and holds no game data.
##   godot --headless --audio-driver Dummy --path game res://server/master_server.tscn -- [--port=47710] [--bind=*]
##         [--auth_token=<secret>] [--ttl=90] [--rate_limit=60]
## Routes (JSON): POST /register, POST /heartbeat, DELETE /unregister (bodies as MasterRegistry.make_clean_entry),
## GET /servers, GET /health. With `auth_token` set, the three write routes need "Authorization: Bearer <token>".
## Prints "MASTER READY port=<p>"; quits with 1 when it cannot listen.

const DEFAULT_PORT := 47710
const MAX_BODY := 2048
const DEFAULTS := {"port": DEFAULT_PORT, "bind": "*", "auth_token": "", "ttl": MasterRegistry.TTL_SECONDS,
	"rate_limit": MasterRegistry.DEFAULT_RATE_LIMIT}

var cfg := DEFAULTS.duplicate()
## False: a check sets `cfg` and calls start() itself.
var autostart := true
var registry := MasterRegistry.new()
var _http := HttpServer.new()


func _ready() -> void:
	if autostart:
		cfg = ServerConfig.load_with(DEFAULTS, OS.get_cmdline_user_args())
		start.call_deferred()


func start() -> void:
	registry.ttl = float(cfg.ttl)
	registry.rate_limit = int(cfg.rate_limit)
	_http.handler = answer
	_http.max_body = MAX_BODY
	add_child(_http)
	if _http.start(int(cfg.port), str(cfg.bind)) != OK:
		print("MASTER FAILED: cannot listen on port %d" % int(cfg.port))
		get_tree().quit(1)
		return
	print("MASTER READY port=%d%s" % [int(cfg.port), " (token required to register)" if str(cfg.auth_token) != "" else ""])


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


## Answers one request (HttpServer handler); public so a check can call it without sockets.
func answer(req: Dictionary) -> Dictionary:
	var ip := str(req.ip)
	if req.method == "OPTIONS":
		return {"code": 204, "type": "text/plain", "body": ""}
	if not registry.allow(ip, now()):
		return _json(429, {"ok": false, "error": "slow down"})
	match [req.method, str(req.path)]:
		["GET", "/health"]:
			return {"code": 200, "type": "text/plain", "body": "ok"}
		["GET", "/servers"]:
			return _json(200, {"servers": registry.list(now())})
		["POST", "/register"], ["POST", "/heartbeat"], ["DELETE", "/unregister"]:
			return _write(req, ip)
	return _json(404, {"ok": false, "error": "not found"})


func _write(req: Dictionary, ip: String) -> Dictionary:
	if str(cfg.auth_token) != "" and str(req.headers.get("authorization", "")) != "Bearer " + str(cfg.auth_token):
		return _json(401, {"ok": false, "error": "this master only lists its own servers"})
	var body: Variant = JsonHttp.parse(str(req.body))
	var result: Dictionary
	match str(req.path):
		"/register":
			result = registry.register(ip, body, now())
		"/heartbeat":
			result = registry.heartbeat(ip, body, now())
		_:
			result = registry.unregister(ip, body)
	return _json(int(result.code), result.body)


static func _json(code: int, data: Dictionary) -> Dictionary:
	return {"code": code, "type": "application/json", "body": JSON.stringify(data)}
