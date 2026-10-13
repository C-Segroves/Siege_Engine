// Textured ground: only the low 4 bits of each texel are used; the distance haze band (0..14)
// selects a 16-entry palette table that fades toward the horizon colour. An orthographic camera (the command map's
// top-down view) sees the near band everywhere.
shader_type spatial;
render_mode unshaded, fog_disabled;

uniform sampler2D index_tex : filter_nearest, repeat_enable;
uniform sampler2D palette : source_color, filter_nearest;
uniform sampler2D ground_lut : filter_nearest;   // 16 x 15
uniform float band_dist[15];                      // metres
uniform float texel_size = 1.0;                   // metres per texel

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = world_pos.xz / (texel_size * 256.0);
	int t = int(round(texture(index_tex, uv).r * 255.0)) & 15;
	float d = PROJECTION_MATRIX[3][3] > 0.5 ? 0.0 : length(VERTEX);
	int band = 0;
	for (int k = 0; k < 14; k++) {
		if (d >= band_dist[k]) {
			band = k + 1;
		}
	}
	int i = int(round(texelFetch(ground_lut, ivec2(t, band), 0).r * 255.0));
	ALBEDO = texelFetch(palette, ivec2(i, 0), 0).rgb;
}
