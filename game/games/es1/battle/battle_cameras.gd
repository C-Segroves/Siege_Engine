class_name BattleCameras
extends RefCounted
## The battle's two cameras: the chase camera behind the player's Herc and the cockpit camera
## inside it (original view geometry), and which one is live.

const CHASE_FOV := 65.0
const FAR_CLIP := 8000.0
const CHASE_START := Vector3(0, 40, 80)
const CHASE_HEIGHT := 14.0          # metres above the Herc
const CHASE_DISTANCE := 32.0        # metres behind the torso
const CHASE_LOOK_HEIGHT := 8.0
const CHASE_LOOK_AHEAD := 20.0
const CHASE_FOLLOW_RATE := 5.0      # 1/s smoothing
## A soldier's chase camera in multiples of the soldier's height (the Herc constants above would put it
## 32 m behind a 2 m body): just above and behind the head, looking a little ahead of him.
const SOLDIER_CHASE_HEIGHT := 1.1
const SOLDIER_CHASE_DISTANCE := 2.0
const SOLDIER_CHASE_LOOK_HEIGHT := 0.8
const SOLDIER_CHASE_LOOK_AHEAD := 3.0
const SOLDIER_FALLBACK_HEIGHT := 2.2
## Free space kept around the chase camera (keeps the near plane out of walls), metres.
const CHASE_CLEARANCE := 0.6
const COCKPIT_NEAR := 0.3
## A soldier's first-person near plane: the view model's grip sits 0.55 m ahead of the eye and long weapons (the
## Tribes 2 Spinfusor, 0.6 m) reach back past 0.3 m, which cut them in half (PLAYTEST_2026-10-11b W1).
const SOLDIER_NEAR := 0.05
## Original view: 320x151 window, projection centre at row 72 of 200 (VUE data), 62 degree FOV.
const COCKPIT_FOV_DEG := 62.0
## Darkstar games (Starsiege, Tribes, Tribes 2) look 90 degrees across their 4:3 screen (Tribes clientDefaults.cs
## $pref::PlayerFov = 90; Starsiege's "fov" console command 0x4a6590 and the "Field of View (degrees)" option set the
## same camera field, default assumed the engine's 90, M): the vertical angle of that view, kept on any screen.
const DARKSTAR_PACKS := ["starsiege", "tribes", "tribes2"]
const DARKSTAR_FOV_ACROSS_DEG := 90.0
const DARKSTAR_SCREEN_ASPECT := 4.0 / 3.0
const COCKPIT_CENTRE_ROW := 72.0
const VIEW_HALF_ROWS := 100.0
const OWN_VEHICLE_LAYER := 2        # render layer bit of the player's own Herc (hidden from inside)
const ALL_LAYERS := 0xFFFFF
const DEFAULT_LAYER := 1
const COCKPIT_FALLBACK_POS := Vector3(0, 1, -1)

var chase_cam: Camera3D
var cockpit_cam: Camera3D


## Adds the chase camera (live until a player Herc exists) to `parent`.
func build_chase_camera(parent: Node) -> void:
	chase_cam = Camera3D.new()
	chase_cam.fov = CHASE_FOV
	chase_cam.far = FAR_CLIP
	chase_cam.cull_mask = ALL_LAYERS & ~InfantryHeldWeapon.VIEW_MODEL_LAYER
	parent.add_child(chase_cam)
	chase_cam.position = CHASE_START
	chase_cam.current = true


