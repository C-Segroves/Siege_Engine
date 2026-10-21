class_name CallinPodPose
extends RefCounted
## How a call-in drop pod is held in the air (docs/design/lobby_loadout_economy.md section 9.6): it falls nose first, and in the last
## callins.pod.flip_height_m metres it swings onto its tail so that it lands standing upright, nose up. The tail carries the engines
## (hdroppod / cdroppod have four nozzles at the shape's +Z end and the hatch dome at -Z; cy_pod is modelled standing, engines up), so
## the nose is each shape's own axis (callins.pod.nose_axes, in the shape's engine frame), not a guess from its proportions.

const FALLBACK_NOSE := Vector3.DOWN
const FALLBACK_FLIP_HEIGHT_M := 40.0


## The local direction of the nose of pod shape `shape_id` (the fallback capsule: down).
static func make_nose_axis(shape_id: String) -> Vector3:
	var axes: Dictionary = CallinRules.pod().get("nose_axes", {})
	var a: Array = axes.get(shape_id, [])
	if a.size() != 3:
		return FALLBACK_NOSE
	var nose := Vector3(float(a[0]), float(a[1]), float(a[2]))
	return nose.normalized() if nose.length() > 0.0 else FALLBACK_NOSE


static func make_flip_height() -> float:
	return maxf(float(CallinRules.pod().get("flip_height_m", FALLBACK_FLIP_HEIGHT_M)), 0.01)


## The pod's rotation `height_m` above the ground: the nose points down while it falls and up once it has landed (height 0).
static func make_basis(nose: Vector3, height_m: float) -> Basis:
	var falling := Basis(Quaternion(nose.normalized(), Vector3.DOWN))
	var turned := 1.0 - clampf(height_m / make_flip_height(), 0.0, 1.0)
	return Basis(Vector3.RIGHT, PI * smoothstep(0.0, 1.0, turned)) * falling
