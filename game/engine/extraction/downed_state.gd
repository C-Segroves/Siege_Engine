class_name DownedState
extends RefCounted
## A soldier knocked down instead of killed (the extraction mode's revive rule, docs/design/extraction.md section 4):
## he lies prone, crawls at crawl_speed_mps, cannot fire, jet, jump or use anything, and the AI ignores him (meta
## "dormant": AIPilot, FlyerAI and InfantryBot skip dormant units; a player may still finish him). Applied on every
## peer through ExtractionRevive's messages; the host also clamps his controls each frame (apply_held_controls).
## Driven through Infantry's public fields only (the body shape and eye nodes, the control fields, the health
## component); the lying pose rotates the body shape about its feet.

const META := "downed"
const DORMANT_META := "dormant"
const SAVED_POSE_META := "downed_pose"
## The prone body: the shape tipped forward about its feet, the eye this high (metres).
const PRONE_PITCH := -PI * 0.5
const PRONE_LIFT := 0.35
const PRONE_EYE_HEIGHT := 0.45


static func is_downed(soldier: Node) -> bool:
	return is_instance_valid(soldier) and soldier.has_meta(META)


## Every peer: `soldier` goes down (prone, ignored by the AI) or gets back up.
static func apply_downed(soldier: Infantry, on: bool) -> void:
	if on == is_downed(soldier):
		return
	if on:
		soldier.set_meta(META, true)
		soldier.set_meta(DORMANT_META, true)
		_apply_prone_pose(soldier)
		apply_held_controls(soldier, 0.0)
	else:
		soldier.remove_meta(META)
		soldier.remove_meta(DORMANT_META)
		_apply_standing_pose(soldier)


## Host: a downed soldier's controls: no fire, jet or jump, movement cut to `crawl_share` of full input.
static func apply_held_controls(soldier: Infantry, crawl_share: float) -> void:
	soldier.throttle = clampf(soldier.throttle, -crawl_share, crawl_share)
	soldier.turn = clampf(soldier.turn, -crawl_share, crawl_share)
	soldier.jump_input = false
	soldier.jet_input = false
	soldier.jetting = false
	for w in soldier.weapons:
		w.trigger = false


## The share of full running input that makes crawl speed in `soldier`'s armour.
static func make_crawl_share(soldier: Infantry) -> float:
	var crawl := float(ExtractionRevive.rules().get("crawl_speed_mps", 1.2))
	return clampf(crawl / maxf(float(soldier.armor.get("max_forward_speed", 11.0)), 0.1), 0.0, 1.0)


## Host: sets the soldier's health to `fraction` of its armour's (downed pool or revived health).
static func apply_health_fraction(soldier: Infantry, fraction: float) -> void:
	if soldier.components.is_empty():
		return
	var c: Dictionary = soldier.components[0]
	c.hp = float(c.get("max", c.hp)) * fraction
	soldier.integrity = HercDamage.integrity_of(soldier.components)


static func _apply_prone_pose(soldier: Infantry) -> void:
	if soldier.shape == null:
		return
	soldier.set_meta(SAVED_POSE_META, [soldier.shape.transform, soldier.eye.position if soldier.eye else Vector3.ZERO])
	# Tipped forward about the feet (whatever axes the imported shape uses), lifted so the chest rests on the ground.
	soldier.shape.transform = Transform3D(Basis(Vector3.RIGHT, PRONE_PITCH), Vector3.UP * PRONE_LIFT) * soldier.shape.transform
	if soldier.eye:
		soldier.eye.position.y = PRONE_EYE_HEIGHT


static func _apply_standing_pose(soldier: Infantry) -> void:
	if not soldier.has_meta(SAVED_POSE_META) or soldier.shape == null:
		return
	var pose: Array = soldier.get_meta(SAVED_POSE_META)
	soldier.remove_meta(SAVED_POSE_META)
	soldier.shape.transform = pose[0]
	if soldier.eye:
		soldier.eye.position = pose[1]
