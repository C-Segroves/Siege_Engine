class_name BoundsWall
extends Node3D
## The area edge as a red energy wall: only the stretch of the boundary near the local player is built (a strip of quads on the
## terrain, as tall as height_m), and it shows within show_range_*_m of him (on foot / in a vehicle), strongest nearest him and
## fading along the wall (the shader). The ring is the area's outline; a polygon or circle area only needs its own ring.

const SHADER := preload("res://engine/shaders/bounds_wall.gdshader")

var battle: Battle
var ring := PackedVector2Array()      # the closed outline (x, z)
var mesh_instance: MeshInstance3D
## 0..1 how strongly the wall shows this frame (tests read it).
var strength := 0.0
var _material := ShaderMaterial.new()
var _built_at := Vector3(INF, INF, INF)


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "BoundsWall"
	ServerProfile.apply_client_only(self)


func _ready() -> void:
	var map_bounds := battle.bounds.bounds
	ring = make_ring_of(map_bounds.area) if map_bounds.has_area else PackedVector2Array()
	_material.shader = SHADER
	_material.render_priority = 100   # over the map sky and water
	mesh_instance = MeshInstance3D.new()
	mesh_instance.material_override = _material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh_instance.extra_cull_margin = 4096.0
	mesh_instance.visible = false
	add_child(mesh_instance)


static func make_ring_of(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])


## The distance (metres) from `p` (x, z) to the nearest point of `outline`'s edge.
static func make_edge_distance(outline: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	for i in outline.size():
		var a := outline[i]
		var b := outline[(i + 1) % outline.size()]
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


func _process(_delta: float) -> void:
	var body := battle.player
	if body == null or not is_instance_valid(body) or ring.is_empty():
		mesh_instance.visible = false
		strength = 0.0
		return
	var p2 := Vector2(body.global_position.x, body.global_position.z)
	var on_foot := body is Infantry and not (body as Infantry).stowed
	var reach := BoundsVisual.value("show_range_foot_m" if on_foot else "show_range_vehicle_m")
	strength = clampf(1.0 - make_edge_distance(ring, p2) / reach, 0.0, 1.0)
	mesh_instance.visible = strength > 0.0
	if not mesh_instance.visible:
		return
	_material.set_shader_parameter("player_pos", body.global_position)
	_material.set_shader_parameter("strength", strength)
	_material.set_shader_parameter("fade_along", BoundsVisual.value("span_m") * 0.6)
	_material.set_shader_parameter("scroll", 0.0 if BoundsVisual.is_reduced_motion() else 1.0)
	if _built_at.distance_to(body.global_position) >= BoundsVisual.value("rebuild_move_m"):
		_built_at = body.global_position
		mesh_instance.mesh = make_strip(body.global_position)


## The wall quads within span_m of `centre`: UV.x metres along the outline, UV.y metres above the strip's foot.
func make_strip(centre: Vector3) -> ArrayMesh:
	var c2 := Vector2(centre.x, centre.z)
	var span := BoundsVisual.value("span_m")
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var normals := PackedVector3Array()
	var along := 0.0
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var length := a.distance_to(b)
		if length > 0.0 and Geometry2D.get_closest_point_to_segment(c2, a, b).distance_to(c2) <= span:
			_add_segment(verts, uvs, normals, [a, b, along], c2, centre.y)
		along += length
	var mesh := ArrayMesh.new()
	if verts.is_empty():
		return mesh
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## Appends the quads of one outline edge [from, to, metres along the outline at `from`] that lie within span_m of `c2`.
func _add_segment(verts: PackedVector3Array, uvs: PackedVector2Array, normals: PackedVector3Array, edge: Array,
		c2: Vector2, fallback_y: float) -> void:
	var a: Vector2 = edge[0]
	var b: Vector2 = edge[1]
	var along: float = edge[2]
	var span := BoundsVisual.value("span_m")
	var tall := BoundsVisual.value("height_m") + BoundsVisual.value("sink_m")
	var length := a.distance_to(b)
	var dir := (b - a) / length
	var normal := Vector3(dir.y, 0.0, -dir.x)
	var count := maxi(int(ceil(length / BoundsVisual.value("step_m"))), 1)
	for k in count:
		var t0 := float(k) / count
		var t1 := float(k + 1) / count
		var p0 := a.lerp(b, t0)
		var p1 := a.lerp(b, t1)
		if p0.lerp(p1, 0.5).distance_to(c2) > span:
			continue
		var y0 := _ground_at(p0, fallback_y) - BoundsVisual.value("sink_m")
		var y1 := _ground_at(p1, fallback_y) - BoundsVisual.value("sink_m")
		var q := [Vector3(p0.x, y0, p0.y), Vector3(p1.x, y1, p1.y), Vector3(p1.x, y1 + tall, p1.y), Vector3(p0.x, y0 + tall, p0.y)]
		var u0 := along + length * t0
		var u1 := along + length * t1
		var quv := [Vector2(u0, 0.0), Vector2(u1, 0.0), Vector2(u1, tall), Vector2(u0, tall)]
		for idx in [0, 1, 2, 0, 2, 3]:
			verts.append(q[idx])
			uvs.append(quv[idx])
			normals.append(normal)


func _ground_at(p: Vector2, fallback_y: float) -> float:
	var h := MapTerrain.make_surface_height(battle, Vector3(p.x, 0.0, p.y))
	if h == INF:
		h = battle.bounds.bounds.ground_plane_y
	return h if h != INF else fallback_y
