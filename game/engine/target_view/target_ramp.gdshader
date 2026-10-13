// Target view, cockpit look: each part is drawn in the 3 shades of its damage level's palette ramp
// (DamageLevels), lit by a fixed key light, so the 3D model matches the 2D damage diagrams pixel for pixel.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform vec3 shade_dark : source_color;
uniform vec3 shade_mid : source_color;
uniform vec3 shade_bright : source_color;
// Key light in view space (from the upper left, towards the viewer).
uniform vec3 light_dir = vec3(-0.45, 0.65, 0.6);
uniform float bright_above = 0.55;
uniform float mid_above = 0.05;

void fragment() {
	vec3 n = normalize(NORMAL);
	float lit = dot(n, normalize(light_dir));
	ALBEDO = lit > bright_above ? shade_bright : (lit > mid_above ? shade_mid : shade_dark);
}
