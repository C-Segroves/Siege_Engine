class_name TargetRampPaint
extends TargetPaint
## Cockpit look: parts drawn only in the palette shades of their damage level's ramp (the colours the
## original damage diagrams use: Earthsiege 1 DamageLevels.RAMP_BASES, 3 shades each; Earthsiege 2 one
## colour per level), so a rendered model blends with the 2D art.

const RAMP_SHADER := preload("res://engine/target_view/target_ramp.gdshader")
const SHADE_UNIFORMS := ["shade_dark", "shade_mid", "shade_bright"]
## A single-colour level (Earthsiege 2) is shaded by darkening its colour (the original draws no 3D
## models there; the factors keep the model's form readable).
const SINGLE_COLOR_SHADES := [0.55, 0.78, 1.0]

var _materials: Array = []


## `palette`: the host cockpit's 256 colours; `bases` / `shades`: the palette ramp of each damage level.
func _init(palette: Array, bases: Array = DamageLevels.RAMP_BASES, shades := DamageLevels.SHADES) -> void:
	for level in DamageLevels.LEVEL_COUNT:
		var m := ShaderMaterial.new()
		m.shader = RAMP_SHADER
		for k in SHADE_UNIFORMS.size():
			m.set_shader_parameter(SHADE_UNIFORMS[k], _make_shade(palette, int(bases[level]), k, shades))
		_materials.append(m)


static func _make_shade(palette: Array, base: int, k: int, shades: int) -> Color:
	if shades > 1:
		return _palette_color(palette, base + mini(k, shades - 1))
	var c := _palette_color(palette, base)
	return Color(c.r * SINGLE_COLOR_SHADES[k], c.g * SINGLE_COLOR_SHADES[k], c.b * SINGLE_COLOR_SHADES[k], c.a)


static func _palette_color(palette: Array, i: int) -> Color:
	return palette[i] if i >= 0 and i < palette.size() else DamageLevels.COLORS[DamageLevels.DESTROYED]


func apply_level(mi: MeshInstance3D, level: int) -> void:
	mi.material_override = _materials[level]
