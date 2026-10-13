// Procedural surfaces of the Herc hangar (HangarBay): no textures, everything from world position.
// kind 0 steel panels (seams, grime, rust streaks), 1 concrete floor with bay markings,
// 2 hazard stripes, 3 painted metal (rust / orange accents), 4 floor grating.
shader_type spatial;

uniform int kind = 0;
uniform vec3 base_color : source_color = vec3(0.24, 0.28, 0.33);
uniform vec3 rust_color : source_color = vec3(0.42, 0.18, 0.07);
uniform float rust_amount = 0.35;
uniform vec2 panel_size = vec2(2.4, 1.6);
uniform float metallic_amount = 0.55;
// floor markings: bay half width (x), bay front edge (z), turntable ring radius
uniform vec3 bay = vec3(6.0, 6.0, 4.0);

varying vec3 wpos;
varying vec3 wnrm;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int k = 0; k < 4; k++) {
		s += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// planar coordinates on the dominant axis (u along the surface, v up where possible)
vec2 planar() {
	vec3 n = abs(wnrm);
	if (n.y >= n.x && n.y >= n.z) {
		return wpos.xz;
	}
	if (n.x >= n.z) {
		return vec2(wpos.z, wpos.y);
	}
	return vec2(wpos.x, wpos.y);
}

float line_mask(float c, float w) {
	return 1.0 - smoothstep(0.0, w, abs(c));
}

void fragment() {
	vec2 uv = planar();
	float grime = fbm(uv * 0.55 + 13.0);
	vec3 col = base_color;
	float rough = 0.7;
	float metal = metallic_amount;
	if (kind == 0 || kind == 3) {
		// panels with dark seams and rivet rows
		vec2 g = fract(uv / panel_size);
		float seam = max(line_mask(g.x, 0.012) + line_mask(1.0 - g.x, 0.012), line_mask(g.y, 0.015) + line_mask(1.0 - g.y, 0.015));
		vec2 pid = floor(uv / panel_size);
		col *= 0.82 + 0.3 * hash(pid);
		col *= 0.7 + 0.45 * grime;
		// rust running down from seams and the floor line
		float streak = vnoise(vec2(uv.x * 4.0, uv.y * 0.18)) * (0.6 + 0.6 * vnoise(uv * 0.7));
		float low = 1.0 - smoothstep(0.0, 2.2, wpos.y);
		float r = clamp(smoothstep(0.55, 0.95, streak + rust_amount * 0.35) * rust_amount * 1.6 + low * rust_amount * grime, 0.0, 1.0);
		col = mix(col, rust_color * (0.6 + 0.6 * grime), r);
		col *= 1.0 - seam * 0.55;
		// scratches through the paint (painted metal shows steel)
		if (kind == 3) {
			float sc = smoothstep(0.78, 0.86, vnoise(vec2(uv.x * 9.0 + uv.y * 3.0, uv.y * 1.5)));
			col = mix(col, vec3(0.35, 0.36, 0.38), sc * 0.6);
		}
		rough = mix(0.45, 0.9, r + (1.0 - grime) * 0.3);
		metal = metallic_amount * (1.0 - r);
	} else if (kind == 1) {
		// concrete slabs
		col = base_color * (0.72 + 0.42 * fbm(uv * 0.35)) * (0.9 + 0.2 * vnoise(uv * 7.0));
		vec2 slab = fract(uv / 6.0);
		float seam = line_mask(slab.x, 0.004) + line_mask(1.0 - slab.x, 0.004) + line_mask(slab.y, 0.004) + line_mask(1.0 - slab.y, 0.004);
		col *= 1.0 - clamp(seam, 0.0, 1.0) * 0.5;
		float oil = smoothstep(0.62, 0.75, fbm(uv * 0.22 + 4.0));
		col *= 1.0 - oil * 0.45;
		// painted bay: yellow outline, hazard band at the front edge, turntable ring
		float wear = smoothstep(0.25, 0.55, fbm(uv * 1.7 + 7.0));
		vec3 yellow = vec3(0.86, 0.62, 0.08);
		float ax = abs(wpos.x);
		float inside = step(ax, bay.x + 0.15) * step(-bay.y - 3.0, wpos.z) * step(wpos.z, bay.y + 0.15);
		float outline = inside * max(line_mask(ax - bay.x, 0.14), line_mask(wpos.z - bay.y, 0.14) * step(ax, bay.x));
		float back = step(ax, bay.x) * line_mask(wpos.z + bay.y + 3.0, 0.14);
		float band = step(ax, bay.x) * step(bay.y + 0.4, wpos.z) * step(wpos.z, bay.y + 1.6);
		float stripes = step(0.5, fract((wpos.x + wpos.z) * 0.55));
		float rr = length(wpos.xz);
		float ring = line_mask(rr - bay.z, 0.09) + line_mask(rr - bay.z - 0.35, 0.05);
		col = mix(col, yellow, clamp(outline + back + ring * 0.8, 0.0, 1.0) * wear);
		col = mix(col, mix(vec3(0.05), yellow, stripes), band * wear);
		rough = 0.85 - oil * 0.4;
		metal = 0.0;
	} else if (kind == 2) {
		float s = step(0.5, fract((uv.x + uv.y) * 1.1));
		col = mix(vec3(0.04, 0.04, 0.04), vec3(0.85, 0.6, 0.08), s);
		col *= 0.65 + 0.5 * grime;
		col = mix(col, rust_color * 0.6, smoothstep(0.6, 0.8, vnoise(uv * 3.0)) * 0.5);
		rough = 0.75;
		metal = 0.2;
	} else {
		// grating: bright bars, dark holes
		vec2 g = fract(uv * 5.0);
		float bar = max(line_mask(g.x - 0.5, 0.12), line_mask(g.y - 0.5, 0.12));
		col = base_color * mix(0.25, 1.0, bar) * (0.7 + 0.4 * grime);
		rough = 0.6;
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = metal;
}
