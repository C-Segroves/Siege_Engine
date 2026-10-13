// 3Space point lights (PaletteLights, weapon_fx.md 2.1): each raises I by I_light x min(1, full / d) within its cutoff.
global uniform sampler2D palette_lights : filter_nearest;
global uniform int palette_light_count;

float palette_point_light(vec3 world_pos) {
	float add = 0.0;
	for (int i = 0; i < palette_light_count; i++) {
		vec4 pc = texelFetch(palette_lights, ivec2(i, 0), 0);
		vec4 kf = texelFetch(palette_lights, ivec2(i, 1), 0);
		float d = distance(world_pos, pc.xyz);
		if (d < pc.w) {
			add += kf.x * min(1.0, kf.y / max(d, 0.001));
		}
	}
	return add;
}