## Mounts the cockpit camera at the Herc's eye (its game's eye point, CockpitEye, else its cockpit node) and hides
## the Herc's own meshes from it, except a cockpit interior the original showed from inside.
func build_cockpit_camera(h: Herc) -> void:
	cockpit_cam = Camera3D.new()
	cockpit_cam.near = SOLDIER_NEAR if h is Infantry else COCKPIT_NEAR
	cockpit_cam.far = FAR_CLIP
	for mi in h.shape.find_children("*", "MeshInstance3D", true, false):
		mi.layers = OWN_VEHICLE_LAYER
	cockpit_cam.cull_mask = ALL_LAYERS & ~OWN_VEHICLE_LAYER
	cockpit_cam.projection = Camera3D.PROJECTION_FRUSTUM
	cockpit_cam.size = 2.0 * cockpit_cam.near * tan(deg_to_rad(make_cockpit_fov_deg(h)) * 0.5)
	apply_centre_row(cockpit_cam, COCKPIT_CENTRE_ROW, VIEW_HALF_ROWS * 2.0)
	var eye := h.eye_mount()
	(eye.node as Node3D).add_child(cockpit_cam)
	cockpit_cam.position = Vector3.ZERO if h is Infantry else eye.position
	apply_sight(h)
	for mi in CockpitEye.make_interior_meshes(h):
		mi.layers = DEFAULT_LAYER
	if h is Infantry:
		(h as Infantry).held.apply_view_shown(true)


## Turns the cockpit camera to `h`'s sight (Herc.sight_basis): the crosshair is the view's projection centre, so
## the view must look exactly where the weapons aim (playtest A1). The camera keeps riding its eye node.
func apply_sight(h: Herc) -> void:
	if is_instance_valid(cockpit_cam) and is_instance_valid(h) and not h is Infantry:
		cockpit_cam.global_basis = h.sight_basis()


## Narrows the soldier's first-person view to his Laser Rifle scope (RifleScope) while it is zoomed and widens it back
## after; the projection centre keeps its place in the view. The weapon's view model is hidden while zoomed.
func apply_scope(h: Herc) -> void:
	var s := h as Infantry
	if s == null or not is_instance_valid(cockpit_cam):
		return
	var zoomed := s.scope.zoomed and s.alive and RifleScope.is_scope_weapon(s.current_weapon())
	var fov := s.scope.make_vertical_fov_deg() if zoomed else make_cockpit_fov_deg(h)
	var size := 2.0 * cockpit_cam.near * tan(deg_to_rad(fov) * 0.5)
	if not is_equal_approx(size, cockpit_cam.size):
		cockpit_cam.frustum_offset *= size / cockpit_cam.size
		cockpit_cam.size = size
	s.held.apply_view_shown(not zoomed)


## Vertical field of view (degrees) of `h`'s cockpit camera: its game's (Earthsiege: the VUE view, 62).
static func make_cockpit_fov_deg(h: Herc) -> float:
	if str(h.def.get("pack", "")) in DARKSTAR_PACKS:
		var half_across := deg_to_rad(DARKSTAR_FOV_ACROSS_DEG) * 0.5
		return rad_to_deg(2.0 * atan(tan(half_across) / DARKSTAR_SCREEN_ASPECT))
	return COCKPIT_FOV_DEG


## Puts frustum camera `cam`'s projection centre on row `row` of a view `rows` high (the cockpit's HUD
## centre: Earthsiege 1 row 72 of 200, Earthsiege 2 per Herc of 240; CockpitDisplay.set_camera).
static func apply_centre_row(cam: Camera3D, row: float, rows: float) -> void:
	var half := rows * 0.5
	cam.frustum_offset = Vector2(0, -cam.size * 0.5 * (half - row) / half)


## Takes the cockpit camera out of `h` (the player left it) and shows its meshes to the next camera again.
func release_cockpit_camera(h: Herc) -> void:
	if is_instance_valid(cockpit_cam):
		cockpit_cam.queue_free()
	cockpit_cam = null
	if h is Infantry:
		(h as Infantry).held.apply_view_shown(false)
	if is_instance_valid(h.shape):
		for mi in h.shape.find_children("*", "MeshInstance3D", true, false):
			mi.layers = DEFAULT_LAYER


