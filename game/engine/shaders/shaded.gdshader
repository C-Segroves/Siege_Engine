// 3Space "shaded" polygon: colour = palette[list[(I * len) >> 8]], I = (1 - n.L) / 2.
// shade_lists is 32 x 256: row = list index, columns = list resampled to 32 steps.
shader_type spatial;
render_mode unshaded;

global uniform vec3 sun_dir;

uniform sampler2D palette : source_color, filter_nearest;
uniform sampler2D shade_lists : filter_nearest;
uniform int list_index = 0;

void fragment() {
	vec3 wn = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float intensity = clamp((1.0 - dot(wn, sun_dir)) * 0.5, 0.0, 0.999);
	int col = int(intensity * 32.0);
	int i = int(round(texelFetch(shade_lists, ivec2(col, list_index), 0).r * 255.0));
	ALBEDO = texelFetch(palette, ivec2(i, 0), 0).rgb;
}
