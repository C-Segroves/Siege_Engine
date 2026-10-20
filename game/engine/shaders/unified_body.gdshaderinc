// The one runtime material (docs/RENDER_UNIFICATION.md section 3). Albedo is true colour with the game's palette
// baked in at import: layer = light level for 3Space ramps (ramp_levels > 0), a single layer for Torque/solid
// materials, which are lit lambert from the scene globals. Reads only global uniforms, so a model needs no
// knowledge of the scene it is in; scene_tonemap undoes Godot's FILMIC curve so colours stay as authored.
global uniform vec3 sun_dir;          // direction the light travels, world space
global uniform vec3 scene_sun_color;
global uniform vec3 scene_ambient;
global uniform int scene_tonemap;     // 0 linear, 1 filmic (bridge until every scene is linear)
#include "res://engine/shaders/palette_point_lights.gdshaderinc"

uniform int ramp_levels = 0;          // 0 = lambert
uniform float ramp_scale = 7.0;       // level = int(I * ramp_scale)
uniform bool self_lit = false;        // unshaded: albedo as is
uniform float alpha_cut = 0.0;        // > 0: alpha test
uniform vec2 uv_scale = vec2(1.0);

// Godot's FILMIC (exposure_bias 2, white 1) solved for the linear input that displays as `t`.
vec3 inverse_filmic(vec3 t) {
	const float A = 0.22 * 4.0;
	const float B = 0.30 * 2.0;
	const float C = 0.10;
	const float D = 0.20;
	const float FE = 0.01;
	const float FF = 0.30;
	float white = ((A + C * B + D * FE) / (A + B + D * FF)) - FE / FF;
	vec3 y = clamp(t, 0.0, 1.0) * white + FE / FF;
	vec3 a = A * (y - 1.0);
	vec3 b = B * (y - C);
	vec3 c = y * D * FF - D * FE;
	vec3 disc = max(b * b - 4.0 * a * c, 0.0);
	return max((-b - sqrt(disc)) / (2.0 * min(a, vec3(-1e-6))), 0.0);
}

void unified_fragment(sampler2DArray tex, mat4 inv_view, vec3 view_normal, vec3 view_pos, vec2 base_uv, out vec3 albedo_out, out float alpha_out) {
	vec3 wn = normalize((inv_view * vec4(view_normal, 0.0)).xyz);
	vec3 world_pos = (inv_view * vec4(view_pos, 1.0)).xyz;
	vec2 uv = base_uv * uv_scale;
	vec4 c;
	if (ramp_levels > 0 && !self_lit) {
		float i = clamp((1.0 - dot(wn, sun_dir)) * 0.5 + palette_point_light(world_pos), 0.0, 1.0);
		int level = min(int(i * ramp_scale), ramp_levels - 1);
		c = texture(tex, vec3(uv, float(level)));
	} else {
		c = texture(tex, vec3(uv, 0.0));
		if (!self_lit && ramp_levels == 0) {
			c.rgb *= scene_ambient + scene_sun_color * max(dot(wn, -sun_dir), 0.0);
		}
	}
	if (alpha_cut > 0.0 && c.a < alpha_cut) {
		discard;
	}
	albedo_out = scene_tonemap == 1 ? inverse_filmic(c.rgb) : c.rgb;
	alpha_out = c.a;
}
