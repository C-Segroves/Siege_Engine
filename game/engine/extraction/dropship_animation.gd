class_name DropshipAnimation
extends RefCounted
## The animation sequences of a Starsiege dropship (tr_drop, kn_drop, cy_drop, tr_carg): "Seq01_FLY" loops while it
## flies and "Seq02_LAND" is posed by its height above the ground, from land_start_alt_m (the gear and flaps begin
## to move) to land_full_alt_m (fully down), and backwards on lift-off. Driven by the replicated position only, so
## every peer sees the same pose. extraction_rules.json "transport.dropship_animation" holds the two heights.
## Only tr_carg has these sequences: the tr_drop, kn_drop and cy_drop shapes carry none in the original data (their
## tr_drop / kn_drop / cy_drop sequence lists are empty), so those three fly and land without animation; none is made up.

const FLY_NAME := "Seq01_FLY"
const LAND_NAME := "Seq02_LAND"
const DEFAULT_START_ALT_M := 35.0
const DEFAULT_FULL_ALT_M := 12.0

var shape: ShapeInstance
var fly_seq := -1
var land_seq := -1
var start_alt_m := DEFAULT_START_ALT_M
var full_alt_m := DEFAULT_FULL_ALT_M
## Seconds into the FLY loop, and how far the LAND sequence is posed (0..1) after the last update.
var fly_time := 0.0
var land_progress := 0.0
var _was_landing := false


## The animation of `flyer`'s shape, or null when the shape has neither sequence (every other vehicle).
static func make(flyer: Herc) -> DropshipAnimation:
	if flyer.shape == null:
		return null
	var a := DropshipAnimation.new()
	a.shape = flyer.shape
	a.fly_seq = ShapeCycles.find_named(a.shape, [FLY_NAME])
	a.land_seq = ShapeCycles.find_named(a.shape, [LAND_NAME])
	if a.fly_seq < 0 and a.land_seq < 0:
		return null
	var rules: Dictionary = ExtractionRules.transport().get("dropship_animation", {})
	a.start_alt_m = float(rules.get("land_start_alt_m", DEFAULT_START_ALT_M))
	a.full_alt_m = float(rules.get("land_full_alt_m", DEFAULT_FULL_ALT_M))
	return a


## 0 = flying, 1 = landing gear fully down, for a height of `altitude` metres above the ground.
func make_land_progress(altitude: float) -> float:
	return clampf((start_alt_m - altitude) / maxf(start_alt_m - full_alt_m, 0.01), 0.0, 1.0)


## Poses the shape for the flyer's current height; `delta` seconds have passed.
func update(altitude: float, delta: float) -> void:
	land_progress = make_land_progress(altitude)
	if land_progress > 0.0 and land_seq >= 0:
		ShapeCycles.pose(shape, land_seq, land_progress, false)
		_was_landing = true
		return
	if _was_landing and land_seq >= 0:
		ShapeCycles.pose(shape, land_seq, 0.0, false)   # back to the flying shape before the loop takes over
		_was_landing = false
	if fly_seq >= 0:
		fly_time += delta
		var cycle := float(ShapeCycles.cycle_seconds(shape, fly_seq, 0.0))
		ShapeCycles.pose(shape, fly_seq, fly_time / maxf(cycle, 0.01))
