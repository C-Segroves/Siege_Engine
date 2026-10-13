// Earthsiege 2 heightmap terrain (DBSIM 1.0): every 128 m texture tile shows ground texture 0 or 1
// (random material, MAT0.DAT); textured polys are lit through the world's RMP remap table at the integer level
// (31*I)>>8 with I = 256*(1 - n.L)/2 of the poly's own (face) normal (es2.md 3.3: one level per poly, no blend).
// The textures arrive baked at the flat-ground level, so the per-level brightness of RMP is applied as
// light_curve[level] / 1.0 (light_curve[flat] == 1). The sun is the global "sun_dir" every palette shader uses.
// Distance haze comes from the Environment fog (RMP haze rows fade to the same colour).
shader_type spatial;
render_mode unshaded, cull_back;

uniform sampler2D tex0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D matmap : filter_nearest, repeat_disable;   // L8: 0 -> tex0, 1 -> tex1
uniform vec2 mat_tiles = vec2(1.0, 1.0);                      // tiles (x, original y)
uniform float tile_m = 128.0;                                 // metres per texture repeat
global uniform vec3 sun_dir;                                  // light vector (into the scene), engine axes
uniform float light_curve[32];

varying vec3 wpos;
varying vec3 wnrm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// texture u = x / texel, v = z / texel (original v runs against +y = north)
	vec2 uv = wpos.xz / tile_m;
	vec2 tile = floor(vec2(wpos.x, -wpos.z) / tile_m);
	ivec2 ti = ivec2(clamp(tile, vec2(0.0), mat_tiles - 1.0));
	float m = texelFetch(matmap, ti, 0).r;
	vec3 c = mix(texture(tex0, uv).rgb, texture(tex1, uv).rgb, step(0.5, m));
	vec3 face = normalize(cross(dFdy(wpos), dFdx(wpos)));
	face = dot(face, wnrm) < 0.0 ? -face : face;
	int I = int(clamp(128.0 * (1.0 - dot(face, sun_dir)), 0.0, 255.0));
	float f = light_curve[clamp((31 * I) >> 8, 0, 31)];
	ALBEDO = c * pow(f, 2.2);   // curve is an sRGB brightness ratio; c is linear
}
