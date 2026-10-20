// Unified lit material, opaque / alpha-tested (docs/RENDER_UNIFICATION.md section 3).
shader_type spatial;
#include "res://engine/shaders/unified_lit_body.gdshaderinc"

void fragment() {
	vec4 c = unified_lit_sample(UV);
	ROUGHNESS = 0.9;
	if (self_lit) {
		ALBEDO = vec3(0.0);
		SPECULAR = 0.0;
		EMISSION = c.rgb;
	} else {
		ALBEDO = c.rgb;
	}
}
