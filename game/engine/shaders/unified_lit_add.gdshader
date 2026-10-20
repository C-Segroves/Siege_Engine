// Unified material, additive (Torque "additive" flag): unshaded glow.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never;
#include "res://engine/shaders/unified_lit_body.gdshaderinc"

void fragment() {
	vec4 c = unified_lit_sample(UV);
	ALBEDO = c.rgb;
	ALPHA = c.a * alpha_mul;
}
