class_name MatchListServer
extends Node
## A tiny HTTP endpoint of a dedicated server: GET /matches answers the JSON list of this server's matches
## ({"matches": [Net.make_match_info()]}); GET /health answers "ok". Nothing else is served: never game data.
## A reverse proxy (deploy/nginx-server.conf.template, deploy/Caddyfile.example) maps it next to the WebSocket path.
## CORS is open because the list holds no secret and desktop clients may read it from any page. Built on HttpServer.

const DEFAULT_PORT := 47702

var _http := HttpServer.new()


func _init() -> void:
	_http.handler = _answer
	_http.max_body = 0
	add_child(_http)


func start(port := DEFAULT_PORT, bind_address := "*") -> Error:
	return _http.start(port, bind_address)


func stop() -> void:
	_http.stop()


func _answer(request: Dictionary) -> Dictionary:
	if request.method not in ["GET", "HEAD", "OPTIONS"]:
		return {"code": 405, "type": "text/plain", "body": "method not allowed"}
	match str(request.path):
		"/matches", "":
			return {"code": 200, "type": "application/json", "body": make_matches_json()}
		"/health":
			return {"code": 200, "type": "text/plain", "body": "ok"}
	return {"code": 404, "type": "text/plain", "body": "not found"}


## The JSON body of GET /matches.
static func make_matches_json() -> String:
	var info := Net.make_match_info()
	info.erase("proto")
	return JSON.stringify({"matches": [info]})
