// Unified material, nearest filtering (palette art of the 3Space games).
shader_type spatial;
render_mode unshaded;

uniform sampler2DArray albedo_array : source_color, filter_nearest, repeat_enable;
#include "res://engine/shaders/unified_body.gdshaderinc"

void fragment() {
	vec3 a;
	float al;
	unified_fragment(albedo_array, INV_VIEW_MATRIX, NORMAL, VERTEX, UV, a, al);
	ALBEDO = a;
}
