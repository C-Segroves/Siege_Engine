class_name TribesBase
extends Node
## The bases of a Tribes / Tribes 2 map in a battle (child "TribesBase" of the Battle; docs/TRIBES_BASE_EQUIPMENT.md):
## every map station with a base_equipment.json spec (generators, solar panels, sensors, turrets, stations, pads)
## becomes a TribesBaseObject (TribesTurret for armed turrets) in place of the plain shape MapBuilder placed.
##   power     TribesPowerGrid: generators power their group and the groups below; checked on every peer (each
##             sees the same damage states), so stations, turrets and sensors switch on and off everywhere;
##   repair    host: a soldier whose repair pack is on repairs the nearest damaged friendly base object within
##             the repair beam's reach at the game's object repair rate (base_equipment.json "repair");
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
static var _specs := {}          # pack -> base_equipment.json


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
		var j = Assets.load_json(SPECS_FILE, pack) if pack != "" else null
		_specs[pack] = j if j is Dictionary else {}
	return _specs[pack]


## The spec of map station `record` ({} when it is not base equipment).
static func make_spec(pack: String, record: Dictionary) -> Dictionary:
	var key := str(record.get("spec", ""))
	return load_specs(pack).get("blocks", {}).get(key, {}) if key != "" else {}


func _build_objects(stations: Array, pack: String, pal: String) -> void:
	var neutral := is_neutral_match()
	for st in stations:
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


## Neutral base: free-for-all or extraction (the stations and turrets belong to no player's team).
func is_neutral_match() -> bool:
	var config: Dictionary = battle.get("config") if battle.get("config") is Dictionary else {}
	return GameModes.is_free_for_all(config) or ExtractionRules.is_extraction(config)


# ------------------------------------------------------------------ power

## Recomputes every group's power from the working generators and gives each object its group's power.
func apply_power() -> void:
	var sources := []
	for o in objects:
		if o.is_power_source():
			sources.append(o.power_group)
	var powered := grid.make_powered_groups(sources)
	for o in objects:
		o.apply_power(powered.has(o.power_group))
	for f in fixtures:
		f.apply_power(powered.has(int(f.power_group)))
	power_changed.emit()


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
				obj.apply_repair(per_s * delta)


## The soldier's repair pack is switched on.
static func is_repairing(soldier: Infantry) -> bool:
	return soldier.kit.pack_active and str(InfantryGear.pack(soldier.kit.pack_id).get("effect", "")) == "repair"


## The nearest damaged base object of the soldier's team (or neutral) within the repair beam's reach.
func find_repair_target(soldier: Infantry) -> TribesBaseObject:
	var reach := float(repair.get("range", 0.0))
	var best: TribesBaseObject = null
	for o in objects:
		if o.is_fully_repaired() or o.invincible or not (o.team == soldier.team or o.team == NEUTRAL_TEAM):
			continue
		var d := _reach_distance(soldier, o)
		if d <= reach:
			reach = d
			best = o
	return best


## Distance from the soldier to the object's surface, roughly: centre distance less the shape's half width.
static func _reach_distance(soldier: Node3D, o: TribesBaseObject) -> float:
	return maxf(0.0, soldier.global_position.distance_to(o.global_position) - o.make_body_size().x)


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
