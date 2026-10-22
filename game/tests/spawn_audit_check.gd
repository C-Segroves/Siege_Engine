extends Node
## Spawn audit: on every map of every installed pack, a light soldier and a large Herc (and, on Tribes maps, the pack's
## largest ground vehicle) are set down at every spawn point the game can use - the starts MapBuilder makes (Herc, vehicle
## pad, team, infantry drop points), the Battledrome arenas' pads, and on the maps an extraction raid is played on its
## exfil zones, loot areas, insertion points, Varuna's site spawn areas and the Cybrid siege's gates - and must stand: not
## start inside collision, not fall through the world or hang in the air, rest inside the playable area and walk 2 m
## (SpawnAuditCohort). Rows go to --out=<file> (tab separated) for tools/spawn_audit_report.py (docs/SPAWN_AUDIT.md).
##   godot --headless --audio-driver Dummy --path game res://tests/spawn_audit_check.tscn -- --only=tribes2 [--map=Katabatic]
##       [--skip=N --count=M] [--out=file] [--full]
## --only a pack id ("bd" the Battledrome arenas, "missions" every campaign / training mission, "missions:<pack>" one game's);
## --map one map (mission) of it; --skip / --count a slice of the pack's maps;
## --full builds the drawn world instead of the collision-only one the dedicated server uses.
## Prints "spawn_audit_check: <n> maps, <m> points, OK|FAILED (<k> failures)"; exit code 0 / 1. Exceptions (documented
## in docs/SPAWN_AUDIT.md) are listed in tests/spawn_audit_exceptions.json: {"map|kind|unit": "reason"}.

const Points := preload("res://tests/spawn_audit_points.gd")
const Cohort := preload("res://tests/spawn_audit_cohort.gd")
const Missions := preload("res://tests/spawn_audit_missions.gd")
const EXCEPTIONS_PATH := "res://tests/spawn_audit_exceptions.json"
const PACK_BD := "bd"
## Battledrome arena settings the audit builds (every size, the most obstacles and turrets, every style).
const BD_STYLES := 3
const UNIT_SOLDIER := "soldier"
const UNIT_BOT := "bot soldier"
const UNIT_HERC := "large Herc"
const UNIT_VEHICLE := "large vehicle"
const NOT_FOR_HERC := "not_for_herc"
## Points a Herc is only tried at to see: soldiers' drop points and the pads of the vehicle stations.
const VEHICLE_KINDS := ["infantry", "pad"]

## Read by Infantry._apply_fell_through (a parent with bounds is not asked for the terrain below).
class World extends Node3D:
	var bounds: MapBounds

var _failures := 0
var _maps := 0
var _points := 0
var _rows: Array[String] = []
var _out_path := ""
var _exceptions := {}
var _probe_points: Array = []   # --probe=x,y,z: audit these places only (a debugging aid)
var _herc_id := ""
var _vehicle_ids := {}   # pack -> largest ground vehicle id


