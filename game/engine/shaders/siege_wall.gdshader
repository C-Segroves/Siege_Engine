// The wall of the siege's safe area (engine/extraction/siege/siege_zone_fx.gd): a translucent red cylinder with moving
// stripes, drawn over the border so everyone sees where the ground turns deadly.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, fog_disabled;

uniform vec3 wall_color : source_color = vec3(1.0, 0.14, 0.08);
uniform float stripes = 90.0;
uniform float base_alpha = 0.2;
uniform float stripe_alpha = 0.3;

void fragment() {
	float across = 0.5 + 0.5 * sin(UV.x * stripes * 3.1415926 + TIME * 0.9);
	float rising = 0.5 + 0.5 * sin(UV.y * 40.0 - TIME * 1.6);
	ALBEDO = wall_color;
	ALPHA = base_alpha + stripe_alpha * across * rising;
}
