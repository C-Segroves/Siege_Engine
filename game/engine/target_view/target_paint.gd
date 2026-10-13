class_name TargetPaint
extends RefCounted
## How a TargetView colours the parts of its model by damage level (DamageLevels): the palette-ramp
## look of the Earthsiege cockpit diagrams (TargetRampPaint), the remake's untextured standard picture
## (TargetFlatPaint), or Starsiege's own lit model (TargetLitPaint).


## Adds what the paint needs to the view's 3D world (lights, environment).
func build_world(_root: Node3D) -> void:
	pass


## Colours copy mesh `mi` for damage level `level` (DamageLevels.INTACT..DESTROYED).
func apply_level(_mi: MeshInstance3D, _level: int) -> void:
	pass
