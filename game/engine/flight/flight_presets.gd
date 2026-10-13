class_name FlightPresets
extends RefCounted
## Flight parameters of a vehicle (FlightModel.create input), in metres, seconds and radians.
##
## Sources (docs/formats/flight_model.md):
##   - Earthsiege 2 flyers carry their FM file in the catalog ("flight_model", 27 words):
##     decoded by decode_fm(), "jet" style.
##   - Tribes fliers: their FlierData read from the user's scripts at import ("flier_data", "hover"
##     style); Tribes 2 fliers carry FlierData-style values derived from their FlyingVehicleData
##     forces (tools/export_tribes_vehicles.py).
##   - Every other flyer (ES1 Skimmer, Starsiege flyers ...) scales a reference craft from the user's
##     own imported packs: small craft fly like the ES2 Razor, large ones (transports, dropships) like
##     the Tribes HAPC. Without those packs the remake's own generic presets stand in.
## No original game data is stored in this file: it only reads what the importer extracted.

const STYLE_JET := "es2"
const STYLE_HOVER := "tribes"
const FM_WORDS := 27
## ES2 nominal frame: 125 ms (gamedata/es2/units.json seconds_per_tick; DBSIM 0x46774c: 1000 >> 3).
const ES2_FRAMES_PER_SECOND := 8.0
## FM fixed point: rate damping and slip are /1024, angles 65536 per turn.
const FIXED_ONE := 1024.0
## Speed target change per angle unit of pitch, /1024 (DBSIM 0x466b75 nose up, 0x466b59 nose down).
const CLIMB_SPEED_LOSS := 62.0
const DIVE_SPEED_GAIN := 250.0
## Ceiling push: nose-down rate demand per world unit above the ceiling, /1024 (0x466e41).
const CEILING_PUSH := 10.0
## Reference craft other games' flyers are scaled from, when the user imported their pack.
const REFERENCE_JET := "es2:RAZOR"
const REFERENCE_SKIMMER := "es2:SKIMMER"
const REFERENCE_TRANSPORT := "tribes:HAPC"
## The remake's own generic jet (no pack data): a nimble ~45 m/s fighter, values chosen for feel.
const GENERIC_JET := {"style": STYLE_JET, "frames_per_second": ES2_FRAMES_PER_SECOND,
	"pitch_rate": 0.035, "roll_rate": 0.13, "yaw_rate": 0.035, "pitch_accel": 0.02, "roll_accel": 0.04,
	"speed_accel": 3.0, "rate_damping": 0.5, "pitch_level": 0.0625, "roll_level": 0.0625, "turn_per_bank": 0.0625,
	"ceiling_min": 25.0, "ceiling_max": 220.0, "max_speed": 45.0, "min_speed": 10.0, "slip_keep": 0.3}
## The remake's own generic hover transport (no pack data), FlierData-style fields.
const GENERIC_HOVER := {"maxSpeed": 25.0, "minSpeed": -1.5, "accel": 0.3, "lift": 0.5, "maxAlt": 20.0,
	"maxVertical": 6.0, "maxBank": 0.3, "maxPitch": 0.2, "mass": 20.0, "length_m": 12.0}
const ES2_METRES_PER_UNIT := 1.0 / 256.0
## Earthsiege 1 Skimmer (SKIMMER.DAT words 1 / 2: max and cruise speed, ES1 units per 100 ms frame,
## docs/formats/gameplay.md §2); it is the same craft as the ES2 Landskimmer, so it flies the ES2
## Skimmer FM scaled to this speed.
const ES1_SKIMMER_MAX := 1200.0
const ES1_SKIMMER_CRUISE := 1000.0
const ES1_FRAMES_PER_SECOND := 10.0
## Approximations for undecoded Darkstar flier physics: accel is read as a fraction of maxSpeed
## per second, lift as a fraction of the Tribes gravity (20 m/s^2), turn rate per rad of maxBank.
const TRIBES_GRAVITY := 20.0
const HOVER_TURN_PER_BANK := 3.0
const HOVER_HEIGHT := 2.0
## Flyers at least this tall (m) are transports / dropships and fly as hover craft.
const HOVER_MIN_HEIGHT := 10.0
## HAPC height (docs/formats/tribes.md: 10.6 x 12.7 x 3.0 m) for scaling transports.
const HAPC_HEIGHT := 3.0
const SCALED_MAX_ALT_LIMIT := 250.0
const SCALED_MAX_VERTICAL_LIMIT := 20.0


