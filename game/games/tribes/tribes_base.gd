class_name TribesBase
extends Node
## The bases of a Tribes / Tribes 2 map in a battle (child "TribesBase" of the Battle; docs/TRIBES_BASE_EQUIPMENT.md):
## every map station with a base_equipment.json spec (generators, solar panels, sensors, turrets, stations, pads)
## becomes a TribesBaseObject (TribesTurret for armed turrets) in place of the plain shape MapBuilder placed.
##   power     TribesPowerGrid: generators power their group and the groups below; checked on every peer (each
##             sees the same damage states), so stations, turrets and sensors switch on and off everywhere;
##   repair    host: a soldier whose repair pack is on repairs the nearest damaged base object within the repair
##             beam's reach at the game's object repair rate (base_equipment.json "repair"); the repair work of a
##             soldier not allied to the object's team captures it for BaseRepairRules capture.seconds
##             (TribesBaseObject.apply_capture); a faction's guard soldiers repair their own downed objects
##             (find_job_for, InfantryBot Task.REPAIR); every peer draws the repair beams (TribesRepairBeam);
##   sensors   TribesSensorNet: what each team's radar shows (is_on_radar); not in an extraction raid, whose
##             radar is the mode's own;
##   teams     the map's team groups; in a free-for-all (GameModes.is_free_for_all) and in an extraction raid
##             the base is neutral (team -1): turrets fire at everyone, anyone may use a station.
##   fixtures  the force fields (TribesForceField: closed while powered) and the Tribes 1 doors and elevators
##             (TribesMover) of the map, powered by the same groups.
## Game modes count destroyed objectives through object_destroyed (D&D).

signal object_destroyed(obj: TribesBaseObject, killer: Node)
## A power group gained or lost power (after the change is applied to its objects).
signal power_changed
## A deploy pack placed `obj` (stations, game modes and tests may react).
signal deployed(obj: TribesBaseObject)

const NODE_NAME := "TribesBase"
const SPECS_FILE := "gameplay/base_equipment.json"
const NEUTRAL_TEAM := -1
## Seconds between damage-state checks (power follows a disabled or repaired generator within this time).
const STATE_CHECK_SECONDS := 0.25
## Group of objects that sense for their team (radar / turret target gating).
const SENSOR_GROUP := "tribes_sensors"
const MISSION_LIGHT_GROUP := "tribes_mission_lights"
## A bot's claim on an object it repairs lapses after this long without renewal.
const JOB_STALE_SECONDS := 3.0
## Meta of a soldier repairing an object without a pack (a faction's repair crew): the object, for the beam.
const META_REPAIR_JOB := "repair_job"

var battle: Node
var objects: Array[TribesBaseObject] = []
## Force fields and movers (each has team, power_group, apply_power(on)).
var fixtures: Array[Node3D] = []
var grid: TribesPowerGrid
var repair: Dictionary = {}
var sensor_net: TribesSensorNet
var _palette := ""
## The map.json the base was built from (the command map draws it).
var map_data: Dictionary = {}
var _check_t := 0.0
var _job_of := {}                # TribesBaseObject -> bot id repairing it (host)
var _job_ms := {}                # TribesBaseObject -> msec of the claim's last renewal
var _beams := {}                 # Infantry -> TribesRepairBeam (every peer)
static var _specs := {}          # pack -> base_equipment.json
## Packs without base_equipment.json of their own that borrow another pack's blocks (their stations are look-alikes).
const SPEC_PACK_FALLBACK := {"tribes_aa": "tribes2", "tribes_v": "tribes2"}


## Builds the base of `built` (MapBuilder.build result) under `p_battle`; null when the map has none.
static func build_for(p_battle: Node, built: Dictionary) -> TribesBase:
	var stations: Array = built.get("stations", [])
	var m: Dictionary = built.get("map", {})
	var pack := str(m.get("_pack", ""))
	var has_fixtures := not (m.get("force_fields", []) as Array).is_empty() or not (m.get("movers", []) as Array).is_empty()
	if load_specs(pack).is_empty():
		return null
	var base := TribesBase.new()
	base.battle = p_battle
	base.name = NODE_NAME
	base.grid = TribesPowerGrid.make_for(built.get("map", {}))
	base.repair = load_specs(pack).get("repair", {})
	if not ExtractionRules.is_extraction(p_battle.get("config") if p_battle.get("config") is Dictionary else {}):
		base.sensor_net = TribesSensorNet.make(load_specs(pack).get("player_sensor", {}))
	p_battle.add_child(base)
	base._palette = str(built.get("palette", ""))
	base.map_data = m
	base._build_objects(stations, pack, base._palette)
	base._build_fixtures(m, str(built.get("palette", "")))
	base.apply_power()
	if not (load_specs(pack).get("deployables", {}) as Dictionary).is_empty():
		TribesDeployables.build_for(p_battle)
	return base


