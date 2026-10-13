class_name TargetView
extends SubViewport
## The selected target's 3D model with its damage, for any vehicle of any game (docs/formats/cockpit.md
## section 4.2): a live copy of the target's model (TargetModelCopy: animation pose, torso twist,
## cell states, weapon pods) in its own small 3D world, seen from a fixed front three-quarter view by
## an orthographic camera framed to fill the view, each part coloured by its damage level
## (TargetDamageMap, DamageLevels) through a TargetPaint. Renders only while a target is set, at
## REFRESH_HZ. Use get_texture() to draw it.

const REFRESH_HZ := 10.0
## Camera direction from the model: in front of it (the model faces -Z), turned and raised.
const VIEW_YAW := deg_to_rad(-30.0)
const VIEW_ELEVATION := deg_to_rad(15.0)
const FRAME_MARGIN := 1.06
const CAMERA_DISTANCE_FACTOR := 3.0
const MIN_EXTENT := 0.1

## The shown target: a vehicle or soldier (Herc: per-part damage), or any other target with a model (a structure or
## turret: `shape` ShapeInstance, its health from TargetInfo.make_integrity colours the whole model).
var target: Node3D = null
var paint: TargetPaint
var _root: Node3D
var _camera: Camera3D
var _copy: TargetModelCopy
var _mesh_components := {}          # copy MeshInstance3D -> component indices
var _levels := {}                   # copy MeshInstance3D -> level shown
var _refresh_left := 0.0


## A view of `pixel_size` pixels coloured by `p_paint`.
func _init(pixel_size: Vector2i, p_paint: TargetPaint) -> void:
	name = "TargetView"
	size = pixel_size
	paint = p_paint
	own_world_3d = true
	transparent_bg = true
	msaa_3d = Viewport.MSAA_DISABLED
	screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	render_target_update_mode = SubViewport.UPDATE_DISABLED
	_root = Node3D.new()
	add_child(_root)
	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_root.add_child(_camera)
	paint.build_world(_root)


## Shows target `t` (null, or a target without a model: nothing, and no more rendering).
func apply_target(t: Node) -> void:
	var shown: Node3D = t as Node3D if t != null and is_instance_valid(t) and make_model_of(t) != null else null
	if shown == target and (shown == null or (_copy != null and _copy.is_source_valid())):
		return
	_clear_copy()
	target = shown
	if target != null:
		_build_copy()
	_refresh_left = 0.0


## The model of target `t`: its `shape` ShapeInstance, null when it has none.
static func make_model_of(t: Node) -> ShapeInstance:
	var s = t.get("shape")
	return s as ShapeInstance if s is ShapeInstance and is_instance_valid(s) else null


func _clear_copy() -> void:
	if _copy != null:
		_copy.free()
	_copy = null
	_mesh_components.clear()
	_levels.clear()
	render_target_update_mode = SubViewport.UPDATE_DISABLED


func _build_copy() -> void:
	_copy = TargetModelCopy.new()
	_root.add_child(_copy)
	var model := make_model_of(target)
	_copy.build_from(model)
	var by_source := TargetDamageMap.make_mesh_components(target.def, model) if target is Herc else {}
	for mi in _copy.copy_to_source:
		_mesh_components[mi] = by_source.get(_copy.copy_to_source[mi], [0])
	_apply_levels()
	_frame_camera()


## True while a target is shown.
func has_target() -> bool:
	return _copy != null


## Advances the refresh clock; every 1 / REFRESH_HZ s copies the target's pose and damage and renders
## one frame.
func advance(delta: float) -> void:
	if _copy == null:
		return
	if not _copy.is_source_valid():
		apply_target(null)
		return
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = 1.0 / REFRESH_HZ
	refresh()


## Copies the target's current pose and damage now and renders one frame.
func refresh() -> void:
	if _copy == null:
		return
	_copy.apply_source_pose()
	_apply_levels()
	render_target_update_mode = SubViewport.UPDATE_ONCE


func _apply_levels() -> void:
	var comps := _make_components()
	for mi in _mesh_components:
		var level := DamageLevels.level_of(DamageLevels.worst_health(comps, _mesh_components[mi]))
		if _levels.get(mi, -1) != level:
			_levels[mi] = level
			paint.apply_level(mi, level)


## The target's damage components; a target without them is one part with its overall health.
func _make_components() -> Array:
	if target is Herc:
		return (target as Herc).components
	return [{"hp": TargetInfo.make_integrity(target), "max": 1.0}]


## Damage level each copy mesh shows now (MeshInstance3D -> DamageLevels level).
func make_levels() -> Dictionary:
	return _levels.duplicate()


## Places the orthographic camera at the fixed view direction, sized so the model fills the view.
func _frame_camera() -> void:
	var dir := Basis(Vector3.UP, VIEW_YAW) * Vector3(0.0, sin(VIEW_ELEVATION), -cos(VIEW_ELEVATION))
	var box := _make_model_box()
	var centre := box.get_center()
	var reach := maxf(box.size.length(), MIN_EXTENT)
	var eye := centre + dir * reach * CAMERA_DISTANCE_FACTOR
	_camera.transform = Transform3D(Basis.looking_at(centre - eye, Vector3.UP), eye)
	_camera.near = reach * 0.1
	_camera.far = reach * CAMERA_DISTANCE_FACTOR * 2.0
	var view := _make_view_extent(box)
	_camera.h_offset = view.position.x + view.size.x * 0.5
	_camera.v_offset = view.position.y + view.size.y * 0.5
	var aspect := float(size.x) / maxf(float(size.y), 1.0)
	_camera.size = maxf(view.size.y, view.size.x / aspect) * FRAME_MARGIN


## Bounds of the copy's visible meshes in the view root's space.
func _make_model_box() -> AABB:
	var box := AABB()
	var first := true
	for mi in _copy.visible_meshes():
		var b: AABB = _copy.make_transform_of(mi) * (mi as MeshInstance3D).mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## The model box projected on the camera plane (camera x / y, relative to the camera axis).
func _make_view_extent(box: AABB) -> Rect2:
	var inv := _camera.transform.affine_inverse()
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in 8:
		var p := inv * box.get_endpoint(k)
		lo = lo.min(Vector2(p.x, p.y))
		hi = hi.max(Vector2(p.x, p.y))
	return Rect2(lo, hi - lo)
