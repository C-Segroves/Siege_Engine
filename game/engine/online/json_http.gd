class_name JsonHttp
extends RefCounted
## One JSON-over-HTTP request from a node of the scene tree, with the round-trip time. Used by the master server client, the
## heartbeat and the server probe (ping). The request node frees itself when the answer (or the timeout) arrives.

const TIMEOUT_SECONDS := 4.0


## Sends `method` `url` (a JSON `body` when it is not null). `done(code, data, ms)`: code 0 = no answer; data = the parsed
## JSON (null when the answer is not JSON); ms = the round trip.
static func send(owner: Node, method: HTTPClient.Method, url: String, body: Variant, headers: PackedStringArray, done: Callable, timeout := TIMEOUT_SECONDS, retry := true) -> void:
	var http := HTTPRequest.new()
	http.timeout = timeout
	owner.add_child(http)
	var started := Time.get_ticks_usec()
	http.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, raw: PackedByteArray) -> void:
		var ms := int(round((Time.get_ticks_usec() - started) / 1000.0))
		http.queue_free()
		# A long frame (loading a screen or the game data) makes the request's timer run out at once: ask again, once.
		if retry and result == HTTPRequest.RESULT_TIMEOUT and ms < timeout * 500.0:
			send(owner, method, url, body, headers, done, timeout, false)
			return
		done.call(code if result == HTTPRequest.RESULT_SUCCESS else 0, parse(raw.get_string_from_utf8()), ms))
	var all_headers := PackedStringArray(headers)
	var payload := ""
	if body != null:
		all_headers.append("Content-Type: application/json")
		payload = JSON.stringify(body)
	if http.request(url, all_headers, method, payload) != OK:
		http.queue_free()
		done.call(0, null, 0)


## The JSON of `text`, or null when it is empty or not JSON (no error printed).
static func parse(text: String) -> Variant:
	if text.strip_edges() == "":
		return null
	var json := JSON.new()
	return json.data if json.parse(text) == OK else null