## The battle's base (null when it has none).
static func of(p_battle: Node) -> TribesBase:
	return p_battle.get_node_or_null(NODE_NAME) as TribesBase if p_battle else null


## base_equipment.json of `pack` ({} when the pack has none).
static func load_specs(pack: String) -> Dictionary:
	if not _specs.has(pack):
		var j = Assets.load_json(SPECS_FILE, SPEC_PACK_FALLBACK.get(pack, pack)) if pack != "" else null
		_specs[pack] = j if j is Dictionary else {}
	return _specs[pack]


## The spec of map station `record` ({} when it is not base equipment).
static func make_spec(pack: String, record: Dictionary) -> Dictionary:
	var key := str(record.get("spec", ""))
	var spec: Dictionary = load_specs(pack).get("blocks", {}).get(key, {}) if key != "" else {}
	if not (record.has("barrel_shape") and spec.get("turret") is Dictionary):
		return spec
	# a pack with its own turret shapes (Aerial Assault): its barrel and mount node replace the borrowed block's
	spec = spec.duplicate(true)
	spec.turret["barrel_shape"] = str(record.barrel_shape)
	spec.turret["barrel_mount"] = str(record.get("barrel_mount", ""))
	return spec


func _build_objects(stations: Array, pack: String, pal: String) -> void:
	var neutral := is_neutral_match()
	for st in stations:
		LoadKeepAlive.pump()
		var record: Dictionary = st.get("record", {})
		var spec := make_spec(pack, record)
		if spec.is_empty() or str(record.get("shape", "")) == "":
			continue
		var placed = st.get("node")
		if is_instance_valid(placed):
			placed.free()
		var obj := TribesBaseObject.make(battle, record, st.xf, spec, pal)
		if neutral:
			obj.team = NEUTRAL_TEAM
		if obj.kind == TribesBaseObject.KIND_SENSOR or obj.spec.get("sensor") is Dictionary:
			obj.add_to_group(SENSOR_GROUP)
		obj.state_changed.connect(func(_o: TribesBaseObject) -> void: apply_power())
		obj.destroyed.connect(func(s: Structure, killer: Node) -> void: object_destroyed.emit(s as TribesBaseObject, killer))
		st["object"] = obj
		objects.append(obj)


func _build_fixtures(m: Dictionary, pal: String) -> void:
	var neutral := is_neutral_match()
	for record in m.get("force_fields", []):
		fixtures.append(TribesForceField.make(battle, record, pal))
	for record in m.get("movers", []):
		if str(record.get("shape", "")) != "":
			var mover := TribesMover.make(battle, record, pal)
			if mover:
				fixtures.append(mover)
	for f in fixtures:
		if neutral:
			f.team = NEUTRAL_TEAM
	for record in m.get("lights", []):
		_build_mission_light(record)


## A Tribes 1 mission SimLight (point light; not a GameBase object, so never powered down).
func _build_mission_light(record: Dictionary) -> void:
	var light := OmniLight3D.new()
	var p: Array = record.pos
	var c: Array = record.get("color", [1, 1, 1])
	light.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
	light.omni_range = float(record.range)
	light.light_color = Color(float(c[0]), float(c[1]), float(c[2]))
	light.add_to_group(MISSION_LIGHT_GROUP)
	battle.add_child(light)


## A deployed object (TribesDeployables): `record` {shape, spec, datablock, team, from, id} placed at `xf`, powering
## itself; every peer builds it the same way.
func add_deployed(record: Dictionary, xf: Transform3D) -> TribesBaseObject:
	var pack := str(record.shape).get_slice(":", 0)
	var spec := make_spec(pack, record)
	if spec.is_empty() or Assets.shape(str(record.shape)).is_empty():
		push_error("TribesBase: cannot deploy %s" % record)
		return null
	var obj := TribesBaseObject.make(battle, {"shape": record.shape, "team": record.team, "datablock": record.datablock,
		"power_group": -1}, xf, spec, _palette)
	obj.self_powered = true
	obj.set_meta(TribesDeployables.META_FROM, str(record.from))
	if obj.kind == TribesBaseObject.KIND_SENSOR or obj.spec.get("sensor") is Dictionary:
		obj.add_to_group(SENSOR_GROUP)
	obj.state_changed.connect(func(_o: TribesBaseObject) -> void: apply_power())
	obj.destroyed.connect(func(s: Structure, killer: Node) -> void: object_destroyed.emit(s as TribesBaseObject, killer))
	objects.append(obj)
	obj.apply_power(true)
	deployed.emit(obj)
	return obj


