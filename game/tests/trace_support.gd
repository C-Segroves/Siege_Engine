extends RefCounted
## Golden-trace support for the mission-unification parity tests (docs/MECHANICS_UNIFICATION.md section 3).
## A trace is a list of (time, event, text, code) rows, the time rounded to the rules tick. finish() writes
## tests/golden/<game>.json when it is missing and otherwise diffs against it.
## Usage: var tr := TraceSupport.new("es1", tree); tr.start(); tr.add("event", "text", 0); ...; tr.finish().

const TICK := 0.25
const SEED := 20261018
const HASH_LEN := 12
const MAX_SHOWN_DIFFS := 12
## The pilot name the goldens were recorded with: the player's own saved name (settings.json) must not leak into a trace.
const PILOT := "PenDragon"

var game := ""
var rows: Array = []         # every row in order: [t, event, text, code]
var _segments: Array = []    # start() opens a segment (one mission run); [first row index of each]
var _tree: SceneTree
var _t0 := 0
var _clock := -1.0   # >= 0: a driven clock in seconds instead of physics frames
var last_status := ""
var _tracked := {}
## The kill feed ("was killed by", "died out of bounds") comes from AI fights and physics: left out unless a test needs it.
var skip_kill_feed := true


func _init(p_game: String, p_tree: SceneTree) -> void:
	game = p_game
	_tree = p_tree
	Net.player_name = PILOT   # a test that needs another name sets it after creating the trace
	# The bot LOD director steps by wall-clock milliseconds (BotSleep._last_step_ms) and wakes / sleeps units by
	# distance: it would make AI fights, and with them the traces, depend on machine speed. Off, as scope_check does.
	var rules: Variant = ExtractionRules.data().get("bot_sleep")
	if rules is Dictionary:
		rules["enabled"] = false


## Time zero is now (physics frames); the global random generator is seeded (random radio chatter, AI).
func start() -> void:
	seed(SEED)
	_clock = -1.0
	_tracked = {}
	_t0 = Engine.get_physics_frames()
	_segments.append(rows.size())


## Uses a caller-driven clock (seconds) instead of the physics frame counter.
func set_clock(seconds: float) -> void:
	_clock = seconds


## Records a "state" row `key=value` whenever `value` differs from the last one tracked under `key`.
func track(key: String, value) -> void:
	var v := str(value)
	if _tracked.get(key, null) != v:
		_tracked[key] = v
		add("state", "%s=%s" % [key, v], 0)


func now() -> float:
	var t := _clock if _clock >= 0.0 else float(Engine.get_physics_frames() - _t0) / float(Engine.physics_ticks_per_second)
	return snappedf(t, TICK)


func add(event: String, text := "", code := 0) -> void:
	rows.append([now(), event, text, code])


## A row whose time is not part of the trace (-1): the radio's voice clips end on the audio thread's clock, so
## when a line starts depends on machine load. Their order and text still count.
func add_untimed(event: String, text := "", code := 0) -> void:
	rows.append([-1.0, event, text, code])


## Rows of the same time are put in a stable order (several sources can land in one tick).
func sorted_rows() -> Array:
	var out: Array = []
	var bounds := _segments.duplicate()
	if bounds.is_empty() or bounds[0] != 0:
		bounds.push_front(0)
	bounds.append(rows.size())
	for i in bounds.size() - 1:
		var seg := rows.slice(bounds[i], bounds[i + 1])
		seg.sort_custom(func(a, b):
			if a[0] != b[0]:
				return a[0] < b[0]
			return str(a[1], "|", a[2], "|", a[3]) < str(b[1], "|", b[2], "|", b[3]))
		out.append_array(seg)
	return out


func count(event: String) -> int:
	return rows.filter(func(r): return r[1] == event).size()


func summary() -> String:
	var counts := {}
	for r in rows:
		counts[r[1]] = int(counts.get(r[1], 0)) + 1
	return "%d events %s" % [rows.size(), counts]


func golden_path() -> String:
	return "res://tests/golden/%s.json" % game


