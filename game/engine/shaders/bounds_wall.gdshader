// The area edge as seen near it (engine/bounds_visual/bounds_wall.gd): a translucent red energy curtain with a slowly
// scrolling hex pattern, strongest nearest the player and fading along the wall away from him.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

uniform vec3 wall_color : source_color = vec3(1.0, 0.12, 0.06);
uniform vec3 player_pos = vec3(0.0);
uniform float strength = 0.0;
uniform float fade_along = 100.0;
uniform float scroll = 1.0;
uniform float cell = 6.0;

varying vec3 world_pos;

// Distance to the nearest hex cell edge in a unit-size tiling (0 on an edge).
float hex_edge(vec2 p) {
	vec2 s = vec2(1.0, 1.7320508);
	vec2 a = mod(p, s) - s * 0.5;
	vec2 b = mod(p - s * 0.5, s) - s * 0.5;
	vec2 g = dot(a, a) < dot(b, b) ? a : b;
	vec2 q = abs(g);
	return 0.5 - max(dot(q, s * 0.5), q.x);
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 flow = vec2(0.0, TIME * 1.5 * scroll);
	float edge = hex_edge((UV + flow) / cell);
	float lines = 1.0 - smoothstep(0.0, 0.07, edge);
	float d = distance(world_pos.xz, player_pos.xz);
	float near = 1.0 - smoothstep(0.0, fade_along, d);
	float rise = 1.0 - smoothstep(0.0, 1.0, UV.y / 160.0);
	ALBEDO = wall_color + vec3(0.0, 0.25, 0.2) * lines;
	ALPHA = strength * near * (0.22 + 0.6 * lines) * (0.5 + 0.5 * rise);
}