## Eye point: a quarter above the cockpit meshes' centre, just in front of them (no meshes: the
## fallback offset in metres, whatever the node's shape scale).
static func make_eye_position(cockpit_node: Node3D) -> Vector3:
	var aabb := AABB()
	var first := true
	for mi in cockpit_node.get_children():
		if mi is MeshInstance3D:
			var bb: AABB = mi.transform * mi.mesh.get_aabb()
			aabb = bb if first else aabb.merge(bb)
			first = false
	if first:
		return COCKPIT_FALLBACK_POS / maxf(cockpit_node.global_basis.get_scale().x, 0.000001)
	return Vector3(0, aabb.get_center().y + aabb.size.y * 0.25, aabb.position.z - 0.2)


## Makes the chase or the cockpit camera current; returns the live camera.
func apply_view(chase: bool) -> Camera3D:
	var use_chase := chase or cockpit_cam == null
	chase_cam.current = use_chase
	if cockpit_cam:
		cockpit_cam.current = not use_chase
	return chase_cam if use_chase else cockpit_cam


func is_chasing() -> bool:
	return chase_cam.current


## Moves the chase camera smoothly behind the Herc's torso. Like a spring arm, it is pulled in at
## once in front of anything between the Herc and the camera (buildings, terrain), then eases back out.
func apply_follow(player: Herc, delta: float) -> void:
	var aim := player.aim_basis()
	var h := make_follow_body(player)
	var rig := make_chase_rig(h)
	var want := h.global_position + Vector3.UP * float(rig.height) + aim.z * float(rig.distance)
	var eased := chase_cam.global_position.lerp(want, clampf(delta * CHASE_FOLLOW_RATE, 0, 1))
	chase_cam.global_position = make_unobstructed_position(h, eased)
	chase_cam.look_at(h.global_position + Vector3.UP * float(rig.look_height) - aim.z * float(rig.look_ahead))


## The body the chase camera follows: the vehicle a soldier rides in (a soldier-sized rig inside a moving
## transport's hull was swept into the hull every frame and shook: extraction playtest X6), else `player` itself.
## The rider still turns the view with his own look.
static func make_follow_body(player: Herc) -> Herc:
	var s := player as Infantry
	if s != null and s.stowed and s.seat != null and is_instance_valid(s.seat.vehicle):
		return s.seat.vehicle
	return player


## Chase camera geometry for `h` in metres: height above it, distance behind it, look-at height and how far
## ahead it looks. Vehicles use the Herc constants; a soldier's scale with his armour's height.
static func make_chase_rig(h: Herc) -> Dictionary:
	if not (h is Infantry):
		return {"height": CHASE_HEIGHT, "distance": CHASE_DISTANCE, "look_height": CHASE_LOOK_HEIGHT,
			"look_ahead": CHASE_LOOK_AHEAD}
	var body := float((h as Infantry).armor.get("height_m", SOLDIER_FALLBACK_HEIGHT))
	return {"height": body * SOLDIER_CHASE_HEIGHT, "distance": body * SOLDIER_CHASE_DISTANCE,
		"look_height": body * SOLDIER_CHASE_LOOK_HEIGHT, "look_ahead": body * SOLDIER_CHASE_LOOK_AHEAD}


## `to`, or the last point clear of geometry on the way out to it from the Herc's chase pivot (a
## sphere of the camera's clearance radius swept from the pivot; the Herc itself is ignored).
static func make_unobstructed_position(h: Herc, to: Vector3) -> Vector3:
	var pivot := h.global_position + Vector3.UP * float(make_chase_rig(h).look_height)
	var sphere := SphereShape3D.new()
	sphere.radius = CHASE_CLEARANCE
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis(), pivot)
	q.motion = to - pivot
	q.exclude = [h.get_rid()]
	var fractions := h.get_world_3d().direct_space_state.cast_motion(q)
	var safe: float = fractions[0] if fractions.size() == 2 else 1.0
	return pivot + (to - pivot) * safe
