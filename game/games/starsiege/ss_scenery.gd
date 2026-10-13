class_name SSScenery
extends RefCounted
## The static part of a Starsiege mission, built on every peer: static shapes as SSStructures, turrets
## as SSTurrets (they fire on the host), interiors the map does not already place (map.json
## "interiors", built with collision by MapBuilder) as SSStructures, and markers for nav points, path
## markers, drop points, triggers, map-placed interiors and objects whose shape was not converted.

## Engine hit points of a structure whose record has no damage block (the mission records carry their
## own sustainable damage, SSStructure.apply_damage_block).
const STRUCTURE_HP := 3000.0
## Interiors are scenery: effectively indestructible.
const INTERIOR_HP := 1e12
const STRUCTURE_KINDS := ["static", "turret", "interior"]
const MARKER_KINDS := ["nav_marker", "marker", "drop_point", "trigger"]


## Builds every scenery object of the runtime's tree; structures are handed to rt.watch_structure.
static func build(rt: StarsiegeMissionRuntime) -> void:
	for id in rt.tree.objects:
		var o: Dictionary = rt.tree.objects[id]
		if o.kind in STRUCTURE_KINDS:
			_build_structure(rt, id, o)
		elif o.kind in MARKER_KINDS:
			_build_marker(rt.battle, o)


static func _build_structure(rt: StarsiegeMissionRuntime, id: int, o: Dictionary) -> void:
	var d: Dictionary = o.def
	var sid := String(d.get("shape", ""))
	if bool(d.get("in_map", false)):
		o.node = _add_marker(rt.battle, SSObjectTree.position_of_def(d))
		return
	if sid == "" or not _shape_exists(sid):
		o["missing_shape"] = true
		o.node = _add_marker(rt.battle, SSObjectTree.position_of_def(d))
		return
	var xf := Transform3D(Basis(Vector3.UP, float(d.get("yaw", 0.0))), SSObjectTree.position_of_def(d))
	var team: int = StarsiegeMissionRuntime.TEAM_OF.get(o.team, SSTeams.NEUTRAL)
	var spec := {"shape": sid, "xf": xf, "palette": rt.battle.palette_id, "team": team, "hp": STRUCTURE_HP,
		"collide": true}
	var st: SSStructure
	if o.kind == "turret":
		st = SSTurret.make_turret(rt.battle, spec, d)
	else:
		st = SSStructure.new()
		st.build_body(rt.battle, spec)
	st.ss_id = id
	st.display_name = String(d.get("name", "Structure"))
	if o.kind == "interior":
		st.hp = INTERIOR_HP
		st.max_hp = INTERIOR_HP
	else:
		st.apply_damage_block(d, rt.damage_factor)
		o.alive = st.alive
	st.apply_targetable(team != SSTeams.NEUTRAL and not st.indestructible)   # rocks and props are scenery
	o.node = st
	rt.watch_structure(st, id)


static func _build_marker(battle: Node3D, o: Dictionary) -> void:
	var d: Dictionary = o.def
	var mk := _add_marker(battle, SSObjectTree.position_of_def(d))
	mk.rotation.y = float(d.get("yaw", 0.0))
	o.node = mk
	if o.kind == "nav_marker":
		mk.set_meta("label", String(d.get("name", "NAV")))
		o["nav_on"] = false
		o["nav_selected"] = false


static func _add_marker(battle: Node3D, pos: Vector3) -> Marker3D:
	var mk := Marker3D.new()
	mk.position = pos
	battle.add_child(mk)
	return mk


static func _shape_exists(shape_id: String) -> bool:
	var sp := Assets.split_id(shape_id)
	return FileAccess.file_exists(Assets.path("shapes/%s.json" % sp[1], sp[0]))
