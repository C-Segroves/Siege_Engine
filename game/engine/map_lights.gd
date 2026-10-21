class_name MapLights
extends Node3D
## The placed point lights of a map ("point_lights" in docs/formats/map_schema.md): each is {pos, color, range, type}. A map
## holds hundreds or thousands of them (Tribes: Vengeance rooms), far more than the renderer lights at once, so a small
## pool of shadowless OmniLight3D follows the lights nearest the current camera, refreshed a few times a second.
## Light types as in Unreal: 1 steady, 2 pulse, 3 blink, 4 flicker, 5 strobe, 7 subtle pulse.

const POOL_SIZE := 40
const REFRESH_SECONDS := 0.3
const ENERGY := 2.5
const TYPE_PULSE := 2
const TYPE_BLINK := 3
const TYPE_FLICKER := 4
const TYPE_STROBE := 5
const TYPE_SUBTLE_PULSE := 7

var _pos := PackedVector3Array()
var _range := PackedFloat32Array()
var _color: Array[Color] = []
var _type := PackedInt32Array()
var _pool: Array[OmniLight3D] = []
var _assigned := PackedInt32Array()
var _since_refresh := REFRESH_SECONDS
var _clock := 0.0


## The node for `lights` (the map's list); null when there is nothing to light or the process draws nothing.
static func make(lights: Array) -> MapLights:
	if lights.is_empty() or ServerProfile.is_collision_only():
		return null
	var node := MapLights.new()
	node.name = "MapLights"
	for l in lights:
		node._add(l)
	node._make_pool()
	return node


func _add(l: Dictionary) -> void:
	var p: Array = l.pos
	var c: Array = l.color
	_pos.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	_range.append(float(l.get("range", 6.0)))
	_color.append(Color(float(c[0]), float(c[1]), float(c[2])))
	_type.append(int(l.get("type", 1)))


func _make_pool() -> void:
	for _i in mini(POOL_SIZE, _pos.size()):
		var o := DynamicLights.make_light({"color": Color.WHITE, "range": 1.0, "energy": 0.0})
		o.visible = false
		add_child(o)
		_pool.append(o)
	_assigned.resize(_pool.size())


func _process(delta: float) -> void:
	_clock += delta
	_since_refresh += delta
	if _since_refresh >= REFRESH_SECONDS:
		_since_refresh = 0.0
		_assign_nearest()
	for i in _pool.size():
		if _pool[i].visible:
			_pool[i].light_energy = ENERGY * energy_scale(_type[_assigned[i]], _clock, _assigned[i])


## Gives the pool the lights that matter most to the camera: the smallest distance relative to the light's reach.
func _assign_nearest() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var at := cam.global_position
	var scored: Array[Vector2] = []
	for i in _pos.size():
		var d := at.distance_to(_pos[i])
		if d < _range[i] + 20.0:
			scored.append(Vector2(d / _range[i], float(i)))
	scored.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	for k in _pool.size():
		var o := _pool[k]
		if k >= scored.size():
			o.visible = false
			continue
		var i := int(scored[k].y)
		_assigned[k] = i
		o.visible = true
		o.position = _pos[i]
		o.omni_range = _range[i]
		o.light_color = _color[i]


## Brightness factor (0..1.x) of a light of `type` at `time` seconds; `seed_value` tells lights of one type apart.
static func energy_scale(type: int, time: float, seed_value: int) -> float:
	var phase := time + float(seed_value) * 0.37
	match type:
		TYPE_PULSE:
			return 0.65 + 0.35 * sin(phase * 3.0)
		TYPE_SUBTLE_PULSE:
			return 0.85 + 0.15 * sin(phase * 2.0)
		TYPE_BLINK:
			return 1.0 if fmod(phase, 1.4) < 0.7 else 0.0
		TYPE_STROBE:
			return 1.0 if fmod(phase, 0.3) < 0.1 else 0.0
		TYPE_FLICKER:
			return 0.6 + 0.4 * absf(sin(phase * 17.0) * sin(phase * 5.3))
	return 1.0
