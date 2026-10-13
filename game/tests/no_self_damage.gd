extends Node
## Headless check that every pilotable armed vehicle's weapon mounts fire clear of the vehicle itself, for
## every weapon each hardpoint can mount (WeaponFit; a fixed-loadout vehicle's own weapons):
##   1. placement: at forward and full torso twist, for aim points 40 / 120 / 300 m down the sight
##      (Weapon.make_aim_point), the straight shot from the muzzle to the aim point must not run into the
##      vehicle's own collision shape (a physics ray, as Projectile casts it) beyond the muzzle exit
##      (Projectile.SHOOTER_CLEARANCE), and the muzzle must sit above the ground the vehicle stands on;
##      a shot through the vehicle's own model (weapon pods excluded) is listed as a NOTE: the model does
##      not collide, but it shows a pod that fires through the hull;
##   2. firing: each weapon fires at a wall 40 m away (forward and at full twist); no shot may end next to
##      the shooter and the shooter's shields and hull never drop.
## Dropped weapons (mines, bombs) and passive pods are skipped: they are not aimed (a fixed loadout's bomb bays
## still release with the rest; where their bombs land is not checked).
## Vehicles are tested side by side on flat platforms high above the map, one round of loadouts at a time.
##   godot --headless --audio-driver Dummy --fixed-fps 60 --path game res://tests/no_self_damage.tscn
##   [-- --pack=es1] [-- --vehicle=es1:RAPTOR] [-- --no-fire]   (filters; geometry only)

const AIM_DISTANCES := [40.0, 120.0, 300.0]
const FIRE_DISTANCE := 40.0
## Hull triangles this close to the muzzle are the barrel's own end (or the pod's root), not the hull in the way.
const MUZZLE_SLACK := 0.3
## A muzzle this far below the platform top is under the ground.
const GROUND_SLACK := 0.05
## A shot that ends closer than this to the shooter's capsule hit it (or the ground at its feet) on the way out.
const NEAR_SHOOTER := 3.0
const FIRE_FRAMES := 30
const SLOT_SPACING := 600.0
const SLOT_ALTITUDE := 3000.0
const PLATFORM_SIZE := Vector3(80.0, 2.0, 80.0)
const WALL_SIZE := Vector3(120.0, 240.0, 2.0)
const SKIPPED_KINDS := ["mine", "bomb", "ecm", "other"]

var _battle: Battle
var _failures := {}       # "vehicle / hardpoint / weapon" -> Array of reasons
var _notes := {}          # same keys: shots through the vehicle's own model
var _exits := 0           # shots that only graze their own collision shape within the muzzle exit
var _combos := 0
var _checks := 0
var _fire := true


func _ready() -> void:
	var packs := []
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			packs.append(a.substr(7))
		elif a.begins_with("--vehicle="):
			only = Assets.qualify(a.substr(10))
		elif a == "--no-fire":
			_fire = false
	_battle = await _start_battle()
	var jobs := _make_jobs(packs, only)
	print("no_self_damage: %d vehicles" % jobs.size())
	var round := 0
	while jobs.any(func(j): return round < j.rounds):
		await _run_round(jobs, round)
		round += 1
	_finish()


func _finish() -> void:
	var keys := _failures.keys()
	keys.sort()
	var noted := _notes.keys()
	noted.sort()
	for k in noted:
		print("  NOTE %s: %s" % [k, _notes[k]])
	for k in keys:
		print("  FAIL %s: %s" % [k, "; ".join(PackedStringArray(_failures[k]))])
	print("no_self_damage: %s (%d combos, %d checks, %d failing combos, %d noted through their own model, %d grazes within the muzzle exit)" % [
		"OK" if keys.is_empty() else "FAILED", _combos, _checks, keys.size(), noted.size(), _exits])
	get_tree().quit(1 if not keys.is_empty() else 0)


# ------------------------------------------------------------------ combos

## One job per vehicle: its hardpoints' candidate weapons; round r mounts candidate r on every hardpoint.
func _make_jobs(packs: Array, only: String) -> Array:
	var out := []
	for v in Packs.pilotable(packs):
		if only != "" and str(v.id) != only:
			continue
		if str(v.get("category", "herc")) == "infantry" or not PackVehicleLoader.is_armed(v):
			continue
		var per_hardpoint := _make_candidates(v)
		var rounds := 0
		for c in per_hardpoint:
			rounds = maxi(rounds, (c as Array).size())
		if rounds > 0:
			out.append({"vehicle": v, "candidates": per_hardpoint, "rounds": rounds, "slot": out.size()})
	return out


