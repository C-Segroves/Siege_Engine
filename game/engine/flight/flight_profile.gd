class_name FlightProfile
extends RefCounted
## How an AI pilot flies one craft, as data (flight_profiles.json): the minimum height over the ground, how far ahead
## the ground is read, the bank of a hard turn and the climb and dive limits. The craft's FlightModel gives the physical
## limits (speeds, maximum pitch); the profile is the manner, so each game's flyers keep their own feel.

const PROFILE_PATH := "res://engine/flight/flight_profiles.json"
const DEFAULT_STYLE := FlightPresets.STYLE_JET
## A hover craft climbs by lift as well as by its nose, so its flight path may be steeper than its pitch.
const HOVER_CLIMB_PER_PITCH := 3.0
## A hover craft has a hard altitude limit above the ground; its clearance stays well inside it.
const HOVER_CLEARANCE_OF_MAX_ALT := 0.6

static var _table := {}

var clearance_m := 18.0
var look_ahead_s := 6.0
var react_s := 1.2
var max_bank := deg_to_rad(55.0)
var bank_per_rad := 1.2
var max_climb := deg_to_rad(25.0)
var max_dive := deg_to_rad(20.0)
var climb_per_m := 0.02
var edge_margin_s := 5.0
## The height over the ground a strafing dive may go down to (m): lower than the clearance, which holds everywhere else.
var dive_clearance_m := 6.0


## The profile of vehicle `vehicle_id` flying with FlightModel parameters `params`.
static func make_for(vehicle_id: String, params: Dictionary) -> FlightProfile:
	var table := _load_table()
	var style := String(params.get("style", DEFAULT_STYLE))
	var data: Dictionary = table.get("styles", {}).get(style, {}).duplicate()
	data.merge(_find_rule(table.get("rules", []), vehicle_id), true)
	var p := FlightProfile.new()
	p.apply_data(data)
	p.apply_limits(params)
	return p


func apply_data(d: Dictionary) -> void:
	clearance_m = float(d.get("clearance_m", clearance_m))
	look_ahead_s = float(d.get("look_ahead_s", look_ahead_s))
	react_s = float(d.get("react_s", react_s))
	max_bank = deg_to_rad(float(d.get("max_bank_deg", rad_to_deg(max_bank))))
	bank_per_rad = float(d.get("bank_per_rad", bank_per_rad))
	max_climb = deg_to_rad(float(d.get("max_climb_deg", rad_to_deg(max_climb))))
	max_dive = deg_to_rad(float(d.get("max_dive_deg", rad_to_deg(max_dive))))
	climb_per_m = float(d.get("climb_per_m", climb_per_m))
	edge_margin_s = float(d.get("edge_margin_s", edge_margin_s))
	dive_clearance_m = float(d.get("dive_clearance_m", dive_clearance_m))


## The craft's own limits win over the manner: a hover craft never banks or pitches beyond its datablock.
func apply_limits(params: Dictionary) -> void:
	if params.has("max_bank"):
		max_bank = minf(max_bank, float(params.max_bank))
	if params.has("max_alt"):
		clearance_m = minf(clearance_m, float(params.max_alt) * HOVER_CLEARANCE_OF_MAX_ALT)
	dive_clearance_m = minf(dive_clearance_m, clearance_m)
	if params.has("max_pitch"):
		max_climb = minf(max_climb, float(params.max_pitch) * HOVER_CLIMB_PER_PITCH)
		max_dive = minf(max_dive, float(params.max_pitch) * HOVER_CLIMB_PER_PITCH)


static func _find_rule(rules: Array, vehicle_id: String) -> Dictionary:
	var pack := vehicle_id.get_slice(":", 0)
	var upper := vehicle_id.to_upper()
	for r in rules:
		if not pack.begins_with(String(r.pack)):
			continue
		var names: Array = r.get("names", [])
		if names.is_empty() or names.any(func(n: String) -> bool: return upper.contains(n)):
			return r.get("profile", {})
	return {}


static func _load_table() -> Dictionary:
	if _table.is_empty():
		var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text()) if f else null
		if parsed is Dictionary:
			_table = parsed
		else:
			push_error("FlightProfile: %s is missing or invalid" % PROFILE_PATH)
			_table = {"styles": {}, "rules": []}
	return _table
