class_name DeathFx
extends RefCounted
## Each game's own death effects (docs/formats/weapon_fx.md section 9): what plays when a unit, one of its
## damage components, a structure, a turret or a soldier is destroyed. The steps come from the pack's
## effect library ("deaths" block, tools/fx_deaths.py) and name that pack's own effects (ES1/ES2 EXPLOS.DAT
## rows, Battledrome explosion types, Starsiege IDDTS shapes, Tribes / Tribes 2 ExplosionData).
##
## A pack without a deaths block (an old import) gets FxPlayer's generic explosion, counted in
## Effects.fx.generic_explosions; the death fx test asserts that never happens for the installed packs.

const KIND_VEHICLE := "vehicle"
const KIND_COMPONENT := "component"
const KIND_COMPONENT_BIG := "component_big"
const KIND_STRUCTURE := "structure"
const KIND_TURRET := "turret"
const KIND_INFANTRY := "infantry"
## Kinds that show nothing when the pack names nothing (a component, a soldier): no generic stand-in.
const SILENT_KINDS := [KIND_COMPONENT, KIND_COMPONENT_BIG, KIND_INFANTRY]
## Generic stand-in size per metre of body height (last resort only).
const FALLBACK_SIZE_PER_HEIGHT := 0.35
const FALLBACK_MIN_SIZE := 2.0


## A death of `body` = {"pack", "kind", "keys": [vehicle id, class ...], "at": Vector3 (feet / base),
## "height": m, "radius": m}, played under `parent`.
static func play(parent: Node, body: Dictionary) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	var entry := FxLibrary.death(str(body.get("pack", "")), str(body.get("kind", KIND_VEHICLE)), body.get("keys", []))
	if entry.is_empty():
		_play_fallback(parent, body)
		return
	for step in entry.get("steps", []):
		if step is Dictionary:
			_play_step(parent, step, body)


## True when the pack's data names a death for `kind` (tests, diagnostics).
static func has_death(pack: String, kind: String, keys: Array = []) -> bool:
	return not FxLibrary.death(pack, kind, keys).is_empty()


## A body description of `node` for play(): its pack from the "<pack>:<name>" id, its position and size.
static func make_body(node: Node3D, id: String, kind: String, size: Vector2) -> Dictionary:
	var p := Assets.split_id(Assets.qualify(id))
	return {"pack": p[0], "kind": kind, "keys": [p[1]], "at": node.global_position,
		"height": size.y, "radius": size.x}


static func _play_step(parent: Node, step: Dictionary, body: Dictionary) -> void:
	var effects: Array = step.get("effects", [])
	if effects.is_empty():
		return
	for i in maxi(1, int(step.get("count", 1))):
		var at := _make_position(step, body)
		var ref := str(effects[randi() % effects.size()])
		var wait := float(step.get("delay", 0.0)) + i * float(step.get("interval", 0.0))
		if wait <= 0.0:
			Effects.fx.play_effect(parent, ref, str(body.pack), at)
		else:
			parent.get_tree().create_timer(wait).timeout.connect(
				func() -> void: Effects.fx.play_effect(parent, ref, str(body.pack), at))


## The step's point: `height` of the body up from its feet, scattered over `scatter` of its half size.
static func _make_position(step: Dictionary, body: Dictionary) -> Vector3:
	var height := float(body.get("height", 0.0))
	var at: Vector3 = body.get("at", Vector3.ZERO) + Vector3.UP * height * float(step.get("height", 0.5))
	var scatter := float(step.get("scatter", 0.0))
	if scatter <= 0.0:
		return at
	var r := float(body.get("radius", 0.0)) * scatter
	return at + Vector3(randf_range(-r, r), randf_range(0.0, height * scatter * 0.5), randf_range(-r, r))


static func _play_fallback(parent: Node, body: Dictionary) -> void:
	if str(body.get("kind", "")) in SILENT_KINDS:
		return
	var height := float(body.get("height", 0.0))
	var size := maxf(FALLBACK_MIN_SIZE, height * FALLBACK_SIZE_PER_HEIGHT)
	Effects.fx.play_generic_explosion(parent, body.get("at", Vector3.ZERO) + Vector3.UP * height * 0.5, size)