## Weapon ids per hardpoint: the fixed loadout as it is, else every aimed weapon that fits there.
func _make_candidates(v: Dictionary) -> Array:
	var out := []
	if PackVehicleLoader.has_fixed_loadout(v):
		for wid in v.get("loadout", []):
			out.append([] if wid == null or str(wid) == "" or _is_skipped(Packs.weapon(str(wid))) else [str(wid)])
		return out
	var rules := {WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS: true}
	var ids := Packs.weapons.keys()
	ids.sort()
	for i in WeaponFit.hardpoint_masks(v).size():
		var fit := []
		for wid in ids:
			var w: Dictionary = Packs.weapons[wid]
			if not _is_skipped(w) and WeaponFit.fits(w, v, i, rules):
				fit.append(str(wid))
		out.append(fit)
	return out


static func _is_skipped(w: Dictionary) -> bool:
	return w.is_empty() or str(w.get("kind", "")) in SKIPPED_KINDS


static func _round_loadout(job: Dictionary, round: int) -> Array:
	var out := []
	for c in job.candidates:
		out.append(c[round] if round < (c as Array).size() else "")
	return out


# ------------------------------------------------------------------ a round

func _run_round(jobs: Array, round: int) -> void:
	var tests := []
	for job in jobs:
		if round < int(job.rounds):
			tests.append(_spawn_test(job, _round_loadout(job, round)))
	await get_tree().physics_frame   # the new bodies reach the physics space
	for twist in [0, -1, 1]:
		for t in tests:
			_apply_twist(t, twist)
			_check_placement(t, twist)
		if _fire:
			await _fire_all(tests, twist)
	for t in tests:
		t.herc.queue_free()
		t.platform.queue_free()
	await get_tree().physics_frame


## The vehicle of `job` with `loadout` on its own platform, frozen (no pilot, no physics: the test poses it).
func _spawn_test(job: Dictionary, loadout: Array) -> Dictionary:
	var slot := int(job.slot)
	var base := Vector3((slot % 12) * SLOT_SPACING, SLOT_ALTITUDE, (slot / 12) * SLOT_SPACING)
	var platform := _make_box(PLATFORM_SIZE, base - Vector3.UP * PLATFORM_SIZE.y * 0.5)
	var spec := {"net_id": _battle.spawner.allocate_id(), "vehicle": str(job.vehicle.id), "team": 0, "owner": 0,
		"xf": Transform3D(Basis.IDENTITY, base), "loadout": loadout, "name": "SelfFire", "ai": {}}
	var h := _battle.spawner.build_vehicle(spec)
	_battle.vehicles.erase(spec.net_id)   # out of the battle's rules (bounds, scores)
	h.set_physics_process(false)
	h.global_transform = Transform3D(Basis.IDENTITY, base)
	h.end_spawn_protection()
	var mounted := {}
	for w in h.weapons:
		mounted[w] = "%s / hp%d / %s" % [job.vehicle.id, w.mount_index, w.weapon_id]
		_combos += 1 if not _failures.has(mounted[w]) else 0
	return {"herc": h, "platform": platform, "ground_y": base.y, "weapons": mounted}


## Twist -1 / 0 / +1: full right, forward, full left (a full-turn turret: a quarter turn each way).
func _apply_twist(t: Dictionary, twist: int) -> void:
	var h: Herc = t.herc
	var limit := minf(h.torso_limit, PI * 0.5)
	h.torso_yaw = limit * twist
	h.torso_target = h.torso_yaw
	h.pitch = 0.0
	h.pitch_target = 0.0
	h.torso.apply(h.torso_yaw, h.pitch, h.animator.animates)


# ------------------------------------------------------------------ 1. placement

