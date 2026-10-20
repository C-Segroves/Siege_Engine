class_name RadarMode
extends RefCounted
## Active / passive radar (Earthsiege 1, DBSIM 0x157f4 / 0x35298: the SCANNER page's ACT / PASS label, STRINGS0
## group 25). The original keeps one flag per unit (unit + 0x90, "emitting"), toggled by a key and by the EMCON
## wingman order, only on units with radar gear; it plays a cue (sounds 0x1a on, 0x1b off) and the AI's target
## criteria can ask for "emitting" units. The remake (L for the numbers):
##  * Active (default): the scope shows every contact in range, and the unit emits, so enemies detect it at their
##    full sensor range.
##  * Passive: the scope shows only emitting hostiles (or any unit very close, a third of the range); friends always
##    show (IFF). The unit is quieter: enemies detect it at HALF their sensor range (SIGNATURE_PASSIVE).

const EMITTING_META := "radar_emitting"
const PASSIVE_NEAR_SHARE := 0.34
const SIGNATURE_PASSIVE := 0.5
const LABELS := ["ACT", "PASS"]


static func is_emitting(unit: Node) -> bool:
	return unit != null and bool(unit.get_meta(EMITTING_META, true))


static func apply_emitting(unit: Node, on: bool) -> void:
	unit.set_meta(EMITTING_META, on)


static func toggle(unit: Node) -> bool:
	apply_emitting(unit, not is_emitting(unit))
	return is_emitting(unit)


static func make_label(unit: Node) -> String:
	return LABELS[0] if is_emitting(unit) else LABELS[1]


## Factor on a sensor's reach against `unit`: passive units are harder to detect.
static func make_signature(unit: Node) -> float:
	return 1.0 if is_emitting(unit) else SIGNATURE_PASSIVE


## True when `viewer`'s radar mode lets it see `unit` at `dist` of `radar_range`: active sees all; passive sees
## emitters and anything close, and friends (IFF) always.
static func can_see(viewer: Node, unit: Node, dist: float, radar_range: float) -> bool:
	if is_emitting(viewer) or is_emitting(unit):
		return true
	var v = viewer.get("team")
	var u = unit.get("team")
	if v != null and u != null and TeamRelations.is_allied(int(v), int(u)):
		return true
	return dist <= radar_range * PASSIVE_NEAR_SHARE
