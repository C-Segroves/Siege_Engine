class_name NetProfile
extends RefCounted
## Per-game netcode tuning (docs/DEDICATED_SERVER_SCALING.md section 6 and chunk M): tick rate, snapshot rates per
## interest tier, interest distances, prediction thresholds and lag compensation of one game's battles. The table is
## engine/net/net_profiles.json: a "default" entry and one entry per game pack id (`CommandProviders.make_game_pack`),
## each overriding only the keys it names ("inherits" names another entry to start from). A profile only changes a
## dedicated server and its clients (a LAN host keeps its 60 Hz / 20 Hz sync unless a test sets the BattleNetSync
## `*_in_lan` flags). Unknown keys and out-of-range values are reported (push_error) and replaced by the default.
##
## Keys (all optional in a game entry):
##   tick_hz            server simulation / input frame rate (ServerClock); server.json tick_hz 0 follows this
##   snapshot_hz        snapshots per second to near units (rounded to a whole number of ticks)
##   tier_intervals     [near, mid, far]: snapshots between updates of a unit in each tier
##   interest           {near_m, mid_m, soldier_view_m, vehicle_view_m} InterestGrid distances
##   prediction         {enabled, blend_s, epsilon_m, snap_infantry_m, snap_herc_m} (Prediction)
##   lag_comp           {enabled, max_rewind_ms, beams, projectile_min_mps (0 = never), include [weapon ids always
##                       compensated], exclude [weapon ids never compensated]} (LagCompensation)
##   evidence           where the numbers come from (free text, not read)

const PATH := "res://engine/net/net_profiles.json"
const DEFAULT_ID := "default"
const TIER_COUNT := 3
const MIN_HZ := 1
const MAX_TICK_HZ := 120
const MAX_SNAPSHOT_HZ := 120.0
const MAX_DISTANCE_M := 100000.0
const KNOWN_KEYS := ["tick_hz", "snapshot_hz", "tier_intervals", "interest", "prediction", "lag_comp", "evidence", "inherits"]
const INTEREST_KEYS := ["near_m", "mid_m", "soldier_view_m", "vehicle_view_m"]
const PREDICTION_KEYS := ["enabled", "blend_s", "epsilon_m", "snap_infantry_m", "snap_herc_m"]
const LAG_COMP_KEYS := ["enabled", "max_rewind_ms", "beams", "projectile_min_mps", "include", "exclude"]

static var _table := {}

var game_id := DEFAULT_ID
var tick_hz := 30
var snapshot_hz := 15.0
var tier_intervals: Array[int] = [1, 3, 5]
var near_m := 100.0
var mid_m := 400.0
var soldier_view_m := 300.0
var vehicle_view_m := 800.0
var prediction_enabled := true
var prediction_blend_s := 0.1
var prediction_epsilon_m := 0.05
var snap_infantry_m := 1.5
var snap_herc_m := 3.0
var lag_comp_enabled := true
var max_rewind_ms := 250.0
var beams_compensated := true
var projectile_min_mps := 250.0
var always_compensated: Array[String] = []
var never_compensated: Array[String] = []


## The profile of game pack `id` (the default entry's values where the game names none).
static func load_for(id: String) -> NetProfile:
	var table := _read_table()
	var merged: Dictionary = (table.get(DEFAULT_ID, {}) as Dictionary).duplicate(true)
	_merge_entry(merged, table, id, [])
	var profile := NetProfile.new()
	profile.game_id = id
	profile._apply(merged)
	return profile


## The profile used when nothing is known about the game (the default entry).
static func make_default() -> NetProfile:
	return load_for(DEFAULT_ID)


# ------------------------------------------------------------------ rules

## Whether a human's beam of weapon `weapon_id` is tested against the units as the shooter saw them.
func compensates_beam(weapon_id: String) -> bool:
	return lag_comp_enabled and not never_compensated.has(weapon_id) and (beams_compensated or always_compensated.has(weapon_id))


## Whether an unguided straight projectile of `weapon_id` flying at `speed` m/s is compensated like a beam.
func compensates_projectile(weapon_id: String, speed: float) -> bool:
	if not lag_comp_enabled or never_compensated.has(weapon_id):
		return false
	return always_compensated.has(weapon_id) or (projectile_min_mps > 0.0 and speed >= projectile_min_mps)


## Sets the distances and update intervals of `grid`.
func apply_to_grid(grid: InterestGrid) -> void:
	grid.near_m = near_m
	grid.mid_m = mid_m
	grid.soldier_view_m = soldier_view_m
	grid.vehicle_view_m = vehicle_view_m
	grid.tier_interval = tier_intervals.duplicate()


## Sets the thresholds of `prediction` that the profile tunes.
func apply_to_prediction(prediction: Prediction, body: Herc) -> void:
	prediction.blend_s = prediction_blend_s
	prediction.epsilon_m = prediction_epsilon_m
	prediction.snap_m = make_snap_distance(body)


