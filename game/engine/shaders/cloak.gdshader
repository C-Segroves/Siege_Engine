// The shared cloak (engine/stealth/cloak_visual.gd): the body shows the scene behind it, bent by its own surface and
// shimmering, and fades from the plain flat-shaded body as `amount` rises. Within `reveal_range` metres of the camera
// the body is seen plainly again (Tribes 2: the cloak is a local effect, an enemy standing next to the wearer sees
// him; docs/formats/cloaking.md). One material per cloaked unit; no per-game code.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float reveal_range = 0.0;
uniform float distortion = 0.035;
uniform float shimmer = 0.006;
uniform float rim_strength = 0.3;
uniform vec3 body_color : source_color = vec3(0.32, 0.36, 0.34);
uniform vec3 outline_color : source_color = vec3(0.35, 0.9, 1.0);
// 0 for every shipped game (no original shows an ally outline); a game's data may turn it on.
uniform float outline_strength = 0.0;

void fragment() {
	vec3 n = normalize(NORMAL);
	float facing = clamp(dot(n, normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.5);
	float near = reveal_range > 0.0 ? 1.0 - smoothstep(reveal_range * 0.5, reveal_range, length(VERTEX)) : 0.0;
	float hidden = amount * (1.0 - near);
	vec2 wobble = vec2(sin(TIME * 3.1 + VERTEX.y * 5.0), cos(TIME * 2.3 + VERTEX.x * 5.0)) * shimmer;
	vec2 bent = SCREEN_UV + (n.xy * distortion + wobble) * hidden;
	vec3 behind = textureLod(screen_tex, bent, 0.0).rgb;
	vec3 flat_body = body_color * (0.45 + 0.55 * clamp(dot(n, normalize(vec3(0.3, 0.8, 0.5))), 0.0, 1.0));
	ALBEDO = mix(flat_body, behind, hidden);
	EMISSION = vec3(0.0);
	ALPHA = 1.0;
	// the rim keeps a faint edge so a cloaked unit can still be picked out up close, as the originals' shimmer does
	ALBEDO += vec3(rim * rim_strength * hidden);
	ALBEDO = mix(ALBEDO, outline_color, rim * outline_strength * amount);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
