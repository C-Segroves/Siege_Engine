class_name TargetLitPaint
extends TargetPaint
## Starsiege's own STATUS / TARGET picture (HudMtrDamage 0x522b68 / HudMtrTarget 0x523440): the vehicle shape as
## it is, its own materials (damage shows as the shape's damaged parts and skins), lit by a grey ambient of 0.7
## (0x522646: 0x3f333333 x 3) and a white directional light of 1.0 (0x5226dd); no damage tint.

const AMBIENT := Color(0.7, 0.7, 0.7)
const LIGHT_COLOR := Color(1.0, 1.0, 1.0)
const LIGHT_ROTATION := Vector3(-0.7, -0.6, 0.0)


func build_world(root: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation = LIGHT_ROTATION
	sun.light_color = LIGHT_COLOR
	root.add_child(sun)
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = AMBIENT
	env.ambient_light_energy = 1.0
	env.background_mode = Environment.BG_CLEAR_COLOR
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)


## The original colours nothing by damage.
func apply_level(_mi: MeshInstance3D, _level: int) -> void:
	pass
