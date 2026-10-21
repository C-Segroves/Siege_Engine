// The shared cloak (engine/stealth/cloak_visual.gd). Drawn the way Tribes 2 draws a cloaked ShapeBase: the model turns
// see-through while a scrolling "special/cloakTexture" (the original liquid-metal bump map, hard-coded in Tribes2.exe)
// bends the scene behind it and glints on it, fading in and out as `amount` runs 0..1 (docs/formats/cloaking.md).
// Without the original texture (Starsiege has none: its cloak is engine code; Tribes 2 not installed) a procedural
// liquid pattern stands in. Within `reveal_range` metres of the camera the body is seen plainly again (the cloak is a
// local effect). One material per cloaked unit; no per-game code.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D cloak_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_texture = false;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float reveal_range = 0.0;
// pattern repeats per metre of the unit's surface, and the scroll in repeats per second
uniform float tile_per_m = 0.7;
uniform vec2 scroll = vec2(0.045, 0.07);
// how far the pattern's slope bends the scene behind, in metres at the unit (scaled by distance to screen units)
uniform float refract_m = 0.35;
uniform float glint_strength = 0.25;
uniform float rim_strength = 0.35;
uniform vec3 tint : source_color = vec3(0.88, 0.95, 1.0);
uniform vec3 body_color : source_color = vec3(0.32, 0.36, 0.34);
uniform vec3 outline_color : source_color = vec3(0.35, 0.9, 1.0);
// 0 for every shipped game (no original shows an ally outline); a game's data may turn it on.
uniform float outline_strength = 0.0;

varying vec3 surface_m;

float fallback_pattern(vec2 uv) {
	vec2 p = uv * 6.2831853;
	float v = sin(p.x + 1.6 * sin(p.y + 1.3)) * sin(p.y + 1.6 * sin(p.x + 0.7));
	float w = sin(2.0 * p.x + 2.2 * sin(2.0 * p.y + 2.1)) * sin(2.0 * p.y - 1.9 * sin(p.x));
	return 0.5 + 0.5 * sin((v * 0.65 + w * 0.35) * 3.2);
}

float pattern(vec2 uv) {
	return use_texture ? texture(cloak_tex, uv).r : fallback_pattern(uv);
}

void vertex() {
	// metres from the unit's origin: the pattern sticks to the body, so it moves with him
	surface_m = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz - MODEL_MATRIX[3].xyz;
}

void fragment() {
	vec3 n = normalize(NORMAL);
	float facing = clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.5);
	float depth = max(-VERTEX.z, 1.0);
	float near = reveal_range > 0.0 ? 1.0 - smoothstep(reveal_range * 0.5, reveal_range, length(VERTEX)) : 0.0;
	float hidden = amount * (1.0 - near);

	vec2 uv = (surface_m.xy + surface_m.zy * 0.7) * tile_per_m + n.xy * 0.35 + scroll * TIME;
	float h = pattern(uv);
	vec2 e = vec2(0.012, 0.0);
	vec2 slope = vec2(pattern(uv + e.xy) - pattern(uv - e.xy), pattern(uv + e.yx) - pattern(uv - e.yx));
	// metres of bend at the unit -> screen units: the unit's apparent size falls with distance
	vec2 bent = SCREEN_UV + (slope * refract_m * 0.35 + n.xy * 0.02) * hidden / depth;
	vec3 behind = textureLod(screen_tex, bent, 0.0).rgb * tint;

	// the glints: bright ridges of the pattern ride on the see-through body
	float glint = pow(h, 3.0) * glint_strength + (h - 0.5) * 0.18;
	vec3 cloaked = behind * (1.0 + glint) + vec3(rim * rim_strength);

	vec3 flat_body = body_color * (0.45 + 0.55 * clamp(dot(n, normalize(vec3(0.3, 0.8, 0.5))), 0.0, 1.0));
	vec3 col = mix(flat_body, cloaked, hidden);
	ALBEDO = mix(col, outline_color, rim * outline_strength * amount);
	ALPHA = 1.0;
}