## The distance (m) from which a correction of `body`'s prediction snaps instead of blending.
func make_snap_distance(body: Herc) -> float:
	return snap_infantry_m if body is Infantry else snap_herc_m


# ------------------------------------------------------------------ reading

static func _read_table() -> Dictionary:
	if not _table.is_empty():
		return _table
	var file := FileAccess.open(PATH, FileAccess.READ)
	var data = JSON.parse_string(file.get_as_text()) if file != null else null
	if not data is Dictionary or not (data as Dictionary).has(DEFAULT_ID):
		push_error("net profiles %s are missing or have no \"%s\" entry" % [PATH, DEFAULT_ID])
		_table = {DEFAULT_ID: {}}
	else:
		_table = data
	return _table


## Lays the entry `id` (after the entry it "inherits") over `into`.
static func _merge_entry(into: Dictionary, table: Dictionary, id: String, seen: Array) -> void:
	if id == DEFAULT_ID or seen.has(id):
		return
	seen.append(id)
	var entry: Dictionary = table.get(id, {})
	if entry.has("inherits"):
		_merge_entry(into, table, str(entry.inherits), seen)
	for key: String in entry:
		if key not in KNOWN_KEYS:
			push_error("net profile \"%s\": unknown key \"%s\"" % [id, key])
		elif entry[key] is Dictionary and into.get(key) is Dictionary:
			(into[key] as Dictionary).merge(entry[key], true)
		else:
			into[key] = entry[key]


func _apply(entry: Dictionary) -> void:
	tick_hz = roundi(_read_float(entry, "tick_hz", float(tick_hz), MIN_HZ, MAX_TICK_HZ))
	snapshot_hz = _read_float(entry, "snapshot_hz", snapshot_hz, MIN_HZ, MAX_SNAPSHOT_HZ)
	_apply_intervals(entry.get("tier_intervals", []))
	_apply_interest(entry.get("interest", {}))
	_apply_prediction(entry.get("prediction", {}))
	_apply_lag_comp(entry.get("lag_comp", {}))


func _apply_intervals(values: Array) -> void:
	if values.is_empty():
		return
	if values.size() != TIER_COUNT:
		push_error("net profile \"%s\": tier_intervals needs %d values" % [game_id, TIER_COUNT])
		return
	var parsed: Array[int] = []
	for v in values:
		parsed.append(maxi(int(v), 1))
	tier_intervals = parsed


func _apply_interest(d: Dictionary) -> void:
	_report_unknown(d, INTEREST_KEYS, "interest")
	near_m = _read_float(d, "near_m", near_m, 1.0, MAX_DISTANCE_M)
	mid_m = maxf(_read_float(d, "mid_m", mid_m, 1.0, MAX_DISTANCE_M), near_m)
	soldier_view_m = _read_float(d, "soldier_view_m", soldier_view_m, 1.0, MAX_DISTANCE_M)
	vehicle_view_m = _read_float(d, "vehicle_view_m", vehicle_view_m, 1.0, MAX_DISTANCE_M)


func _apply_prediction(d: Dictionary) -> void:
	_report_unknown(d, PREDICTION_KEYS, "prediction")
	prediction_enabled = bool(d.get("enabled", prediction_enabled))
	prediction_blend_s = _read_float(d, "blend_s", prediction_blend_s, 0.001, 5.0)
	prediction_epsilon_m = _read_float(d, "epsilon_m", prediction_epsilon_m, 0.0, 10.0)
	snap_infantry_m = _read_float(d, "snap_infantry_m", snap_infantry_m, 0.0, 1000.0)
	snap_herc_m = _read_float(d, "snap_herc_m", snap_herc_m, 0.0, 1000.0)


func _apply_lag_comp(d: Dictionary) -> void:
	_report_unknown(d, LAG_COMP_KEYS, "lag_comp")
	lag_comp_enabled = bool(d.get("enabled", lag_comp_enabled))
	max_rewind_ms = _read_float(d, "max_rewind_ms", max_rewind_ms, 0.0, 2000.0)
	beams_compensated = bool(d.get("beams", beams_compensated))
	projectile_min_mps = _read_float(d, "projectile_min_mps", projectile_min_mps, 0.0, 100000.0)
	always_compensated.assign(d.get("include", always_compensated))
	never_compensated.assign(d.get("exclude", never_compensated))


func _report_unknown(d: Dictionary, known: Array, section: String) -> void:
	for key: String in d:
		if key not in known:
			push_error("net profile \"%s\": unknown key \"%s.%s\"" % [game_id, section, key])


func _read_float(d: Dictionary, key: String, fallback: float, low: float, high: float) -> float:
	if not d.has(key):
		return fallback
	var value := float(d[key])
	if value < low or value > high:
		push_error("net profile \"%s\": %s = %s is outside %s..%s" % [game_id, key, value, low, high])
		return fallback
	return value
