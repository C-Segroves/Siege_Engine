class_name TargetFlatPaint
extends TargetPaint
## The remake's standard target picture for every display without an original one of its own (the plain HUD:
## soldiers, Tribes vehicles, vehicles without a cockpit; non-Herc targets): the live model without textures,
## each part flat-shaded in three shades of its damage level's colour (DamageLevels.COLORS: the Earthsiege
## damage diagram colours, green / yellow / orange / red / dark grey), lit by a fixed key light like the cockpit
## ramp pictures (TargetRampPaint), so every game reads damage the same way.

const RAMP_SHADER := preload("res://engine/target_view/target_ramp.gdshader")
const SHADE_UNIFORMS := ["shade_dark", "shade_mid", "shade_bright"]
## Dark / mid / bright shade of a level colour (mid = the colour itself).
const SHADE_FACTORS := [0.6, 1.0, 1.45]

var _materials: Array = []


func _init() -> void:
	for level in DamageLevels.LEVEL_COUNT:
		var m := ShaderMaterial.new()
		m.shader = RAMP_SHADER
		for k in SHADE_UNIFORMS.size():
			m.set_shader_parameter(SHADE_UNIFORMS[k], make_shade(level, k))
		_materials.append(m)


## Shade `k` (0 dark .. 2 bright) of damage level `level`.
static func make_shade(level: int, k: int) -> Color:
	var c: Color = DamageLevels.COLORS[level]
	var f: float = SHADE_FACTORS[k]
	return Color(minf(c.r * f, 1.0), minf(c.g * f, 1.0), minf(c.b * f, 1.0))


func apply_level(mi: MeshInstance3D, level: int) -> void:
	mi.material_override = _materials[level]