## Writes the golden when missing, else diffs. Returns the number of differences (0 = match, golden written).
## The golden keeps event kinds, times and numeric codes in clear; every text is stored as a short hash
## (HASH_LEN hex chars of its sha256), so no original game text lands in the repository. A diff prints the live
## text next to the golden hash.
func finish() -> int:
	var live := sorted_rows()
	var hashed := _hash_rows(live)
	var path := golden_path()
	if not FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			printerr("trace %s: cannot write %s" % [game, path])
			return 1
		f.store_string(JSON.stringify({"game": game, "tick": TICK, "text": "sha256/%d" % HASH_LEN, "events": hashed}, "	"))
		f.close()
		last_status = "golden written (%d events)" % hashed.size()
		print("trace %s: %s" % [game, last_status])
		return 0
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		printerr("trace %s: golden unreadable" % game)
		return 1
	var gold := _normalise(parsed.get("events", []))
	# A row matches a golden row of the same event, text hash and code whose time is within one rules tick (a
	# physics step more or less moves an event across a 0.25 s bucket edge); each golden row is used once.
	var used := {}
	var diffs := 0
	for i in hashed.size():
		var b = hashed[i]
		var hit := -1
		for j in gold.size():
			if used.has(j):
				continue
			var g = gold[j]
			if g[1] == b[1] and g[2] == b[2] and g[3] == b[3] and absf(float(g[0]) - float(b[0])) <= TICK + 0.0001:
				hit = j
				break
		if hit >= 0:
			used[hit] = true
		else:
			diffs += 1
			if diffs <= MAX_SHOWN_DIFFS:
				printerr("  extra in this run: %s  live text: %s" % [JSON.stringify(b), JSON.stringify(live[i][2])])
	for j in gold.size():
		if not used.has(j):
			diffs += 1
			if diffs <= MAX_SHOWN_DIFFS:
				printerr("  missing from this run: golden %s" % JSON.stringify(gold[j]))
	last_status = "matches golden (%d events)" % hashed.size() if diffs == 0 else "%d differences vs golden (%d vs %d events)" % [diffs, gold.size(), hashed.size()]
	print("trace %s: %s" % [game, last_status])
	return diffs


static func hash_text(text: String) -> String:
	return text.sha256_text().substr(0, HASH_LEN)


func _hash_rows(list: Array) -> Array:
	return list.map(func(r): return [snappedf(float(r[0]), TICK), str(r[1]), hash_text(str(r[2])), int(r[3])])


static func _normalise(list: Array) -> Array:
	return list.map(func(r): return [snappedf(float(r[0]), TICK), str(r[1]), str(r[2]), int(r[3])])


# ------------------------------------------------------------------ observers for Battle based games

## Records chat/radio lines, objective changes, spawns and the match end of `battle`; `extra` (optional) is
## a Callable returning a Dictionary key -> value of game state, each change of which is recorded as "state".
func watch_battle(battle: Node, extra := Callable()) -> void:
	_battle = battle
	_extra = extra
	_objs = {}
	_spawned = {}
	_state = {}
	if _tree.physics_frame.is_connected(_poll):
		_tree.physics_frame.disconnect(_poll)
	battle.overlay.chat_log.added.connect(func(e: Dictionary):
		if skip_kill_feed and (" was killed by " in str(e.get("text")) or " died " in str(e.get("text"))):
			return
		if _is_wingman_chatter(str(e.get("sender", ""))):
			return
		if str(e.get("channel")) == str(ChatChannels.RADIO):
			add_untimed("chat.radio", str(e.get("text")), 0)
		else:
			add("chat." + str(e.get("channel")), str(e.get("text")), 0))
	battle.chat.radio.line_started.connect(func(speaker: String, text: String):
		if _is_wingman_chatter(speaker):
			return
		add_untimed("radio", "%s|%s" % [speaker, text], 0))
	battle.match_finished.connect(func(r: Dictionary):
		add("end", str(r.get("text", "")).replace("\n", " / "), int(r.get("code", -1)) * 10 + (1 if bool(r.get("success", false)) else 0)))
	_tree.physics_frame.connect(_poll)


## Wingman chatter (WingmanRadio: random kill / spotted lines) is engine behaviour, not mission script, and its
## random picks and timing follow the AI fight: left out.
func _is_wingman_chatter(speaker: String) -> bool:
	var rt = _battle.get("mission") if _battle != null else null
	var wr = rt.get("wingman_radio") if rt != null else null
	if wr == null:
		return false
	for w in wr.get("_wingmen"):
		if is_instance_valid(w.unit) and str(w.unit.display_name) == speaker:
			return true
	return false


var _battle: Node
var _extra := Callable()
var _objs := {}
var _spawned := {}
var _state := {}


func _poll() -> void:
	if _battle == null or not is_instance_valid(_battle):
		return
	var rt = _battle.get("mission")
	if rt != null:
		for l in rt.make_objective_lines():
			var key := str(l.get("text", ""))
			var done := 1 if bool(l.get("done", false)) else 0
			if not _objs.has(key):
				add("objective", key, done)
			elif _objs[key] != done:
				add("objective", key, done)
			_objs[key] = done
	for v in _tree.get_nodes_in_group("vehicles"):
		if not _spawned.has(v):
			_spawned[v] = true
			add("spawn", "%s|team%d" % [str(v.get("display_name")), int(v.get("team"))], 0)
	if _extra.is_valid():
		var s: Dictionary = _extra.call()
		for k in s:
			if not _state.has(k) or _state[k] != s[k]:
				add("state", str(k), int(s[k]))
			_state[k] = s[k]
