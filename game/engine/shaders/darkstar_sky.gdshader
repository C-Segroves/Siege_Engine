// Darkstar sky (Starsiege: Tribes / Starsiege), see tools/darkstar_sky.py for the original geometry:
// a ring of 16 flat panels around the camera (corner k at first_corner - k * panel_deg, CCW from east,
// panel heights per ring radius band_bottom..band_top), flat-coloured cones above and below the ring,
// billboard planets, an optional procedural star field, haze toward the fog colour below the horizon.
shader_type sky;

const int MAX_PLANETS = 4;
const float STAR_GRID = 180.0;
const float STAR_DENSITY = 0.03;
const float STAR_BRIGHT_SHARE = 0.15; // of the stars in colors[0]; the next STAR_MID_SHARE in colors[1]
const float STAR_MID_SHARE = 0.3;
const float STAR_RADIUS = 0.11;
const float HAZE_BELOW = -0.06;

uniform sampler2D panels : source_color, filter_linear, repeat_enable;
uniform bool has_panels = false;
uniform float first_corner = 1.178097; // radians
uniform float panel_step = 0.392699;   // radians
uniform float band_bottom = -0.1;
uniform float band_top = 0.6;
uniform vec3 top_color : source_color = vec3(0.5, 0.6, 0.8);
uniform vec3 band_color : source_color = vec3(0.6, 0.6, 0.6);
uniform vec3 fog_color : source_color = vec3(0.6, 0.6, 0.6);

uniform int planet_count = 0;
uniform vec4 planet_dir_tan[MAX_PLANETS]; // xyz: unit direction, w: tan(angular radius)
uniform sampler2D planet_0 : source_color, filter_linear;
uniform sampler2D planet_1 : source_color, filter_linear;
uniform sampler2D planet_2 : source_color, filter_linear;
uniform sampler2D planet_3 : source_color, filter_linear;

uniform int star_mode = 0; // 0 none, 1 behind the panels, 2 in front of the sky (inFrontOfSky)
uniform vec3 star_colors[3];

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// Panel k is the chord from corner k to corner k + 1; returns (u, height per ring radius) of the ray.
vec2 panel_hit(vec2 d, float k) {
	float a0 = first_corner - k * panel_step;
	vec2 p0 = vec2(cos(a0), sin(a0));
	vec2 e = vec2(cos(a0 - panel_step), sin(a0 - panel_step)) - p0;
	float den = d.x * e.y - d.y * e.x;
	float u = (p0.x * d.y - p0.y * d.x) / den;
	float t = (p0.x * e.y - p0.y * e.x) / den;
	return vec2(u, t);
}

vec3 ring_color(vec3 dir) {
	vec2 d = vec2(dir.x, -dir.z); // Darkstar x east, y north
	float horiz = length(d);
	if (horiz < 1e-5) {
		return dir.y > 0.0 ? top_color : fog_color;
	}
	float ang = atan(d.y, d.x);
	float k = floor(mod((first_corner - ang) / panel_step, 16.0));
	vec2 hit = panel_hit(d, k);
	float z = hit.y * dir.y;
	if (z > band_top) {
		return top_color;
	}
	if (z < band_bottom || !has_panels) {
		return z < band_bottom ? fog_color : band_color;
	}
	// Keep v half a texel inside so the vertical repeat does not blend the top row with the bottom one.
	float half_texel = 0.5 / float(textureSize(panels, 0).y);
	float v = clamp((band_top - z) / (band_top - band_bottom), half_texel, 1.0 - half_texel);
	return texture(panels, vec2((k + clamp(hit.x, 0.0, 1.0)) / 16.0, v)).rgb;
}

vec4 planet_sample(int i, vec2 uv) {
	if (i == 0) return texture(planet_0, uv);
	if (i == 1) return texture(planet_1, uv);
	if (i == 2) return texture(planet_2, uv);
	return texture(planet_3, uv);
}

vec3 add_planets(vec3 col, vec3 dir) {
	for (int i = 0; i < MAX_PLANETS; i++) {
		if (i >= planet_count) {
			break;
		}
		vec3 pd = planet_dir_tan[i].xyz;
		float c = dot(dir, pd);
		if (c <= 0.0) {
			continue;
		}
		vec3 right = normalize(cross(pd, abs(pd.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 up = cross(right, pd);
		vec3 q = dir / c - pd;
		vec2 xy = vec2(dot(q, right), dot(q, up)) / planet_dir_tan[i].w;
		if (abs(xy.x) < 1.0 && abs(xy.y) < 1.0) {
			vec4 s = planet_sample(i, vec2(xy.x, -xy.y) * 0.5 + 0.5);
			col = mix(col, s.rgb, s.a);
		}
	}
	return col;
}

vec3 star(vec3 dir) {
	vec3 p = dir * STAR_GRID;
	vec3 cell = floor(p);
	float h = hash13(cell);
	if (h > STAR_DENSITY) {
		return vec3(0.0);
	}
	vec3 jitter = vec3(hash13(cell + 17.1), hash13(cell + 41.7), hash13(cell + 73.3));
	vec3 sp = normalize(cell + 0.15 + 0.7 * jitter) * STAR_GRID;
	float glow = 1.0 - smoothstep(0.0, STAR_RADIUS * STAR_GRID / 60.0, distance(p, sp));
	float share = h / STAR_DENSITY;
	int cls = share < STAR_BRIGHT_SHARE ? 0 : (share < STAR_BRIGHT_SHARE + STAR_MID_SHARE ? 1 : 2);
	return star_colors[cls] * glow;
}

void sky() {
	vec3 dir = normalize(EYEDIR);
	vec3 col = ring_color(dir);
	if (star_mode == 1 && dir.y > 0.0) {
		col += star(dir) * (1.0 - clamp(dot(col, vec3(0.333)) * 4.0, 0.0, 1.0));
	}
	col = add_planets(col, dir);
	if (star_mode == 2 && dir.y > 0.0) {
		col += star(dir);
	}
	col = mix(col, fog_color, smoothstep(0.0, HAZE_BELOW, dir.y));
	COLOR = col;
}
