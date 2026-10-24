// Unified lit material with a baked lightmap (Tribes: Vengeance BSP surfaces, docs/formats/tribes_vengeance.md "BSP lightmaps").
// The original multiplies texture, lightmap and a 2x overbright in gamma space (Direct3D 8 fixed function), so the product is
// formed in gamma space and converted back. The lightmap already holds every placed light, the zone ambient and the sun:
// the surface takes no scene light (no ambient, sun or point light) and shows the product as emission.
shader_type spatial;
#include "res://engine/shaders/unified_lit_body.gdshaderinc"

uniform sampler2D lightmap : filter_linear_mipmap, repeat_disable;   // gamma values, not source_color
uniform float lightmap_gain = 2.0;                                   // overbright: a texel of 0.5 leaves the texture unchanged
const float GAMMA = 2.2;

void fragment() {
	vec4 c = unified_lit_sample(UV);
	vec3 baked = texture(lightmap, UV2).rgb;
	vec3 gamma_colour = pow(c.rgb, vec3(1.0 / GAMMA)) * baked * lightmap_gain;
	ROUGHNESS = 0.9;
	SPECULAR = 0.0;
	ALBEDO = vec3(0.0);
	EMISSION = pow(gamma_colour, vec3(GAMMA));
}
