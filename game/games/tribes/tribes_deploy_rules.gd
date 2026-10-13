class_name TribesDeployRules
extends RefCounted
## Where a Tribes deploy pack may place its object (docs/TRIBES_BASE_EQUIPMENT.md, Deployables): the pack's rule set
## from base_equipment.json "deployables" (tools/export_tribes_deployables.py, the games' own scripts), checked in
## the originals' order:
##   team limit   Tribes 1 $TeamItemMax; Tribes 2 $TeamDeployableMax, turrets one per two players of the bigger
##                team clamped to $TeamDeployableMin .. Max (countTurretsAllowed);
##   surface      the aim ray from the eye reaches terrain or a building within `reach` (T1 getLOSInfo, T2
##                $MaxDeployableDistance); Tribes 2 outdoor turrets need terrain, indoor turrets a building;
##   slope        T1 flat items: normal . up > 0.7; T2 maxDepSlope;
##   space        T1 checkDeployArea: nothing in a 1 m box (the deployer: "You're in the way"); T2
##                $MinDeployableDistance: no object and not the deployer that close;
##   turrets      T1 at most $MaxNumTurretsInBox remote turrets in the 50 m box and none in the 10 m box; T2 none of
##                the team's deployed turrets within the space radius, at most MaxPerSphere in the sphere.
## make_placement answers {error: "" | message, xf: Transform3D, place: {deployed, spec, shape}}.

const UP := Vector3.UP
## The soldier's eye above his origin when the soldier has no eye node (metres).
const EYE_HEIGHT := 1.6

var rules: Dictionary = {}


static func make(p_rules: Dictionary) -> TribesDeployRules:
	var r := TribesDeployRules.new()
	r.rules = p_rules
	return r


## Where `soldier` would deploy (see the class comment); `placed` = the battle's deployed objects of this pack's
## family ([TribesBaseObject]), `team_size` = players of the bigger team.
func make_placement(soldier: Infantry, placed: Array, team_size: int) -> Dictionary:
	var item := str(rules.get("item", ""))
	var own := placed.filter(func(o: TribesBaseObject) -> bool:
		return o.team == soldier.team and str(o.get_meta(TribesDeployables.META_FROM, "")) == item)
	if own.size() >= make_team_max(team_size):
		return _fail("Deployable item limit reached for your team")
	var hit := _make_aim_hit(soldier)
	if hit.is_empty():
		return _fail("Deploy position out of range")
	var surface := _surface_of(hit.collider)
	if not (surface in rules.get("surfaces", [])):
		return _fail("Can only deploy on %s" % " or ".join(rules.get("surfaces", [])))
	var angle := rad_to_deg(UP.angle_to(hit.normal))
	if angle > float(rules.get("max_slope_deg", 180.0)) + 0.001:
		return _fail("Can only deploy on flat surfaces (%.0f degrees)" % angle)
	var space := _check_space(soldier, hit.position)
	if space != "":
		return _fail(space)
	var turret := _check_turrets(soldier, hit.position, placed)
	if turret != "":
		return _fail(turret)
	var place := _make_place(angle)
	return {"error": "", "place": place, "xf": _make_transform(soldier, hit.position, hit.normal)}


static func _fail(text: String) -> Dictionary:
	return {"error": text}


## The team's limit: the item's maximum, for Tribes 2 turrets one per `per_players` of the bigger team (clamped).
func make_team_max(team_size: int) -> int:
	var top := int(rules.get("team_max", 0))
	var per := int(rules.get("per_players", 0))
	if per <= 0:
		return top
	return clampi(team_size / per, int(rules.get("team_min", 0)), top)


func _make_aim_hit(soldier: Infantry) -> Dictionary:
	var from := soldier.aim_origin() if soldier.has_method("aim_origin") else soldier.global_position + UP * EYE_HEIGHT
	var to := from - soldier.aim_basis().z * float(rules.get("reach", 3.0))
	var q := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [soldier.get_rid()])
	return soldier.get_world_3d().direct_space_state.intersect_ray(q)


static func _surface_of(collider: Object) -> String:
	if collider is Node and (collider as Node).is_in_group("terrain"):
		return "terrain"
	if collider is Node and (collider as Node).is_in_group(MapBuilder.INTERIOR_GROUP):
		return "interior"
	return ""


