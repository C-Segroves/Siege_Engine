class_name BoundsVisual
extends RefCounted
## What the local player sees of the out-of-area rule (BattleBounds): a red energy wall along the area edge when close, and a
## red tint with a warning while outside. Client-side only, built by Battle (nothing exists on a dedicated server) and driven by
## BattleBounds.is_out_of_area, the test the damage uses, so the visuals and the damage never disagree.
## Values: bounds_visual_rules.json. Reduced motion (ProjectSettings siege/accessibility/reduced_motion) stops the pulse and scroll.

const FILE := "res://engine/bounds_visual/bounds_visual_rules.json"
const REDUCED_MOTION_SETTING := "siege/accessibility/reduced_motion"

static var _data := {}


static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		_data = d if d is Dictionary else {}
		if _data.is_empty():
			push_error("BoundsVisual: cannot read %s" % FILE)
	return _data


static func value(key: String) -> float:
	return float(data().get(key, 0.0))


static func is_reduced_motion() -> bool:
	return bool(ProjectSettings.get_setting(REDUCED_MOTION_SETTING, false))


## The wall and the tint of `battle`; null on a dedicated server (no nodes at all) or without an area.
static func build_for(battle: Battle) -> Node:
	if ServerProfile.is_collision_only() or battle.bounds == null:
		return null
	var holder := Node.new()
	holder.name = "BoundsVisual"
	var wall := BoundsWall.new(battle)
	holder.add_child(wall)
	var tint := BoundsTint.new(battle)
	battle.overlay.add_child(tint)
	holder.set_meta("wall", wall)
	holder.set_meta("tint", tint)
	battle.add_child(holder)
	return holder
