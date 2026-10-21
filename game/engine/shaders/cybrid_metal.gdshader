// The Cybrid look (engine/extraction/siege/cybrid_look.gd): a dark brushed-metal body with a faint grid of panel seams
// that glow red and pulse, and a red rim, made entirely here (no copied art). It is a per-material override, so it works
// the same over the soldier bodies and the Hercs of every game.
shader_type spatial;
render_mode cull_back;

uniform vec3 base_color : source_color = vec3(0.2, 0.21, 0.24);
uniform vec3 glow_color : source_color = vec3(1.0, 0.1, 0.06);
uniform float panel_per_m = 2.4;
uniform float seam_width = 0.07;
uniform float pulse_speed = 1.7;
uniform float seam_glow = 1.4;
uniform float rim_glow = 0.55;

varying vec3 local_pos;
varying vec3 local_normal;
varying vec3 pulse_seed;

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

void vertex() {
	// metres in the piece's own axes: the shapes are modelled in the games' own units, so the node scale is applied
	vec3 to_metres = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	local_pos = VERTEX * to_metres;
	local_normal = NORMAL;
	pulse_seed = vec3(MODEL_MATRIX[3].x, MODEL_MATRIX[3].y, MODEL_MATRIX[3].z);
}

void fragment() {
	vec3 scaled = local_pos * panel_per_m;
	vec3 cell = floor(scaled);
	vec3 f = fract(scaled);
	float panel = hash31(cell);
	// seams run along the face: the axis the face stands across is left out, or a flat face would glow whole
	vec3 line = step(vec3(1.0 - seam_width), f);
	vec3 an = abs(local_normal);
	float edge = (an.x >= an.y && an.x >= an.z) ? max(line.y, line.z) : ((an.y >= an.z) ? max(line.x, line.z) : max(line.x, line.y));
	float brushed = 0.5 + 0.5 * sin(local_pos.y * 90.0 + panel * 6.2831853);
	float pulse = 0.55 + 0.45 * sin(TIME * pulse_speed + hash31(floor(pulse_seed)) * 6.2831853 + panel * 3.0);
	float rim = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
	ALBEDO = base_color * (0.75 + 0.5 * panel) * (0.9 + 0.1 * brushed);
	METALLIC = 0.88;
	ROUGHNESS = 0.32 + 0.28 * panel;
	EMISSION = glow_color * (edge * seam_glow * pulse + rim * rim_glow);
}
