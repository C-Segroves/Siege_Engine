// Six-face skybox from a map's sky images (cubemap). A map with a day cycle (DayCycleLight) also tints the picture,
// shows stars at night and one disc: the sun by day, the moon by night. Without those the picture shows as it is.
shader_type sky;

uniform samplerCube sky_cube : source_color, filter_linear;
uniform vec3 tint = vec3(1.0);
uniform float star_amount = 0.0;
uniform vec3 body_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 body_color = vec3(0.0);
uniform float body_cos = 0.9996;

float star_field(vec3 dir) {
	vec3 cell = floor(dir * 260.0);
	float h = fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
	return step(0.9965, h) * (h - 0.9965) / 0.0035;
}

void sky() {
	vec3 col = texture(sky_cube, EYEDIR).rgb * tint;
	if (star_amount > 0.0) {
		col += vec3(0.9, 0.95, 1.0) * star_field(EYEDIR) * star_amount * step(0.02, EYEDIR.y) * 0.9;
	}
	float c = dot(EYEDIR, normalize(body_dir));
	float disc = smoothstep(body_cos, body_cos + (1.0 - body_cos) * 0.35, c);
	float halo = pow(max(c, 0.0), 60.0) * 0.18;
	col += body_color * (disc + halo);
	COLOR = col;
}
