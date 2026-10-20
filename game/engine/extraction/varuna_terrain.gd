class_name VarunaTerrain
extends RefCounted
## The heightfield of the extraction map "Varuna's Fall" (maps/varuna.json "terrain"; docs/design/extraction_map_varuna.md),
## made from the map's seed and its region masks, so no height data is stored anywhere:
##   regions   five landscapes (north mountains, central plains, southern lakes, eastern broken uplands, western
##             cave mountains) blended by inverse distance to their centres; each has a noise recipe (kind)
##   features  impact craters, a mountain tarn basin, rivers (carved channels) and a southern coast
##   pads      every site (and outpost) is levelled to a flat pad with a smooth skirt
## Water is one box at water_level over the whole map (MapWater): wherever the ground is lower, there is a lake.
## Heights are in metres; x east, z south (north is -z).

const WEIGHT_POWER := 4.0
const WEIGHT_EPS := 0.08
const COARSE_STEP := 64.0

var def: Dictionary
var seed_value := 0
var water_level := 8.0
var regions: Array = []
var samples := 385
var square := 16.0
var origin := Vector2(-3072.0, -3072.0)
## [{center: Vector2, radius, skirt, height}] levelled places.
var pads: Array = []
var _noises: Array[FastNoiseLite] = []
var _detail: FastNoiseLite
var _heights := PackedFloat32Array()


static func make(map_def: Dictionary) -> VarunaTerrain:
	var t := VarunaTerrain.new()
	t.def = map_def
	var td: Dictionary = map_def.get("terrain", {})
	t.seed_value = int(map_def.get("seed", 1))
	t.water_level = float(td.get("water_level", 8.0))
	t.samples = int(td.get("samples", 385))
	t.square = float(td.get("square", 16.0))
	var b: Dictionary = map_def.get("bounds", {})
	t.origin = Vector2(float(b.min[0]), float(b.min[1])) if b.has("min") else t.origin
	t.regions = td.get("regions", [])
	for i in t.regions.size():
		t._noises.append(_make_noise(t.seed_value + i * 101, float(t.regions[i].get("freq", 0.001))))
	t._detail = _make_noise(t.seed_value + 7, 0.012)
	t._detail.fractal_octaves = 3
	t._make_pads()
	return t


