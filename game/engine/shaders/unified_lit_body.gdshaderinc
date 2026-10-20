// Shared fragment of the unified lit materials (true-colour Torque / Darkstar art): one Texture2DArray layer,
// lit by the scene's own lights so map shadows, sun colour and ambient apply with no per-game code. Same shading
// as the old StandardMaterial3D (roughness 0.9), so the Darkstar/Torque look is preserved.
uniform sampler2DArray albedo_array : source_color, filter_linear_mipmap, repeat_enable;
uniform bool self_lit = false;        // Torque "self-illuminating": albedo as emission, not lit
uniform float alpha_cut = 0.0;        // > 0: alpha test (Torque "translucent" scissor)
uniform float alpha_mul = 1.0;        // per-material fade (damage decals are 0 until damaged)
uniform vec2 uv_scale = vec2(1.0);

vec4 unified_lit_sample(vec2 uv) {
	vec4 c = texture(albedo_array, vec3(uv * uv_scale, 0.0));
	if (alpha_cut > 0.0 && c.a < alpha_cut) {
		discard;
	}
	return c;
}
