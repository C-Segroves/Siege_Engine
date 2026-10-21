class_name CallinFx
extends Node3D
## What every peer sees of the call-ins (child "CallinFx" of the battle; docs/design/lobby_loadout_economy.md sections 9.5 and 9.6):
## the flare and the ground ring at a landing zone, the pod falling from orbit (animated in game time from the seconds the host said
## it has left, visual only; CallinPodPose holds its attitude), the impact flash and the crater that fades. The host tells the state of each order
## (`apply_view`) and the impacts (`apply_impact`); nothing here changes the game.

const STALE_SECONDS := 2.5
const FLARE_HEIGHT := 40.0
const FLARE_WIDTH := 0.18
const RING_THICKNESS := 0.12
const POD_LENGTH := 4.0
const POD_WIDTH := 1.1
const STREAK_LENGTH := 60.0
const CRATER_RADIUS := 2.6
const CRATER_HEIGHT := 0.06
const FLASH_SECONDS := 0.7
const SIREN_SOUND := "warning"
const IMPACT_SOUND := "big_explosion"
const IMPACT_SIZE := 7.0
const SIREN_UNIT := 40.0

## order id -> {root, kind, full (the caller and his squad see it at any range), seen (game s), shown, pod (Node3D or null),
## pod_body (the turning pod model), nose (its nose axis), fall_left (s), speed (m/s), light, ring, beam}
var markers := {}
var craters: Array = []
## Game seconds: the sum of the frames' delta, so a paused or slowed game holds the markers and the pods too.
var _clock := 0.0
var _pulse := 0.0
var _puff_left := 0.0


func _init() -> void:
	name = "CallinFx"


func _process(delta: float) -> void:
	_clock += delta
	_pulse += delta
	_puff_left -= delta
	var player := get_viewport().get_camera_3d()
	for id in markers.keys():
		var m: Dictionary = markers[id]
		if _clock - float(m.seen) > STALE_SECONDS and not bool(m.full):
			apply_remove(int(id))
			continue
		_animate(m, delta, player)
	if _puff_left <= 0.0:
		_puff_left = 0.6


## Every peer: the host's word on order `view` (CallinOrder.make_view).
func apply_view(view: Dictionary) -> void:
	if ServerProfile.is_collision_only():
		return
	var id := int(view.id)
	var state := int(view.state)
	if state >= CallinOrder.State.DONE:
		apply_remove(id)
		return
	if not markers.has(id):
		markers[id] = _build_marker(view)
	var m: Dictionary = markers[id]
	m.seen = _clock
	m.full = view.has("peer")
	m.root.global_position = view.lz
	if state == CallinOrder.State.INBOUND and m.pod == null and str(view.kind) in CallinRules.POD_KINDS + [CallinRules.KIND_VEHICLE] \
			and float(view.fall_s) > 0.0:
		_start_pod(m, view)
	var in_flight := state <= CallinOrder.State.INBOUND
	m.shown = in_flight or state == CallinOrder.State.DELIVERING
	m.root.visible = m.shown
	(m.ring as Node3D).visible = in_flight and str(view.kind) != CallinRules.KIND_RADAR


func apply_remove(id: int) -> void:
	if markers.has(id):
		(markers[id].root as Node3D).queue_free()
		markers.erase(id)


func _build_marker(view: Dictionary) -> Dictionary:
	var root := Node3D.new()
	root.name = "CallinMarker%d" % int(view.id)
	add_child(root)
	root.global_position = view.lz
	var color := _color("color")
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = FLARE_WIDTH
	cyl.bottom_radius = FLARE_WIDTH
	cyl.height = FLARE_HEIGHT
	cyl.material = _unshaded(Color(color, 0.55))
	beam.mesh = cyl
	beam.position.y = FLARE_HEIGHT * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(beam)
	var light := OmniLight3D.new()
	light.light_color = color
	light.omni_range = 22.0
	light.position.y = 2.0
	root.add_child(light)
	var ring := _make_ring(float(view.radius))
	root.add_child(ring)
	return {"root": root, "kind": str(view.kind), "full": view.has("peer"), "seen": _clock, "pod": null,
		"pod_body": null, "nose": CallinPodPose.FALLBACK_NOSE, "fall_left": 0.0, "speed": 0.0, "shown": true, "light": light, "ring": ring, "beam": beam}


func _make_ring(radius: float) -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.outer_radius = maxf(radius, 1.0)
	torus.inner_radius = maxf(radius, 1.0) - RING_THICKNESS
	torus.material = _unshaded(Color(_color("ring_color"), 0.8))
	ring.mesh = torus
	ring.position.y = 0.15
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return ring


func _color(key: String) -> Color:
	var c: Array = (CallinRules.data().get("marker", {}) as Dictionary).get(key, [1.0, 0.55, 0.1])
	return Color(float(c[0]), float(c[1]), float(c[2]))