func _check_placement(t: Dictionary, twist: int) -> void:
	var h: Herc = t.herc
	var hull := _hull_faces(h)
	var aim := -h.aim_basis().z
	var eye := h.aim_origin()
	for w in t.weapons:
		var muzzle: Vector3 = w.muzzle().global_position
		var local := _fmt(h.global_transform.affine_inverse() * muzzle)
		var label := "twist %+d" % twist
		_checks += 1
		if muzzle.y < float(t.ground_y) - GROUND_SLACK:
			_fail(t.weapons[w], "%s: muzzle %.2f m under the ground" % [label, float(t.ground_y) - muzzle.y])
		for d in AIM_DISTANCES:
			var target: Vector3 = eye + aim * float(d)
			_checks += 1
			var entry := _own_body_entry(t, muzzle, target)
			if entry > Projectile.SHOOTER_CLEARANCE:
				_fail(t.weapons[w], "%s, %d m: shot runs into its own collision shape %.2f m from the muzzle (local %s)" % [
					label, d, entry, local])
			elif entry >= 0.0:
				_exits += 1
			var through := _first_hull_hit(hull, muzzle, target)
			if not through.is_empty() and not _notes.has(t.weapons[w]):
				_notes[t.weapons[w]] = "%s, %d m: through its own model (%s) %.2f m from the muzzle (local %s)" % [
					label, d, through.part, through.distance, local]


## Distance from the muzzle at which the straight shot to `to` enters the shooter's own collision shape (a
## physics ray as Projectile casts it: a shape the ray starts inside does not count); -1 when it never does.
func _own_body_entry(t: Dictionary, from: Vector3, to: Vector3) -> float:
	var h: Herc = t.herc
	var q := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF, [(t.platform as StaticBody3D).get_rid()])
	var hit := h.get_world_3d().direct_space_state.intersect_ray(q)
	return from.distance_to(hit.position) if hit and hit.collider == h else -1.0


## The vehicle's visible hull: {faces: world-space triangles, parts: the shape node of each triangle}, every
## drawn mesh except the weapon pods on the hardpoint frames.
static func _hull_faces(h: Herc) -> Dictionary:
	var faces := PackedVector3Array()
	var parts := PackedStringArray()
	for mi in h.shape.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or not m.is_visible_in_tree() or _is_on_hardpoint(m, h.shape):
			continue
		var xf := m.global_transform
		var part := _part_name(h.shape, m)
		var tri := m.mesh.get_faces()
		for p in tri:
			faces.append(xf * p)
		for i in tri.size() / 3:
			parts.append(part)
	return {"faces": faces, "parts": parts}


## "node<i> <name>" of the shape node a mesh hangs on (its name in the shape data, when it has one).
static func _part_name(s: ShapeInstance, m: MeshInstance3D) -> String:
	var i := s.nodes.find(m.get_parent())
	var list: Array = s.shape.get("nodes", [])
	var named := str((list[i] as Dictionary).get("name", "")) if i >= 0 and i < list.size() else ""
	return ("node%d %s" % [i, named]).strip_edges() if i >= 0 else str(m.get_parent().name)


static func _is_on_hardpoint(n: Node, root: Node) -> bool:
	var p := n.get_parent()
	while p != null and p != root:
		if String(p.name).begins_with("hardpoint"):
			return true
		p = p.get_parent()
	return false


## The first hull triangle on the segment beyond MUZZLE_SLACK: {distance from `from`, part}; empty when clear.
static func _first_hull_hit(hull: Dictionary, from: Vector3, to: Vector3) -> Dictionary:
	var faces: PackedVector3Array = hull.faces
	var start := from + (to - from).normalized() * MUZZLE_SLACK
	var best := {}
	for i in range(0, faces.size() - 2, 3):
		var hit = Geometry3D.segment_intersects_triangle(start, to, faces[i], faces[i + 1], faces[i + 2])
		if hit != null and (best.is_empty() or from.distance_to(hit) < float(best.distance)):
			best = {"distance": from.distance_to(hit), "part": hull.parts[i / 3]}
	return best


## The vehicle's collision capsule as {a, b, r} (axis end points, world; radius), empty when it has none.
static func _capsule_of(h: Herc) -> Dictionary:
	for c in h.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is CapsuleShape3D:
			var cap := (c as CollisionShape3D).shape as CapsuleShape3D
			var xf := (c as CollisionShape3D).global_transform
			var half := maxf(cap.height * 0.5 - cap.radius, 0.0)
			return {"a": xf * Vector3(0, -half, 0), "b": xf * Vector3(0, half, 0), "r": cap.radius}
	push_error("no_self_damage: %s has no collision capsule" % h.vehicle_id)
	return {}


