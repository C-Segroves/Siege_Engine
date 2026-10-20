class_name HitHistory
extends RefCounted
## About one second of per-tick hit capsules of every unit, copied from the EntityTable once per server tick
## (docs/DEDICATED_SERVER_SCALING.md section 2.3). Lag compensation asks where a ray would have hit the units as
## they stood `rewind_ms` ago: an analytic ray against the capsules of the two ticks around that moment,
## interpolated. No physics state is touched, so it is cheap and deterministic.
## A capsule stands on its unit's position (feet) and is `height` tall with rounded ends of `radius`.

const HISTORY_SECONDS := 1.0
const STRIDE := 6   # x, y, z, yaw, radius, height
const MILLISECONDS := 1000.0

var tick_hz: int
var capacity: int
var _frames: Array[Dictionary] = []   # {tick, ids: PackedInt32Array, data: PackedFloat32Array}


func _init(p_tick_hz := ServerClock.DEFAULT_HZ) -> void:
	tick_hz = maxi(p_tick_hz, 1)
	capacity = ceili(HISTORY_SECONDS * tick_hz) + 2


func size() -> int:
	return _frames.size()


func newest_tick() -> int:
	return -1 if _frames.is_empty() else int(_frames.back().tick)


## Ticks of history kept (about HISTORY_SECONDS worth).
func oldest_tick() -> int:
	return -1 if _frames.is_empty() else int(_frames.front().tick)


## Copies the living units of `table` as they stand at `tick`.
func record(table: EntityTable, tick: int) -> void:
	var ids := PackedInt32Array()
	var data := PackedFloat32Array()
	for row in table.size():
		if not table.is_flagged(row, EntityTable.FLAG_ALIVE):
			continue
		ids.append(table.ids[row])
		data.append_array(PackedFloat32Array([table.pos_x[row], table.pos_y[row], table.pos_z[row], table.yaw[row],
			table.hit_radius[row], table.hit_height[row]]))
	record_capsules(ids, data, tick)


## Adds a frame of already packed capsules (STRIDE floats per id).
func record_capsules(ids: PackedInt32Array, data: PackedFloat32Array, tick: int) -> void:
	_frames.append({"tick": tick, "ids": ids, "data": data})
	while _frames.size() > capacity:
		_frames.pop_front()


## The tick (fractional) `rewind_ms` before `now_tick`, not older than the history and not newer than `now_tick`.
func make_view_tick(now_tick: int, rewind_ms: float) -> float:
	var t := float(now_tick) - rewind_ms * tick_hz / MILLISECONDS
	if _frames.is_empty():
		return t
	return clampf(t, float(oldest_tick()), float(newest_tick()))


## Where the unit `id` stood at tick `view_tick` (interpolated); the capsule as Vector3 position, plus radius and
## height: {position, radius, height}. Empty when it was not in the history then.
func make_capsule(id: int, view_tick: float) -> Dictionary:
	var pair := _find_pair(view_tick)
	if pair.is_empty():
		return {}
	var a := _read(pair.from, id)
	if a.is_empty():
		return {}
	var b := _read(pair.to, id)
	if b.is_empty():
		return a
	return {"position": (a.position as Vector3).lerp(b.position, pair.weight), "radius": a.radius, "height": a.height}


## The first unit a ray hits as the units stood at `view_tick`: {id, distance, position}, empty when none within
## `reach`. `ignore_id` (the shooter) is skipped; `limit` shortens the reach (a wall in front of the unit).
func find_hit(origin: Vector3, direction: Vector3, reach: float, view_tick: float, ignore_id: int) -> Dictionary:
	var pair := _find_pair(view_tick)
	if pair.is_empty():
		return {}
	var best := {}
	var best_t := reach
	var frame_ids: PackedInt32Array = pair.from.ids
	for i in frame_ids.size():
		if frame_ids[i] == ignore_id:
			continue
		var capsule := make_capsule(frame_ids[i], view_tick)
		if capsule.is_empty():
			continue
		var t := make_ray_distance(origin, direction, capsule)
		if t >= 0.0 and t <= best_t:
			best_t = t
			best = {"id": frame_ids[i], "distance": t, "position": origin + direction * t}
	return best


## Distance along the unit-length `direction` from `origin` to `capsule` ({position, radius, height}); -1 when the
## ray misses it or starts inside it.
static func make_ray_distance(origin: Vector3, direction: Vector3, capsule: Dictionary) -> float:
	var radius: float = capsule.radius
	var base: Vector3 = capsule.position
	var a := base + Vector3.UP * radius
	var b := base + Vector3.UP * maxf(float(capsule.height) - radius, radius)
	var ba := b - a
	var oa := origin - a
	var baba := ba.dot(ba)
	var bard := ba.dot(direction)
	var baoa := ba.dot(oa)
	var rdoa := direction.dot(oa)
	var oaoa := oa.dot(oa)
	var qa := baba - bard * bard
	var qb := baba * rdoa - baoa * bard
	var qc := baba * oaoa - baoa * baoa - radius * radius * baba
	var h := qb * qb - qa * qc
	var best := -1.0
	if h >= 0.0 and absf(qa) > 1e-9:
		var t := (-qb - sqrt(h)) / qa
		var y := baoa + t * bard
		if t >= 0.0 and y > 0.0 and y < baba:
			best = t
	for centre in [a, b]:
		var ts := _ray_sphere(origin, direction, centre, radius)
		if ts >= 0.0 and (best < 0.0 or ts < best):
			best = ts
	return best


static func _ray_sphere(origin: Vector3, direction: Vector3, centre: Vector3, radius: float) -> float:
	var oc := origin - centre
	var b := direction.dot(oc)
	var h := b * b - (oc.dot(oc) - radius * radius)
	if h < 0.0:
		return -1.0
	var t := -b - sqrt(h)
	return t if t >= 0.0 else -1.0


func _find_pair(view_tick: float) -> Dictionary:
	if _frames.is_empty():
		return {}
	var oldest := float(oldest_tick())
	var newest := float(newest_tick())
	if view_tick < oldest or view_tick > newest:
		return {}
	for i in range(_frames.size() - 1, -1, -1):
		var f: Dictionary = _frames[i]
		if float(f.tick) <= view_tick:
			if i == _frames.size() - 1:
				return {"from": f, "to": f, "weight": 0.0}
			var g: Dictionary = _frames[i + 1]
			var span := float(g.tick) - float(f.tick)
			return {"from": f, "to": g, "weight": (view_tick - float(f.tick)) / maxf(span, 1.0)}
	return {}


static func _read(frame: Dictionary, id: int) -> Dictionary:
	var ids: PackedInt32Array = frame.ids
	var at := ids.find(id)
	if at == -1:
		return {}
	var d: PackedFloat32Array = frame.data
	var o := at * STRIDE
	return {"position": Vector3(d[o], d[o + 1], d[o + 2]), "radius": d[o + 4], "height": d[o + 5]}