## Parameters for a catalog vehicle definition; `metres_per_unit` = its pack's world scale.
static func make_params(vdef: Dictionary, metres_per_unit: float) -> Dictionary:
	var fm: Array = vdef.get("flight_model", [])
	if fm.size() == FM_WORDS:
		return make_jet_params(fm, metres_per_unit)
	var tribes := make_tribes_datablock(vdef)
	if not tribes.is_empty():
		return make_hover_params(tribes)
	if String(vdef.get("pack", "")) == "es1":
		return make_es1_skimmer_params(metres_per_unit)
	if float(vdef.get("height_m", 0.0)) >= HOVER_MIN_HEIGHT or String(vdef.get("pack", "")).begins_with("tribes"):
		return make_scaled_hover_params(vdef)
	return make_scaled_jet_params(vdef)


## The FM words as named original values (angle units, world units, frames; docs §1.2).
static func decode_fm(w: Array) -> Dictionary:
	var d := func(i: int) -> int: return (int(w[7 + 2 * i]) & 0xffff) | (int(w[8 + 2 * i]) << 16)
	return {"pitch_rate": int(w[0]), "roll_rate": int(w[1]), "yaw_rate": int(w[2]), "pitch_accel": int(w[3]),
		"roll_accel": int(w[4]), "speed_accel": int(w[5]), "rate_damping": d.call(1), "pitch_level_shift": d.call(2),
		"roll_level_shift": d.call(3), "turn_shift": d.call(4), "ceiling_max": d.call(5), "ceiling_min": d.call(6),
		"max_speed": d.call(7), "min_speed": d.call(8), "slip_keep": d.call(9)}


## Earthsiege 2 jet: FM values converted to metres, m/s per frame and rad per frame.
static func make_jet_params(fm: Array, metres_per_unit: float) -> Dictionary:
	var o := decode_fm(fm)
	var mps := metres_per_unit * ES2_FRAMES_PER_SECOND   # m/s per world unit per frame
	var angle := TAU / 65536.0
	var p := {"style": STYLE_JET, "frames_per_second": ES2_FRAMES_PER_SECOND,
		"pitch_rate": o.pitch_rate * angle, "roll_rate": o.roll_rate * angle, "yaw_rate": o.yaw_rate * angle,
		"pitch_accel": o.pitch_accel * angle, "roll_accel": o.roll_accel * angle,
		"speed_accel": o.speed_accel * mps, "rate_damping": o.rate_damping / FIXED_ONE,
		"pitch_level": 1.0 / float(1 << o.pitch_level_shift), "roll_level": 1.0 / float(1 << o.roll_level_shift),
		"turn_per_bank": 1.0 / float(1 << o.turn_shift),
		"ceiling_max": o.ceiling_max * metres_per_unit, "ceiling_min": o.ceiling_min * metres_per_unit,
		"max_speed": o.max_speed * mps, "min_speed": o.min_speed * mps, "slip_keep": o.slip_keep / FIXED_ONE,
		"climb_speed_loss": CLIMB_SPEED_LOSS / FIXED_ONE / angle * mps,
		"dive_speed_gain": DIVE_SPEED_GAIN / FIXED_ONE / angle * mps,
		"ceiling_push": CEILING_PUSH / FIXED_ONE * angle / metres_per_unit}
	p["ceiling_slope"] = (p.ceiling_max - p.ceiling_min) / maxf(p.max_speed - p.min_speed, 0.001)
	p["cruise_speed"] = p.max_speed
	return p


## Jet parameters with every speed (and the speed-driven ceiling) scaled to `max_speed` m/s.
static func make_speed_scaled(p: Dictionary, max_speed: float) -> Dictionary:
	var out := p.duplicate()
	var k := max_speed / float(p.max_speed)
	for key in ["max_speed", "min_speed", "speed_accel", "climb_speed_loss", "dive_speed_gain", "ceiling_max",
			"ceiling_min", "cruise_speed"]:
		out[key] = float(p[key]) * k
	return out


## The jet parameters of reference craft `id` from the user's packs, else the generic jet.
static func make_reference_jet_params(id: String) -> Dictionary:
	var fm: Array = Packs.vehicles.get(id, {}).get("flight_model", [])
	if fm.size() == FM_WORDS:
		return make_jet_params(fm, ES2_METRES_PER_UNIT)
	return make_generic_jet_params()