static func _unshaded(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat


# ------------------------------------------------------------------ the falling pod

func _start_pod(m: Dictionary, view: Dictionary) -> void:
	var height := float(CallinRules.pod().get("drop_height_m", 400.0))
	m.speed = height / maxf(float(view.fall_s), 0.1)
	m.fall_left = float(view.fall_left)
	m.pod = Node3D.new()
	(m.root as Node3D).add_child(m.pod)
	_build_pod(m)
	Sfx.play_at_range(SIREN_SOUND, view.lz, 0.0, Vector2(SIREN_UNIT, float(CallinRules.pod().get("siren_m", 400.0))))


## Fills the marker's `pod` (already in the tree: a model is measured in the world) with the pod's body, which turns about its
## middle, and its fiery streak, which always trails straight above it.
func _build_pod(m: Dictionary) -> void:
	var pod: Node3D = m.pod
	var body := Node3D.new()
	pod.add_child(body)
	m.pod_body = body
	var shape_id := CallinRules.pick_imported_shape(CallinRules.pod().get("pod_shapes", []))
	if shape_id != "":
		_build_pod_model(body, shape_id)
		m.nose = CallinPodPose.make_nose_axis(shape_id)
	else:
		var capsule := MeshInstance3D.new()
		var mesh := CapsuleMesh.new()
		mesh.radius = POD_WIDTH
		mesh.height = POD_LENGTH
		capsule.mesh = mesh
		body.add_child(capsule)
	var streak := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.05
	cyl.bottom_radius = POD_WIDTH * 0.7
	cyl.height = STREAK_LENGTH
	cyl.material = _unshaded(Color(1.0, 0.7, 0.3, 0.45))
	streak.mesh = cyl
	streak.position.y = STREAK_LENGTH * 0.5 + POD_LENGTH * 0.5
	streak.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pod.add_child(streak)
	_pose_pod(m)


## The pod model scaled to POD_LENGTH along its longest axis, its middle on `body`'s origin so that it turns about it.
func _build_pod_model(body: Node3D, shape_id: String) -> void:
	var model := ShapeInstance.new()
	body.add_child(model)
	model.build(Assets.shape(shape_id), 0, Packs.default_palette(Assets.split_id(shape_id)[0]))
	var extent := LootContainer._make_world_box(model).get_longest_axis_size()
	if extent > 0.0:
		model.scale *= POD_LENGTH / extent
	model.position -= LootContainer._make_world_box(model).get_center() - body.global_position


func _pose_pod(m: Dictionary) -> void:
	var height := maxf(float(m.fall_left), 0.0) * float(m.speed)
	(m.pod as Node3D).position.y = height + POD_LENGTH * 0.5
	(m.pod_body as Node3D).basis = CallinPodPose.make_basis(m.nose, height)


func _animate(m: Dictionary, delta: float, camera: Camera3D) -> void:
	var flicker := 0.75 + 0.25 * sin(_pulse * 9.0)
	(m.light as OmniLight3D).light_energy = 2.0 * flicker
	(m.ring as Node3D).scale = Vector3.ONE * (1.0 + 0.04 * sin(_pulse * 5.0))
	if _puff_left <= 0.0 and (m.root as Node3D).visible:
		Effects.puff(self, (m.root as Node3D).global_position + Vector3.UP * 1.5, "smoke")
	var pod := m.pod as Node3D
	if pod != null:
		m.fall_left = maxf(float(m.fall_left) - delta, 0.0)
		_pose_pod(m)
	if not bool(m.full) and camera != null:
		var visible_m := float(CallinRules.data().get("marker", {}).get("visible_m", 300.0))
		(m.root as Node3D).visible = bool(m.shown) and (pod != null 			or camera.global_position.distance_to((m.root as Node3D).global_position) <= visible_m)


# ------------------------------------------------------------------ the impact

## Every peer: a pod landed at `pos`: the flash, the sound, the crater.
func apply_impact(pos: Vector3, radius: float) -> void:
	if ServerProfile.is_collision_only():
		return
	Sfx.play_at(IMPACT_SOUND, pos, 4.0)
	var flash := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	var mat := _unshaded(Color(1.0, 0.7, 0.25, 0.9))
	sphere.material = mat
	flash.mesh = sphere
	add_child(flash)
	flash.global_position = pos + Vector3.UP * radius * 0.5
	var tw := flash.create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector3.ONE * (IMPACT_SIZE / maxf(radius, 0.5)), FLASH_SECONDS)
	tw.tween_property(mat, "albedo_color:a", 0.0, FLASH_SECONDS)
	tw.chain().tween_callback(flash.queue_free)
	_build_crater(pos)


func _build_crater(pos: Vector3) -> void:
	var crater := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = CRATER_RADIUS
	disc.bottom_radius = CRATER_RADIUS
	disc.height = CRATER_HEIGHT
	var mat := _unshaded(Color(0.08, 0.07, 0.06, 0.85))
	disc.material = mat
	crater.mesh = disc
	crater.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(crater)
	crater.global_position = pos + Vector3.UP * CRATER_HEIGHT
	craters.append(crater)
	var fade := float(CallinRules.pod().get("crater_fade_s", 120.0))
	var tw := crater.create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, fade)
	tw.tween_callback(func() -> void:
		craters.erase(crater)
		crater.queue_free())
