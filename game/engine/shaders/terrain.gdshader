// Lit heightfield terrain of the engine map schema (MapTerrain): the map's baked colour map plus procedural variation
// in world space, so a repeating or low-resolution colour map shows no tile grid from the air:
//   warp   the colour map's lookup is bent by a slow noise, so the straight tile seams wander
//   macro  large slow patches of brightness and warmth (hundreds of metres, visible from the air)
//   mid    patches of tens of metres, fading out with distance
//   fine   grit of a few metres, only near the camera (it would shimmer farther away)
// Strengths come from the map's terrain "detail" record (MapTerrain.DETAIL_DEFAULTS).
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;   // four seamless noise fields (r g b a)
uniform vec4 base_color : source_color = vec4(0.45, 0.42, 0.36, 1.0);
uniform float has_albedo = 1.0;
uniform float warp = 0.0;            // colour-map UV units
uniform float macro_period = 7000.0; // metres per noise tile of each scale
uniform float mid_period = 1100.0;
uniform float fine_period = 140.0;
uniform float grit_period = 14.0;
uniform float macro_amount = 0.2;
uniform float mid_amount = 0.12;
uniform float fine_amount = 0.1;
uniform float grit_amount = 0.1;
uniform float warm_amount = 0.08;    // macro hue drift: warmer in some patches, cooler in others
uniform float mid_fade_start = 400.0;
uniform float mid_fade_end = 4000.0;
uniform float grit_fade_start = 40.0;
uniform float grit_fade_end = 220.0;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 uv = UV;
	if (warp > 0.0) {
		vec2 w = texture(noise_tex, world_xz / (macro_period * 0.35) + vec2(0.37, 0.61)).ga - 0.5;
		uv += w * 2.0 * warp;
	}
	vec3 col = has_albedo > 0.5 ? texture(albedo_tex, uv).rgb : base_color.rgb;
	float d = length(VERTEX);
	vec4 nm = texture(noise_tex, world_xz / macro_period);
	vec4 nd = texture(noise_tex, world_xz / mid_period + vec2(0.5, 0.25));
	vec4 nf = texture(noise_tex, world_xz / fine_period + vec2(0.13, 0.71));
	vec4 ng = texture(noise_tex, world_xz / grit_period + vec2(0.83, 0.29));
	float mid_w = 1.0 - smoothstep(mid_fade_start, mid_fade_end, d) * 0.7;
	float grit_w = 1.0 - smoothstep(grit_fade_start, grit_fade_end, d);
	float fine_w = 1.0 - smoothstep(mid_fade_start, mid_fade_end, d);
	float lum = 1.0 + (nm.r - 0.5) * 2.0 * macro_amount
			+ (nd.g - 0.5) * 2.0 * mid_amount * mid_w
			+ (nf.b - 0.5) * 2.0 * fine_amount * fine_w
			+ (ng.a - 0.5) * 2.0 * grit_amount * grit_w;
	float warm = (nm.b - 0.5) * 2.0 * warm_amount;
	ALBEDO = col * lum * vec3(1.0 + warm, 1.0, 1.0 - warm);
	ROUGHNESS = 1.0;
}