static func _capsule_distance(c: Dictionary, p: Vector3) -> float:
	if c.is_empty():
		return INF
	return Geometry3D.get_closest_point_to_segment(p, c.a, c.b).distance_to(p) - float(c.r)


# ------------------------------------------------------------------ 2. firing

## Every vehicle fires each of its weapons in turn at a wall FIRE_DISTANCE down its sight.
func _fire_all(tests: Array, twist: int) -> void:
	var walls := []
	for t in tests:
		var h: Herc = t.herc
		var aim := -h.aim_basis().z
		var at: Vector3 = h.aim_origin() + aim * FIRE_DISTANCE
		var wall := _make_box(WALL_SIZE, at + aim * WALL_SIZE.z * 0.5)
		wall.look_at(at + aim * 10.0, Vector3.UP)
		walls.append(wall)
	await get_tree().physics_frame
	var shots := []
	for t in tests:
		shots.append(_fire_one(t))
	await _watch(shots, twist)
	for wall in walls:
		wall.queue_free()


## Fires every weapon of a test vehicle at once (a self-hit fails each of them: the loadout is one weapon
## per hardpoint, so the failing pair shows in the before / after lists).
func _fire_one(t: Dictionary) -> Dictionary:
	var h: Herc = t.herc
	h.capacitor = h.capacitor_max * 4.0
	var shot := {"test": t, "health": _health(h), "hits": [], "ends": []}
	var on_hit := func(_v, attacker): shot.hits.append(attacker)
	h.damaged.connect(on_hit)
	shot["on_hit"] = on_hit
	var on_child := func(n: Node):
		if n is Projectile and (n as Projectile).shooter == h and not _is_dropped(n as Projectile):
			var p := n as Projectile
			p.tree_exiting.connect(func(): shot.ends.append(p.global_position))
	_battle.child_entered_tree.connect(on_child)
	shot["on_child"] = on_child
	for w in t.weapons:
		w.reload()
		w.fire()
	return shot


func _watch(shots: Array, twist: int) -> void:
	for f in FIRE_FRAMES:
		await get_tree().physics_frame
	for s in shots:
		_battle.child_entered_tree.disconnect(s.on_child)
	for p in get_tree().get_nodes_in_group("projectiles"):
		p.queue_free()
	await get_tree().physics_frame
	for s in shots:
		var t: Dictionary = s.test
		var h: Herc = t.herc
		for w in t.weapons:
			w.reload()
		h.damaged.disconnect(s.on_hit)
		var label := "fire twist %+d" % twist
		_checks += 1
		var capsule := _capsule_of(h)
		var why := ""
		for e in s.ends:
			if _capsule_distance(capsule, e) < NEAR_SHOOTER:
				why = "%s: a shot ended %.1f m from its own hull" % [label, maxf(_capsule_distance(capsule, e), 0.0)]
		if _health(h) < float(s.health) - 0.01 or not s.hits.is_empty():
			why = "%s: the shooter took %.0f damage (hit by %s)" % [label, float(s.health) - _health(h),
				", ".join(PackedStringArray(s.hits.map(func(a): return str(a.name) if a is Node else "?")))]
		if why != "":
			for w in t.weapons:
				_fail(t.weapons[w], why)
		# heal for the next shot
		h.shield_front = h.shield_max * 0.5
		h.shield_rear = h.shield_max * 0.5
		for c in h.components:
			c.hp = c.max


## Bombs and mines fall where they are released: under a vehicle on the ground, beside its hull.
static func _is_dropped(p: Projectile) -> bool:
	return str(p.weapon_def.get("kind", "")) in Weapon.DROPPED_KINDS


static func _health(h: Herc) -> float:
	var hull := 0.0
	for c in h.components:
		hull += float(c.hp)
	return h.shield_front + h.shield_rear + hull


# ------------------------------------------------------------------ helpers

func _start_battle() -> Battle:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	var config := BattleSetup.make_default_config()
	config.ai = []
	battle.config = config
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	for i in 10:
		await get_tree().physics_frame
	return battle


func _make_box(size: Vector3, at: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	_battle.add_child(body)
	body.global_position = at
	return body


func _fail(combo: String, why: String) -> void:
	if not _failures.has(combo):
		_failures[combo] = []
	if (_failures[combo] as Array).size() < 3:
		_failures[combo].append(why)


static func _fmt(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