## Faction ownership in a raid: every base object (turrets, sensors, stations) within an owner's `radius` of its `pos`
## takes that owner's `team`, the nearest owner winning, so a faction's soldiers, vehicles and turrets share a side
## (TeamRelations) and no longer fight each other. `owners`: [{pos: Vector3, radius: float, team: int}].
func apply_owners(owners: Array) -> void:
	for o in objects:
		var best_d := INF
		for ow in owners:
			var d: float = o.global_position.distance_to(ow.pos)
			if d <= float(ow.radius) and d < best_d:
				best_d = d
				o.apply_owner_team(int(ow.team))


## Neutral base: free-for-all or extraction (the stations and turrets belong to no player's team).
func is_neutral_match() -> bool:
	var config: Dictionary = battle.get("config") if battle.get("config") is Dictionary else {}
	return GameModes.is_free_for_all(config) or ExtractionRules.is_extraction(config)


# ------------------------------------------------------------------ power

## Recomputes every group's power from the working generators and gives each object its group's power.
func apply_power() -> void:
	var sources := []
	var held := []          # generators a soldier captured: they power the capturer's side only
	for o in objects:
		if o.is_power_source():
			(held if o.is_captured() else sources).append(o.power_group)
	var powered := grid.make_powered_groups(sources)
	var held_powered := grid.make_powered_groups(held) if not held.is_empty() else {}
	for o in objects:
		o.apply_power(powered.has(o.power_group) or (not held.is_empty() and _is_fed_by_captured(o, held_powered)))
	for f in fixtures:
		f.apply_power(powered.has(int(f.power_group)))
	power_changed.emit()


## True when a captured generator feeding `o`'s group is allied to `o` (a captured generator powers its captor's side).
func _is_fed_by_captured(o: TribesBaseObject, held_powered: Dictionary) -> bool:
	if not held_powered.has(o.power_group):
		return false
	for g in objects:
		if g.is_power_source() and g.is_captured() and g.power_group >= 0 \
				and grid.make_powered_groups([g.power_group]).has(o.power_group) and TeamRelations.is_allied(g.team, o.team):
			return true
	return false


## True when `obj` (a station node or base object) works: enabled and powered. Anything that is not base
## equipment counts as working.
static func is_working(obj: Object) -> bool:
	return not (obj is TribesBaseObject) or (obj as TribesBaseObject).is_working()


func _physics_process(delta: float) -> void:
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = STATE_CHECK_SECONDS
		for o in objects:
			o.apply_state_check()
		_apply_field_permeability()
	if sensor_net:
		sensor_net.apply_refresh(get_tree(), delta)
	if multiplayer.is_server():
		_apply_repair_packs(delta)
	if not ServerProfile.is_collision_only():
		_apply_repair_beams()


func _apply_field_permeability() -> void:
	var bodies := get_tree().get_nodes_in_group("vehicles")
	for f in fixtures:
		if f is TribesForceField:
			(f as TribesForceField).apply_permeability(bodies)


## Fixtures of `type` (tests).
func fixtures_of(type: Variant) -> Array:
	return fixtures.filter(func(f: Node3D) -> bool: return is_instance_of(f, type))


# ------------------------------------------------------------------ repair

func _apply_repair_packs(delta: float) -> void:
	var per_s := float(repair.get("per_s", 0.0))
	if per_s <= 0.0:
		return
	for h in battle.get("vehicles").values():
		var soldier := h as Infantry if is_instance_valid(h) else null
		if soldier and soldier.alive and is_repairing(soldier):
			var obj := find_repair_target(soldier)
			if obj:
				apply_object_repair(obj, soldier.team, per_s * delta)


## Host: `amount` points of repair work by a soldier of `by_team` on `obj`. Work for a team that is not allied to the
## object's owner captures it first (a neutral object, team -1, has no owner to take it from); a captured object's
## capturer keeps it going, its owner's work takes it back.
func apply_object_repair(obj: TribesBaseObject, by_team: int, amount: float) -> void:
	if obj.is_fully_repaired():
		return
	if BaseRepairRules.is_capture_on():
		var seconds := BaseRepairRules.make_capture_seconds()
		if obj.is_captured():
			if TeamRelations.is_allied(by_team, obj.home_team):
				obj.apply_release()
			else:
				obj.apply_capture(obj.team if TeamRelations.is_allied(by_team, obj.team) else by_team, seconds)
		elif obj.team >= 0 and not TeamRelations.is_allied(by_team, obj.team):
			obj.apply_capture(by_team, seconds)
	obj.apply_repair(amount)


## The soldier's repair pack is switched on.
static func is_repairing(soldier: Infantry) -> bool:
	return soldier.kit.pack_active and str(InfantryGear.pack(soldier.kit.pack_id).get("effect", "")) == "repair"