static func _make_noise(noise_seed: int, freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	n.seed = noise_seed
	n.frequency = freq
	return n


## The pads: each site's disc, its outposts, set to the ground height at the centre (or the site's pad_h).
func _make_pads() -> void:
	var blend := float((def.get("terrain", {}) as Dictionary).get("pad_blend", 1.7))
	var raw: Array = []
	for s in def.get("sites", []):
		var c := Vector2(float(s.pos[0]), float(s.pos[1]))
		raw.append({"center": c, "radius": float(s.pad_radius), "h": s.get("pad_h")})
		for o in s.get("outposts", []):
			raw.append({"center": c + Vector2(float(o.dx), float(o.dz)), "radius": float(o.pad), "h": null})
	for r in raw:
		var h = r.h if r.h != null else _make_natural(r.center.x, r.center.y)
		h = maxf(float(h), water_level + 2.0)
		pads.append({"center": r.center, "radius": r.radius, "skirt": r.radius * blend, "height": h})


## Ground height at (x, z), pads included.
func height_at(x: float, z: float) -> float:
	var h := _make_natural(x, z)
	for p in pads:
		var c: Vector2 = p.center
		var d := sqrt((x - c.x) * (x - c.x) + (z - c.y) * (z - c.y))
		var outer: float = p.radius + p.skirt
		if d < outer:
			var t := 1.0 if d <= p.radius else 1.0 - smoothstep(0.0, 1.0, (d - p.radius) / p.skirt)
			h = lerpf(h, p.height, t)
	return h


## Height before the pads: regions, then the features.
func _make_natural(x: float, z: float) -> float:
	var w := make_weights(x, z)
	var h := 0.0
	for i in regions.size():
		if w[i] > 0.002:
			h += w[i] * _region_height(i, x, z)
	h = _apply_craters(h, x, z)
	h = _apply_tarns(h, x, z)
	h = _apply_rivers(h, x, z)
	return _apply_coast(h, z)


## Blend weight of each region at (x, z) (sum 1).
func make_weights(x: float, z: float) -> PackedFloat32Array:
	var w := PackedFloat32Array()
	w.resize(regions.size())
	var sum := 0.0
	for i in regions.size():
		var c: Array = regions[i].center
		var d := sqrt((x - float(c[0])) * (x - float(c[0])) + (z - float(c[1])) * (z - float(c[1]))) / float(regions[i].scale)
		var v := pow(1.0 / (d + WEIGHT_EPS), WEIGHT_POWER)
		w[i] = v
		sum += v
	for i in w.size():
		w[i] /= sum
	return w


## Index of the region with the largest weight at (x, z).
func find_region(x: float, z: float) -> int:
	var w := make_weights(x, z)
	var best := 0
	for i in w.size():
		if w[i] > w[best]:
			best = i
	return best


func _region_height(i: int, x: float, z: float) -> float:
	var r: Dictionary = regions[i]
	var n := _noises[i].get_noise_2d(x, z)
	var base := float(r.base)
	var amp := float(r.amp)
	match str(r.kind):
		"ridged":
			var ridge := 1.0 - absf(n * 1.6)
			return base + amp * maxf(ridge, 0.0) * maxf(ridge, 0.0) + 22.0 * _detail.get_noise_2d(x, z)
		"terraced":
			var steps := float(r.get("steps", 5))
			var t := (n * 0.5 + 0.5) * steps
			var f := t - floorf(t)
			return base + amp * (floorf(t) + smoothstep(0.6, 1.0, f)) / steps + 6.0 * _detail.get_noise_2d(x, z)
		"steep":
			var ridge := maxf(1.0 - absf(n * 1.5), 0.0)
			return base + amp * ridge * ridge * ridge + 30.0 * _detail.get_noise_2d(x, z) * ridge
	return base + amp * n + 3.0 * _detail.get_noise_2d(x, z)


func _apply_craters(h: float, x: float, z: float) -> float:
	for c in (def.terrain as Dictionary).get("craters", []):
		var d := Vector2(x - float(c.center[0]), z - float(c.center[1])).length() / float(c.radius)
		if d >= 1.35:
			continue
		var bowl := lerpf(float(c.floor), water_level + float(c.rim), smoothstep(0.25, 1.0, minf(d, 1.0)))
		h = lerpf(h, bowl, 1.0 - smoothstep(1.0, 1.35, d))
	return h


func _apply_tarns(h: float, x: float, z: float) -> float:
	for c in (def.terrain as Dictionary).get("tarns", []):
		var d := Vector2(x - float(c.center[0]), z - float(c.center[1])).length()
		var half := float(c.half)
		if d >= half * 3.0:
			continue
		var bowl := float(c.floor) + (float(c.level) + 22.0 - float(c.floor)) * smoothstep(half * 0.45, half * 1.5, d)
		h = lerpf(h, bowl, 1.0 - smoothstep(half * 1.8, half * 3.0, d))
	return h


func _apply_rivers(h: float, x: float, z: float) -> float:
	for r in (def.terrain as Dictionary).get("rivers", []):
		var pts: Array = r.points
		var d := INF
		for k in pts.size() - 1:
			d = minf(d, _distance_to_segment(Vector2(x, z), Vector2(float(pts[k][0]), float(pts[k][1])), Vector2(float(pts[k + 1][0]), float(pts[k + 1][1]))))
		var w := float(r.width)
		if d < w + float(r.bank):
			var bed := water_level - float(r.depth) * (1.0 - clampf(d / w, 0.0, 1.0) * 0.6)
			h = lerpf(bed, h, smoothstep(w, w + float(r.bank), d))
	return h


static func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _apply_coast(h: float, z: float) -> float:
	var c: Dictionary = (def.terrain as Dictionary).get("coast", {})
	if c.is_empty() or z <= float(c.z0):
		return h
	return h - float(c.drop) * smoothstep(float(c.z0), float(c.z1), z)


## The whole grid, row-major (rows = +z, columns = +x), as MapTerrain wants it.
func make_heights() -> PackedFloat32Array:
	if _heights.is_empty():
		_heights.resize(samples * samples)
		for row in samples:
			LoadKeepAlive.pump()
			var z := origin.y + row * square
			for col in samples:
				_heights[row * samples + col] = height_at(origin.x + col * square, z)
	return _heights


## Bilinear height from the grid (what the game's terrain gives).
func grid_height(x: float, z: float) -> float:
	var hs := make_heights()
	var fx := clampf((x - origin.x) / square, 0.0, samples - 1.001)
	var fz := clampf((z - origin.y) / square, 0.0, samples - 1.001)
	var cx := int(fx)
	var cz := int(fz)
	var tx := fx - cx
	var tz := fz - cz
	var i := cz * samples + cx
	return lerpf(lerpf(hs[i], hs[i + 1], tx), lerpf(hs[i + samples], hs[i + samples + 1], tx), tz)


## Slope (rise over run) at (x, z) from the grid.
func grid_slope(x: float, z: float) -> float:
	var e := square
	var dx := grid_height(x + e, z) - grid_height(x - e, z)
	var dz := grid_height(x, z + e) - grid_height(x, z - e)
	return sqrt(dx * dx + dz * dz) / (2.0 * e)


## True when nothing of the ground blocks the line between two eye points above (x0,z0) and (x1,z1).
func is_line_clear(a: Vector2, b: Vector2, eye := 1.7) -> bool:
	var h0 := grid_height(a.x, a.y) + eye
	var h1 := grid_height(b.x, b.y) + eye
	var steps := maxi(int(a.distance_to(b) / square), 2)
	for i in range(1, steps):
		var t := float(i) / steps
		var p := a.lerp(b, t)
		if grid_height(p.x, p.y) > lerpf(h0, h1, t):
			return false
	return true
