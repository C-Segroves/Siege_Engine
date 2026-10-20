class_name MatchListClient
extends Node
## Fetches a server's match list (GET <origin>/matches, see MatchListServer) and tells the screen the matches.
## The browser build asks the page's own origin; the desktop asks an address the player typed (http(s)://host).

signal received(matches: Array)
signal failed(reason: String)

const TIMEOUT_SECONDS := 8.0


## The origin the web page was served from ("" outside a browser).
static func make_page_origin() -> String:
	if not WebPlatform.is_active():
		return ""
	return str(JavaScriptBridge.eval("window.location.origin"))


func fetch(origin: String) -> void:
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	add_child(http)
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		http.queue_free()
		var data = JSON.parse_string(body.get_string_from_utf8())
		if result != HTTPRequest.RESULT_SUCCESS or code != 200 or not data is Dictionary:
			failed.emit("no match list at %s (%d)" % [origin, code])
			return
		received.emit(data.get("matches", [])))
	if http.request(origin.rstrip("/") + "/matches") != OK:
		http.queue_free()
		failed.emit("bad address %s" % origin)