## The nearest damaged base object within the repair beam's reach: his own team's, a neutral one, and (capture rule on)
## an object of a team he is not allied to, which his repair work then captures.
func find_repair_target(soldier: Infantry) -> TribesBaseObject:
	var reach := float(repair.get("range", 0.0))
	var best: TribesBaseObject = null
	for o in objects:
		if o.is_fully_repaired() or o.invincible or not _may_repair(soldier.team, o):
			continue
		var d := make_reach_distance(soldier, o)
		if d <= reach:
			reach = d
			best = o
	return best


## True when a soldier of `team` may repair `o`: neutral, allied, or any (capture on).
func _may_repair(team: int, o: TribesBaseObject) -> bool:
	return o.team == NEUTRAL_TEAM or TeamRelations.is_allied(team, o.team) or BaseRepairRules.is_capture_on()


## The damaged or downed object of the side `soldier` belongs to that bot `bot_id` should repair now (null when none):
## the nearest within BaseRepairRules faction_repair.search_m, generators first, no other live bot already on it,
## none that `is_skipped` (func(obj) -> bool: the bot gave it up) refuses.
func find_job_for(soldier: Infantry, bot_id: int, is_skipped := Callable()) -> TribesBaseObject:
	var rules := BaseRepairRules.faction()
	if not bool(rules.get("enabled", false)):
		return null
	var best: TribesBaseObject = null
	var best_score := float(rules.get("search_m", 0.0))
	for o in objects:
		if o.is_fully_repaired() or o.invincible or o.team < 0 or not TeamRelations.is_allied(soldier.team, o.team) \
				or (_job_of.has(o) and int(_job_of[o]) != bot_id and _is_job_live(o)) 				or (is_skipped.is_valid() and bool(is_skipped.call(o))):
			continue
		var score := soldier.global_position.distance_to(o.global_position)
		if o.kind == TribesBaseObject.KIND_GENERATOR:
			score *= float(rules.get("generator_priority", 1.0))
		if score < best_score:
			best_score = score
			best = o
	if best:
		apply_job_claim(best, bot_id)
	return best


## Host: a repairing bot keeps its claim fresh; a claim not renewed for JOB_STALE_SECONDS lapses.
func apply_job_claim(obj: TribesBaseObject, bot_id: int) -> void:
	_job_of[obj] = bot_id
	_job_ms[obj] = Time.get_ticks_msec()


func _is_job_live(o: TribesBaseObject) -> bool:
	return (Time.get_ticks_msec() - int(_job_ms.get(o, 0))) < int(JOB_STALE_SECONDS * 1000.0)


## Distance from the soldier to the object's surface, roughly: centre distance less the shape's half width.
static func make_reach_distance(soldier: Node3D, o: TribesBaseObject) -> float:
	return maxf(0.0, soldier.global_position.distance_to(o.global_position) - o.make_body_size().x)


# ------------------------------------------------------------------ repair beams

## Every peer: a beam from each repairing soldier (pack on, or a crew member at work) to the object it repairs.
func _apply_repair_beams() -> void:
	var live := {}
	for h in battle.get("vehicles").values():
		var soldier := h as Infantry if is_instance_valid(h) else null
		if soldier == null or not soldier.alive:
			continue
		var obj: TribesBaseObject = null
		var job = soldier.get_meta(META_REPAIR_JOB) if soldier.has_meta(META_REPAIR_JOB) else null
		if job is TribesBaseObject and is_instance_valid(job) and not (job as TribesBaseObject).is_fully_repaired():
			obj = job
		elif is_repairing(soldier):
			obj = find_repair_target(soldier)
		if obj == null:
			continue
		live[soldier] = true
		if not _beams.has(soldier):
			_beams[soldier] = TribesRepairBeam.make(battle)
		(_beams[soldier] as TribesRepairBeam).apply_between(soldier.global_position + Vector3.UP * TribesRepairBeam.SOLDIER_CHEST,
			obj.global_position + Vector3.UP * TribesRepairBeam.OBJECT_MIDDLE)
	for soldier in _beams.keys():
		if not live.has(soldier):
			if is_instance_valid(_beams[soldier]):
				(_beams[soldier] as Node).queue_free()
			_beams.erase(soldier)


# ------------------------------------------------------------------ sensors

## True when `unit` shows on `viewer`'s radar: always outside a Tribes base battle, else by the viewer's team's
## sensor net (radars skip the other blips).
static func is_on_radar(viewer: Node, unit: Node) -> bool:
	var base := of(viewer.get_parent()) if viewer else null
	return base == null or base.sensor_net == null or base.sensor_net.is_shown(int(viewer.get("team")), unit)


## Base objects of `kind` (tests, game modes).
func objects_of(kind: String) -> Array[TribesBaseObject]:
	var out: Array[TribesBaseObject] = []
	for o in objects:
		if o.kind == kind:
			out.append(o)
	return out