## T1 checkDeployArea box / T2 MinDeployableDistance: nothing but ground within it, and not the deployer.
func _check_space(soldier: Infantry, at: Vector3) -> String:
	var size := float(rules.get("clear_box", 0.0))
	var radius := float(rules.get("clear_radius", 0.0))
	if size <= 0.0 and radius <= 0.0:
		return ""
	var shape: Shape3D
	if size > 0.0:
		shape = BoxShape3D.new()
		(shape as BoxShape3D).size = Vector3.ONE * size
	else:
		shape = SphereShape3D.new()
		(shape as SphereShape3D).radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.transform = Transform3D(Basis(), at + UP * (size * 0.5 if size > 0.0 else 0.0))
	for r in soldier.get_world_3d().direct_space_state.intersect_shape(q, 16):
		var c: Object = r.collider
		if c == soldier:
			return "Unable to deploy - You're in the way"
		if _surface_of(c) == "":
			return "Unable to deploy - Item in the way" if not (c is Herc) else "Unable to deploy - Player in the way"
	return ""


func _check_turrets(soldier: Infantry, at: Vector3, placed: Array) -> String:
	var t: Dictionary = rules.get("turret", {})
	if t.is_empty():
		return ""
	var turrets := placed.filter(func(o: TribesBaseObject) -> bool: return o is TribesTurret)
	if t.has("max_box"):
		if _count_in_box(turrets, at, float(t.max_box)) >= int(t.max_in_box):
			return "Interference from other remote turrets in the area"
		if _count_in_box(turrets, at, float(t.min_box)) > 0:
			return "Frequency Overload - Too close to other remote turrets"
		return ""
	var own := turrets.filter(func(o: TribesBaseObject) -> bool: return o.team == soldier.team)
	if own.any(func(o: TribesBaseObject) -> bool: return o.global_position.distance_to(at) < float(t.space)):
		return "Interference from a nearby turret prevents placement here"
	if _make_density(turrets, at, float(t.sphere)) > int(t.max_per_sphere):
		return "There are too many turrets nearby"
	return ""


## Turrets inside the cube of side `size` centred on `at` (containerBoxFillSet).
static func _count_in_box(turrets: Array, at: Vector3, size: float) -> int:
	var half := size * 0.5
	return turrets.filter(func(o: TribesBaseObject) -> bool:
		var d := (o.global_position - at).abs()
		return d.x <= half and d.y <= half and d.z <= half).size()


## testTurretSaturation: the most turrets around `at` or around any turret near it (within `radius`).
static func _make_density(turrets: Array, at: Vector3, radius: float) -> int:
	var near := turrets.filter(func(o: TribesBaseObject) -> bool: return o.global_position.distance_to(at) <= radius)
	var best := near.size()
	for o in near:
		var around := turrets.filter(func(p: TribesBaseObject) -> bool: return p.global_position.distance_to(o.global_position) <= radius)
		best = maxi(best, around.size())
	return best


## The variant for the surface angle (T2 indoor turret: floor, wall, ceiling), else the only one.
func _make_place(angle: float) -> Dictionary:
	for p in rules.get("places", []):
		if angle >= float(p.get("min_angle_deg", 0.0)) and angle <= float(p.get("max_angle_deg", 180.0)):
			return p
	return (rules.get("places", [{}]) as Array)[0]


## Orientation: "player" stands upright facing the deployer's heading (T1 GameBase::setRotation(player
## rotation), T2 the player transform); "surface" stands on the surface normal (T2 setDeployRotation); "stick"
## sticks to the surface, snapped upright / upside down near vertical (T1 motion sensor, camera).
func _make_transform(soldier: Infantry, at: Vector3, normal: Vector3) -> Transform3D:
	var heading := Basis(UP, soldier.global_rotation.y)
	var up := UP
	match str(rules.get("orient", "player")):
		"surface":
			up = normal
		"stick":
			var snap := cos(deg_to_rad(float(rules.get("stick_snap_deg", 0.0))))
			up = UP if normal.dot(UP) > snap else (-UP if normal.dot(-UP) > snap else normal)
	if up.is_equal_approx(UP):
		return Transform3D(heading, at)
	var fwd := (heading * Vector3.FORWARD).slide(up).normalized()
	if fwd.length() < 0.01:
		fwd = up.cross(Vector3.RIGHT).normalized()
	var right := fwd.cross(up).normalized()
	return Transform3D(Basis(right, up, -fwd).orthonormalized(), at)
