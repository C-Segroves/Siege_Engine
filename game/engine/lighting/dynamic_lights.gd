class_name DynamicLights
extends RefCounted
## Every point light the games add at run time, built one way and counted against one budget: explosion and
## impact flashes (FxPlayer), lights carried by projectiles (FxProjectileLook) and fixed base-equipment lights
## (TribesBaseLights). Each game's fx / equipment data gives colour, range and energy; the budget keeps a 24-player
## battle's lights bounded (new transient lights are skipped while it is spent; fixed lights always get one).

## Live transient lights (flashes, projectile lights) at most.
const MAX_TRANSIENT := 24

static var _live := 0


## A shadowless OmniLight3D (not yet in the tree): spec {color: Color, range: metres, energy}.
static func make_light(spec: Dictionary) -> OmniLight3D:
	var l := OmniLight3D.new()
	l.light_color = spec.get("color", Color.WHITE)
	l.omni_range = float(spec.get("range", 6.0))
	l.light_energy = float(spec.get("energy", 1.0))
	l.shadow_enabled = false
	return l


## A transient light counted against the budget until it leaves the tree; null when the budget is spent.
static func make_transient(spec: Dictionary) -> OmniLight3D:
	if _live >= MAX_TRANSIENT:
		return null
	var l := make_light(spec)
	_live += 1
	l.tree_exiting.connect(func() -> void: _live = maxi(0, _live - 1))
	return l


## Live transient lights (diagnostics, tests).
static func transient_count() -> int:
	return _live
