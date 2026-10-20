// Unified lit material, alpha blended (damage decals: alpha_mul 0 hides them until a damage state shows them).
shader_type spatial;
render_mode depth_draw_opaque;
#include "res://engine/shaders/unified_lit_body.gdshaderinc"

void fragment() {
	vec4 c = unified_lit_sample(UV);
	ROUGHNESS = 0.9;
	ALBEDO = c.rgb;
	ALPHA = c.a * alpha_mul;
}
