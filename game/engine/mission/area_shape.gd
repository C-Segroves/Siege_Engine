class_name AreaShape
extends RefCounted
## A volume the mission asks "is this point in it": a circle (horizontal only, with a minimum radius), a box (with
## height slack), a cylinder (with height slack) or a sphere. Games pass their own numbers (Earthsiege regions: 30 m minimum;
## Starsiege boxes: 20 m slack; Vengeance cylinders: 2.5 m slack).

enum Kind { CIRCLE, BOX, CYLINDER, SPHERE }

var kind := Kind.CIRCLE
var center := Vector3.ZERO
var radius := 0.0
var size := Vector3.ZERO          # box: full extents
var height := 0.0                 # cylinder: full height
var slack := 0.0                  # extra reach above and below a box or cylinder


static func make_circle(p_center: Vector3, p_radius: float, p_min_radius := 0.0) -> AreaShape:
	var s := AreaShape.new()
	s.center = p_center
	s.radius = maxf(p_radius, p_min_radius)
	return s


static func make_box(p_center: Vector3, p_size: Vector3, p_slack := 0.0) -> AreaShape:
	var s := AreaShape.new()
	s.kind = Kind.BOX
	s.center = p_center
	s.size = p_size
	s.slack = p_slack
	return s


static func make_cylinder(p_center: Vector3, p_radius: float, p_height: float, p_slack := 0.0) -> AreaShape:
	var s := AreaShape.new()
	s.kind = Kind.CYLINDER
	s.center = p_center
	s.radius = p_radius
	s.height = p_height
	s.slack = p_slack
	return s


## A ball (Tribes spherical triggers): `radius` in every direction, no slack.
static func make_sphere(p_center: Vector3, p_radius: float) -> AreaShape:
	var s := AreaShape.new()
	s.kind = Kind.SPHERE
	s.center = p_center
	s.radius = p_radius
	return s


func is_inside(point: Vector3) -> bool:
	var d := point - center
	match kind:
		Kind.SPHERE:
			return d.length() <= radius
		Kind.BOX:
			return absf(d.x) <= size.x * 0.5 and absf(d.z) <= size.z * 0.5 and absf(d.y) <= size.y * 0.5 + slack
		Kind.CYLINDER:
			return Vector2(d.x, d.z).length() <= radius and absf(d.y) <= height * 0.5 + slack
	return Vector2(d.x, d.z).length() <= radius
