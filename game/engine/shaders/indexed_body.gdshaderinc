// Palette-indexed texturing with the original 3Space lighting: the light intensity
// I = (1 - n.L) / 2 selects one of the palette remap tables (texlight rows), then the palette gives RGB.
// Earthsiege 1 builds 8 tables, level 7*I/255 (DBSIM 0x5410c); Earthsiege 2 uses WORLD<n>.RMP's
// 32 light levels, level (31*I)>>8 (DBSIM 0x468054). Both are int(I * (rows - 1)).
global uniform vec3 sun_dir;   // direction the light travels, world space
#include "res://engine/shaders/palette_point_lights.gdshaderinc"

uniform sampler2D index_tex : filter_nearest, repeat_enable;
uniform sampler2D palette : source_color, filter_nearest;
uniform sampler2D tex_light : filter_nearest;   // 256 x light levels, value = remapped index
uniform bool lit = true;
uniform bool index0_transparent = true;
uniform vec2 uv_scale = vec2(1.0);

void fragment() {
	int i = int(round(texture(index_tex, UV * uv_scale).r * 255.0));
	if (index0_transparent && i == 0) {
		discard;
	}
	if (lit) {
		vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		float intensity = clamp((1.0 - dot(wn, sun_dir)) * 0.5 + palette_point_light(world_pos), 0.0, 1.0);
		int top_level = textureSize(tex_light, 0).y - 1;
		int level = clamp(int(intensity * float(top_level)), 0, top_level);
		i = int(round(texelFetch(tex_light, ivec2(i, level), 0).r * 255.0));
	}
	ALBEDO = texelFetch(palette, ivec2(i, 0), 0).rgb;
}