## The remake's own jet preset with its derived fields (used when no reference pack is imported).
static func make_generic_jet_params() -> Dictionary:
	var p := GENERIC_JET.duplicate()
	var angle := TAU / 65536.0
	var mps := ES2_METRES_PER_UNIT * ES2_FRAMES_PER_SECOND
	p["climb_speed_loss"] = CLIMB_SPEED_LOSS / FIXED_ONE / angle * mps
	p["dive_speed_gain"] = DIVE_SPEED_GAIN / FIXED_ONE / angle * mps
	p["ceiling_push"] = CEILING_PUSH / FIXED_ONE * angle / ES2_METRES_PER_UNIT
	p["ceiling_slope"] = (p.ceiling_max - p.ceiling_min) / maxf(p.max_speed - p.min_speed, 0.001)
	p["cruise_speed"] = p.max_speed
	return p


## The hover datablock of the reference transport from the user's packs, else the generic one.
static func make_reference_transport_datablock() -> Dictionary:
	var data = Packs.vehicles.get(REFERENCE_TRANSPORT, {}).get("flier_data")
	return data if data is Dictionary else GENERIC_HOVER


## ES1 Skimmer: the ES2 Skimmer (or the generic jet) at the ES1 Skimmer's speed.
static func make_es1_skimmer_params(metres_per_unit: float) -> Dictionary:
	var es2 := make_reference_jet_params(REFERENCE_SKIMMER)
	var p := make_speed_scaled(es2, ES1_SKIMMER_MAX * metres_per_unit * ES1_FRAMES_PER_SECOND)
	p["cruise_speed"] = ES1_SKIMMER_CRUISE * metres_per_unit * ES1_FRAMES_PER_SECOND
	return p


## Small flyers of other games: the Razor (or the generic jet), at the vehicle's speed, turn and pitch rates.
static func make_scaled_jet_params(vdef: Dictionary) -> Dictionary:
	var razor := make_reference_jet_params(REFERENCE_JET)
	var p := make_speed_scaled(razor, float(vdef.get("max_speed", razor.max_speed)))
	var fps: float = p.frames_per_second
	var turn_rate := float(vdef.get("turn_rate", 0.0))
	if turn_rate > 0.0:
		p["turn_per_bank"] = turn_rate / (fps * JetFlightModel.MAX_BANK)
	var pitch_rate := float(vdef.get("pitch_rate", 0.0))
	if pitch_rate > 0.0:
		p["pitch_accel"] = float(razor.pitch_accel) * pitch_rate / fps / float(razor.pitch_rate)
		p["pitch_rate"] = pitch_rate / fps
	return p


## The Tribes datablock a vehicle flies by: its own "flier_data" ({} when it has none).
static func make_tribes_datablock(vdef: Dictionary) -> Dictionary:
	if not String(vdef.get("pack", "")).begins_with("tribes"):
		return {}
	return vdef.flier_data if vdef.get("flier_data") is Dictionary else {}


## Tribes flier parameters from its datablock.
static func make_hover_params(b: Dictionary) -> Dictionary:
	var max_speed := float(b.maxSpeed)
	return {"style": STYLE_HOVER, "max_speed": max_speed, "min_speed": float(b.minSpeed),
		"accel": float(b.accel) * max_speed, "lift_accel": float(b.lift) * TRIBES_GRAVITY,
		"max_alt": float(b.maxAlt), "max_vertical": float(b.maxVertical), "max_bank": float(b.maxBank),
		"max_pitch": float(b.maxPitch), "turn_rate": float(b.maxBank) * HOVER_TURN_PER_BANK,
		"hover_height": float(b.get("hoverHeight", HOVER_HEIGHT)), "cruise_speed": max_speed}


## Large flyers of other games: the HAPC (or the generic transport) at the vehicle's speed and turn
## rate, its altitude limit and climb rate grown with the craft's size.
static func make_scaled_hover_params(vdef: Dictionary) -> Dictionary:
	var p := make_hover_params(make_reference_transport_datablock())
	var size := maxf(float(vdef.get("height_m", HAPC_HEIGHT)) / HAPC_HEIGHT, 1.0)
	p["max_speed"] = float(vdef.get("max_speed", p.max_speed))
	p["cruise_speed"] = p.max_speed
	p["accel"] = float(vdef.get("accel", p.accel))
	if float(vdef.get("turn_rate", 0.0)) > 0.0:
		p["turn_rate"] = float(vdef.turn_rate)
	if float(vdef.get("pitch_max", 0.0)) > 0.0:
		p["max_pitch"] = float(vdef.pitch_max)
	p["max_alt"] = minf(float(p.max_alt) * size, SCALED_MAX_ALT_LIMIT)
	p["max_vertical"] = minf(float(p.max_vertical) * sqrt(size), SCALED_MAX_VERTICAL_LIMIT)
	return p
