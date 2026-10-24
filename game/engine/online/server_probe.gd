class_name ServerProbe
extends Node
## Asks a game server for its info and the round-trip time before joining: GET <list origin>/matches (MatchListServer).
## `done(ok, info, ping_ms)`: info = the first match of the answer ({name, mode, map, players, max, password, ...}).


func probe(list_origin: String, done: Callable) -> void:
	if list_origin == "":
		done.call(false, {}, -1)
		return
	JsonHttp.send(self, HTTPClient.METHOD_GET, list_origin.rstrip("/") + "/matches", null, PackedStringArray(), func(code: int, data: Variant, ms: int) -> void:
		var matches: Array = data.get("matches", []) if data is Dictionary else []
		if code != 200 or matches.is_empty():
			done.call(false, {}, -1)
			return
		done.call(true, matches[0], ms), 2.5)
