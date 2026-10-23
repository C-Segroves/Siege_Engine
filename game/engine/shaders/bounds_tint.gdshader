// The red wash over everything while the local player is outside the combat area (engine/bounds_visual/bounds_tint.gd).
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount = 0.0;

void fragment() {
	vec3 scene = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	float grey = dot(scene, vec3(0.3, 0.59, 0.11));
	vec3 red = vec3(grey * 1.3 + 0.12, grey * 0.35, grey * 0.3);
	float edge = smoothstep(0.2, 0.9, distance(UV, vec2(0.5)));
	COLOR = vec4(mix(scene, red, amount * (0.65 + 0.35 * edge)), 1.0);
}