func _ready() -> void:
	var only := ""
	var one_map := ""
	var skip := 0
	var count := 1000000
	var full := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			only = a.substr(7)
		elif a.begins_with("--map="):
			one_map = a.substr(6)
		elif a.begins_with("--skip="):
			skip = int(a.substr(7))
		elif a.begins_with("--count="):
			count = int(a.substr(8))
		elif a.begins_with("--out="):
			_out_path = a.substr(6)
		elif a == "--full":
			full = true
		elif a.begins_with("--probe="):
			var c := a.substr(8).split(",")
			_probe_points.append({"kind": "probe", "label": "probe #%d" % (_probe_points.size() + 1), "hercs": true, "soldier_on_ground": false,
				"xf": Transform3D(Basis(), Vector3(float(c[0]), float(c[1]), float(c[2])))})
	ServerProfile.set_collision_only(not full)
	await get_tree().process_frame
	_exceptions = _load_exceptions()
	_pick_units()
	var jobs := _make_jobs(only, one_map)
	for i in range(skip, mini(jobs.size(), skip + count)):
		await _audit(jobs[i])
	print("spawn_audit_check: %d maps, %d points, %s (%d failures)" % [_maps, _points, "OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _load_exceptions() -> Dictionary:
	if not FileAccess.file_exists(EXCEPTIONS_PATH):
		return {}
	var j = JSON.parse_string(FileAccess.get_file_as_string(EXCEPTIONS_PATH))
	return j if j is Dictionary else {}


## The audited maps: {pack, id, name, arena: settings (Battledrome only)}, in the pack's order.
func _make_jobs(only: String, one_map: String) -> Array:
	var jobs := []
	if only.begins_with("missions"):
		return Missions.make_jobs(only.get_slice(":", 1) if only.contains(":") else "").filter(func(j: Dictionary) -> bool:
			return one_map == "" or str(j.id).ends_with(one_map))
	for e in MapBuilder.list_maps():
		var id := str(e.id)
		if (only == "" or str(e.pack) == only) and (one_map == "" or id == one_map or id.ends_with(":" + one_map)):
			jobs.append({"pack": str(e.pack), "id": id, "name": str(e.get("name", id)),
				"extraction": GameModes.make_remake_ids(e).has(ExtractionRules.MODE)})
	if (only == "" or only == PACK_BD) and Assets.has_pack(PACK_BD):
		for size in range(1, ArenaBuilder.ARENA_SIZES + 1):
			for style in BD_STYLES:
				var id := "bd:arena%d/style%d" % [size, style]
				if one_map == "" or id == one_map or id.ends_with(":" + one_map):
					jobs.append({"pack": PACK_BD, "id": id, "name": id, "extraction": false, "arena": {"size": size,
						"obstacles": "MANY", "turrets": "MANY", "lighting": "BRIGHT", "style": style}})
	return jobs


# ------------------------------------------------------------------ units

## The large Herc (the biggest capsule among the pilotable Hercs installed) and each Tribes pack's largest ground vehicle.
func _pick_units() -> void:
	var best_herc := _Candidate.new()
	var best_vehicle := {}
	for v in Packs.pilotable():
		if bool(v.get("flyer", false)):
			continue
		var size := _measure(str(v.id))
		if str(v.get("category", "herc")) == "herc" and str(v.get("side", "herc")) == "herc":
			if size.is_bigger_than(best_herc):
				best_herc = size
		var pack := str(v.pack)
		if str(v.get("category", "herc")) == "vehicle" and (not best_vehicle.has(pack) or size.is_bigger_than(best_vehicle[pack])):
			best_vehicle[pack] = size
	_herc_id = best_herc.id
	for pack in best_vehicle:
		_vehicle_ids[pack] = best_vehicle[pack].id
	print("spawn_audit_check: large Herc %s (capsule radius %.1f, height %.1f); vehicles %s" % [_herc_id, best_herc.radius, best_herc.height, _vehicle_ids.values()])


class _Candidate extends RefCounted:
	var id := ""
	var radius := 0.0
	var height := 0.0

	func is_bigger_than(other: _Candidate) -> bool:
		return radius > other.radius + 0.001 or (absf(radius - other.radius) <= 0.001 and height > other.height)


func _measure(vehicle_id: String) -> _Candidate:
	var h := Herc.new()
	h.vehicle_id = vehicle_id
	add_child(h)
	var c := _Candidate.new()
	c.id = vehicle_id
	for n in h.get_children():
		if n is CollisionShape3D and n.shape is CapsuleShape3D:
			c.radius = n.shape.radius
			c.height = n.shape.height
	h.queue_free()
	return c


func _make_soldier(armor_id: String, yaw: float) -> Callable:
	return func() -> Herc:
		var s := Infantry.new()
		s.armor_id = armor_id
		s.torso_target = yaw
		return s


func _make_vehicle(vehicle_id: String, palette: String) -> Callable:
	return func() -> Herc:
		var h := Herc.new()
		h.vehicle_id = vehicle_id
		h.palette_id = palette
		return h


# ------------------------------------------------------------------ one map

func _audit(job: Dictionary) -> void:
	if job.has("make_config"):
		await _audit_mission(job)
		return
	var started := Time.get_ticks_msec()
	var world := World.new()
	add_child(world)
	var built: Dictionary
	var points: Array
	if job.has("arena"):
		built = ArenaBuilder.build(world, job.arena)
		points = Points.collect_arena(built.get("spawns", []))
	else:
		built = MapBuilder.build(world, str(job.id))
	await get_tree().physics_frame
	await get_tree().physics_frame
	if built.is_empty():
		_row(job, {"label": "map", "xf": Transform3D()}, "-", "fail", "the map did not build")
		_failures += 1
		world.queue_free()
		return
	_maps += 1
	var bounds := MapBounds.make_for(world, built)
	world.bounds = bounds
	if not job.has("arena"):
		points = Points.collect(world, built)
		if job.extraction:
			points.append_array(Points.collect_extraction(world, built, bounds))
	if not _probe_points.is_empty():
		points = _probe_points
	await _run_cohort(job, world, bounds, built, points, started)
	world.queue_free()
	await get_tree().process_frame


## The probes of `points` in `world`, run and written down.
func _run_cohort(job: Dictionary, world: Node3D, bounds: MapBounds, built: Dictionary, points: Array, started: int) -> void:
	_points += points.size()
	var probes := _make_probes(job, world, built, points)
	var cohort := Cohort.new(get_tree(), world, bounds)
	await cohort.run(probes)
	var bad := 0
	for p in probes:
		var result := _judge(job, p)
		bad += 1 if result.begins_with("fail") else 0
		_row(job, p.point, p.unit, result, str(p.reason))
	_failures += bad
	_flush_rows()
	print("  %s %-34s %3d points %3d probes %2d failures  %.1fs" % ["FAIL" if bad > 0 else "ok  ", job.id, points.size(), probes.size(), bad, (Time.get_ticks_msec() - started) / 1000.0])


## A mission: started in a Battle, its units' start transforms taken, the battle frozen and emptied of units, and the
## audit's probes set down at those places in the battle's own world.
func _audit_mission(job: Dictionary) -> void:
	var started := Time.get_ticks_msec()
	var config: Dictionary = job.make_config.call()
	if config.is_empty():
		_row(job, {"label": "mission", "xf": Transform3D()}, "-", "fail:build", "the mission did not compile")
		_failures += 1
		return
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	for i in Missions.SETTLE_FRAMES:
		await get_tree().physics_frame
	_maps += 1
	var points := Missions.collect(battle)
	if battle.bounds == null or points.is_empty():
		var empty := battle.bounds == null
		_row(job, {"label": "mission", "xf": Transform3D()}, "-", "fail:build" if empty else "n/a",
			"no battle bounds" if empty else "no ground units placed at the start (flyers, later waves)")
		_failures += 1 if empty else 0
		battle.queue_free()
		await get_tree().process_frame
		return
	_freeze(battle)
	for id in battle.vehicles.keys():
		battle.remove_vehicle(int(id))
	await get_tree().process_frame
	var built := {"palette": battle.palette_id}
	await _run_cohort(job, battle, battle.bounds.bounds, built, points, started)
	battle.queue_free()
	for i in 3:
		await get_tree().process_frame


## One probe per unit per point: a soldier everywhere, the large Herc where the game uses Hercs (and, as a "not for Hercs"
## probe, on the infantry drop points), the pack's vehicle likewise.
func _make_probes(job: Dictionary, world: Node3D, built: Dictionary, points: Array) -> Array:
	var probes := []
	var pack: String = BattleInfantry.make_infantry_pack({"map": job.id}) if not job.has("arena") else BattleInfantry.make_infantry_pack({})
	var armor := InfantryCatalog.light_armor_id(pack) if pack != "" else ""
	var palette := str(built.get("palette", "es1:WORLD0"))
	var vehicle := str(_vehicle_ids.get(str(job.pack), ""))
	for pt in points:
		var xf: Transform3D = pt.xf
		var yaw := xf.basis.get_euler().y
		if armor != "":
			var on_ground := Transform3D(Basis(Vector3.UP, yaw), BattleInfantry.make_ground_point(world, xf.origin))
			var soldier_xf: Transform3D = on_ground if pt.soldier_on_ground else Transform3D(Basis(Vector3.UP, yaw), xf.origin)
			probes.append(_make_probe(pt, UNIT_SOLDIER, soldier_xf, _make_soldier(armor, yaw)))
			if not pt.soldier_on_ground and not on_ground.origin.is_equal_approx(xf.origin):
				probes.append(_make_probe(pt, UNIT_BOT, on_ground, _make_soldier(armor, yaw)))
		if not (pt.hercs or pt.kind in VEHICLE_KINDS):
			continue   # (a place only soldiers are set down at)
		var herc_xf := Transform3D(Basis(Vector3.UP, yaw), xf.origin)
		probes.append(_make_probe(pt, UNIT_HERC, herc_xf, _make_vehicle(_herc_id, palette)))
		if vehicle != "" and vehicle != _herc_id and (pt.hercs or pt.kind == "pad"):
			probes.append(_make_probe(pt, UNIT_VEHICLE, herc_xf, _make_vehicle(vehicle, palette)))
	return probes


func _make_probe(pt: Dictionary, unit: String, xf: Transform3D, make: Callable) -> Dictionary:
	return {"point": pt, "unit": unit, "xf": xf, "make": make, "yaw": xf.basis.get_euler().y}


## "ok", "fail:<result>", "exception:<result>" (a documented exception) or "not_for_herc" for a Herc failing on a soldiers-only point.
func _judge(job: Dictionary, p: Dictionary) -> String:
	if p.result == Cohort.OK:
		return "ok"
	var key := "%s|%s|%s" % [job.id, p.point.label, p.unit]
	if _exceptions.has(key):
		p["reason"] = "%s [exception: %s]" % [p.reason, _exceptions[key]]
		return "exception:" + str(p.result)
	if p.unit == UNIT_HERC and not p.point.hercs and p.point.kind in VEHICLE_KINDS:
		return NOT_FOR_HERC + ":" + str(p.result)
	return "fail:" + str(p.result)


## Stops the mission's logic (every node's own processing but the collision objects': a disabled node loses its collision).
func _freeze(node: Node) -> void:
	for c in node.get_children():
		_freeze(c)
	if not (node is CollisionObject3D):
		node.set_process(false)
		node.set_physics_process(false)


# ------------------------------------------------------------------ rows

func _row(job: Dictionary, pt: Dictionary, unit: String, result: String, reason: String) -> void:
	var o: Vector3 = (pt.xf as Transform3D).origin
	_rows.append("\t".join([str(job.pack), str(job.id), str(pt.get("label", "")), "%.1f %.1f %.1f" % [o.x, o.y, o.z], unit, result, reason.replace("\t", " ")]))


## Appends the rows of the map just audited to --out (a run that is cut short keeps what it did).
func _flush_rows() -> void:
	if _out_path != "" and not _rows.is_empty():
		var f := FileAccess.open(_out_path, FileAccess.READ_WRITE if FileAccess.file_exists(_out_path) else FileAccess.WRITE)
		if f == null:
			push_error("cannot write %s" % _out_path)
			return
		f.seek_end()
		f.store_string("\n".join(_rows) + "\n")
	_rows.clear()
