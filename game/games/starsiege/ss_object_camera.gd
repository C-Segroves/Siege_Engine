class_name SSObjectCamera
extends RefCounted
## The object cameras Starsiege mission scripts switch to (Starsiege.exe console functions, usage
## strings and defaults in the handlers at 0x4a7a1c..0x4a80fc; offsets are metres in the object's frame,
## x right, y forward, z up):
##   setDominantCamera(object0, object1, [x, y, z])   follows object0 at the offset (default 0, -25, 12:
##                                                     behind and above) looking at object1;
##   setFlybyCamera(object, [cx, cy, cz, ox, oy, oz]) a camera left at object + (cx, cy, cz) (default
##                                                     -6, 40, 2: ahead of it) watches the object pass,
##                                                     aimed at object + (ox, oy, oz) (default 0, 0, 5);
##   setTowerCamera(object, x, y, z, [ox, oy, oz])    a camera at the mission position (x, y, z) aimed at
##                                                     object + (ox, oy, oz);
##   setOrbitCamera(object, [distance, azimuth, incidence]) a camera on a sphere around the object
##                                                     (azimuth degrees around it from behind its
##                                                     heading, incidence degrees above the horizon).
## A camera whose object is gone holds its last view.

enum Mode { DOMINANT, FLYBY, TOWER, ORBIT }

## 0x4a7b4c: default dominant offset (x, y, z).
const DOMINANT_OFFSET := Vector3(0.0, -25.0, 12.0)
## 0x4a7ca5: default flyby camera offset; 0x4a7ccf: default object (aim) offset z.
const FLYBY_OFFSET := Vector3(-6.0, 40.0, 2.0)
const OBJECT_OFFSET := Vector3(0.0, 0.0, 5.0)
## setOrbitCamera without arguments keeps the orbit camera's previous settings; these are the start values.
const ORBIT_DISTANCE := 40.0
const ORBIT_AZIMUTH_DEG := 0.0
const ORBIT_INCIDENCE_DEG := 20.0
## The dominant camera aims at the middle of a Herc rather than its feet.
const DOMINANT_AIM_HEIGHT := 4.0

var mode := Mode.DOMINANT
var subject: Node3D
var focus: Node3D
var offset := Vector3.ZERO           # original object frame (x right, y forward, z up)
var aim_offset := OBJECT_OFFSET      # original object frame
var position := Vector3.ZERO         # engine frame (flyby / tower camera position)
var orbit := Vector3(ORBIT_DISTANCE, ORBIT_AZIMUTH_DEG, ORBIT_INCIDENCE_DEG)


static func make_dominant(p_subject: Node3D, p_focus: Node3D, p_offset := DOMINANT_OFFSET) -> SSObjectCamera:
	var c := SSObjectCamera.new()
	c.mode = Mode.DOMINANT
	c.subject = p_subject
	c.focus = p_focus
	c.offset = p_offset
	return c


## The camera stays where it is placed now, ahead of the object.
static func make_flyby(p_subject: Node3D, camera_offset := FLYBY_OFFSET, p_aim := OBJECT_OFFSET) -> SSObjectCamera:
	var c := SSObjectCamera.new()
	c.mode = Mode.FLYBY
	c.subject = p_subject
	c.aim_offset = p_aim
	c.position = make_point(p_subject, camera_offset)
	return c


## `p_position`: engine frame.
static func make_tower(p_subject: Node3D, p_position: Vector3, p_aim := OBJECT_OFFSET) -> SSObjectCamera:
	var c := SSObjectCamera.new()
	c.mode = Mode.TOWER
	c.subject = p_subject
	c.position = p_position
	c.aim_offset = p_aim
	return c


## p_orbit = (distance m, azimuth deg, incidence deg).
static func make_orbit(p_subject: Node3D, p_orbit := Vector3(ORBIT_DISTANCE, ORBIT_AZIMUTH_DEG, ORBIT_INCIDENCE_DEG)) -> SSObjectCamera:
	var c := SSObjectCamera.new()
	c.mode = Mode.ORBIT
	c.subject = p_subject
	c.orbit = p_orbit
	return c


## World point at `local` (original object frame) from `node`.
static func make_point(node: Node3D, local: Vector3) -> Vector3:
	var engine_local := Vector3(local.x, local.z, -local.y)
	return node.global_position + node.global_basis.orthonormalized() * engine_local


## The camera transform now; `previous` when the followed object is gone.
func make_transform(previous: Transform3D) -> Transform3D:
	if not _is_live(subject):
		return previous
	var from := _make_eye()
	var at := _make_target()
	if from.distance_to(at) < 0.01:
		return previous
	var up := Vector3.UP if absf((at - from).normalized().y) < 0.99 else Vector3.FORWARD
	return Transform3D(Basis.looking_at(at - from, up), from)


func _make_eye() -> Vector3:
	match mode:
		Mode.DOMINANT:
			return make_point(subject, offset)
		Mode.ORBIT:
			return subject.global_position + _orbit_direction() * orbit.x
	return position


func _make_target() -> Vector3:
	if mode == Mode.DOMINANT:
		var looked_at := focus if _is_live(focus) else subject
		return looked_at.global_position + Vector3.UP * DOMINANT_AIM_HEIGHT
	return make_point(subject, aim_offset)


## Unit vector from the object to an orbit camera: turned by the azimuth about the vertical from
## straight behind the object's heading, raised by the incidence.
func _orbit_direction() -> Vector3:
	var forward := -subject.global_basis.z
	var heading := atan2(-forward.x, -forward.z)
	var inc := deg_to_rad(orbit.z)
	var behind := Basis(Vector3.UP, heading + deg_to_rad(orbit.y)) * Vector3.BACK
	return behind * cos(inc) + Vector3.UP * sin(inc)


static func _is_live(n: Node3D) -> bool:
	return n != null and is_instance_valid(n) and n.is_inside_tree()
