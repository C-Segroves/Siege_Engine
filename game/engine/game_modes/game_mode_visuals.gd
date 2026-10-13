class_name GameModeVisuals
extends Node3D
## What the players see of a mode's objects (every peer, from the rules' replicated state): flags (the original
## flag shapes: Tribes flag, Tribes 2 flag and Hunters flag, Starsiege team flags) at home, on the ground or on
## their carrier's back, the Football ball over its carrier, and a beacon in the holding team's colour over each
## switch, and a light pillar over a flag carrier while a stalemate reveals him (CtfRules.revealed). Static objects (stands, the Nexus, switches themselves) stay the map's own placements.

const MOVING_KINDS := [ModeObject.KIND_FLAG, ModeObject.KIND_HUNTER_FLAG, ModeObject.KIND_BALL]
const HUNTERS_FLAG_SHAPE := "tribes2:huntersflag"
## Metres above a carrier's origin: on a soldier's back / over a Herc's hull.
const CARRY_HEIGHT_SOLDIER := 1.2
const CARRY_HEIGHT_VEHICLE := 7.0
const BEACON_HEIGHT := 3.0
const BEACON_RADIUS := 0.45
const BALL_RADIUS := 1.2
const POLE_HEIGHT := 2.4
const POLE_RADIUS := 0.05
const CLOTH_SIZE := Vector3(1.0, 0.6, 0.04)
const NEUTRAL_COLOR := Color(0.75, 0.75, 0.75)
const BALL_COLOR := Color(1.0, 0.85, 0.2)
## The stalemate pillar over a revealed carrier.
const BEACON_PILLAR_HEIGHT := 60.0
const BEACON_PILLAR_RADIUS := 0.6
const BEACON_NAME := "StalemateBeacon"
const HUNTERS_COLORS := {1: Color(0.9, 0.2, 0.15), 2: Color(0.2, 0.45, 0.95), 4: Color(0.95, 0.85, 0.2), 8: Color(0.25, 0.8, 0.3)}

var battle: Battle
var _nodes := {}       # object id -> Node3D


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "ModeObjects"


## Removes the map's own flag placements (static, with collision): the mode draws the flags where they really are.
static func apply_hidden_station_flags(built_stations: Array) -> void:
	for s in built_stations:
		if str(s.get("kind", "")) == ModeObject.KIND_FLAG and is_instance_valid(s.get("node")):
			(s.node as Node).queue_free()


## Every frame: one node per drawn object, placed from the state.
func apply(rules: GameModeRules) -> void:
	for id in _nodes.keys():
		if not rules.objects.has(id):
			_nodes[id].queue_free()
			_nodes.erase(id)
	for o in rules.objects.values():
		if not (o.kind in MOVING_KINDS or o.kind == ModeObject.KIND_SWITCH):
			continue
		if not _nodes.has(o.id):
			_nodes[o.id] = _build(o)
		_place(_nodes[o.id], o)
		_apply_beacon(_nodes[o.id], o.state == ModeObject.CARRIED and bool(rules.get("revealed")))


func _place(node: Node3D, o: ModeObject) -> void:
	node.visible = not (o.state in [ModeObject.GONE, ModeObject.DESTROYED])
	if o.kind == ModeObject.KIND_SWITCH:
		node.position = o.pos + Vector3.UP * BEACON_HEIGHT
		_apply_color(node, _team_color(o.owner_team))
		return
	var carrier: Herc = battle.vehicles.get(o.carrier) if o.state == ModeObject.CARRIED else null
	if is_instance_valid(carrier):
		var up := CARRY_HEIGHT_SOLDIER if carrier is Infantry else CARRY_HEIGHT_VEHICLE
		node.position = carrier.global_position + Vector3.UP * up
		node.visible = node.visible and carrier.visible
	else:
		node.position = o.pos
	node.rotation = Vector3(0, deg_to_rad(o.yaw), 0)


func _apply_beacon(node: Node3D, on: bool) -> void:
	var beacon := node.get_node_or_null(BEACON_NAME) as Node3D
	if beacon == null and on:
		var m := MeshInstance3D.new()
		var c := CylinderMesh.new()
		c.top_radius = BEACON_PILLAR_RADIUS
		c.bottom_radius = BEACON_PILLAR_RADIUS
		c.height = BEACON_PILLAR_HEIGHT
		m.mesh = c
		m.position.y = BEACON_PILLAR_HEIGHT * 0.5
		m.material_override = _make_material(BALL_COLOR)
		m.name = BEACON_NAME
		node.add_child(m)
		beacon = m
	if beacon != null:
		beacon.visible = on


func _build(o: ModeObject) -> Node3D:
	var node: Node3D
	match o.kind:
		ModeObject.KIND_SWITCH:
			node = _build_sphere(BEACON_RADIUS, NEUTRAL_COLOR)
		ModeObject.KIND_BALL:
			node = _build_sphere(BALL_RADIUS, BALL_COLOR)
		ModeObject.KIND_HUNTER_FLAG:
			node = _build_shape(HUNTERS_FLAG_SHAPE, HUNTERS_COLORS.get(int(o.value), NEUTRAL_COLOR))
		_:
			node = _build_shape(o.shape, _team_color(o.team))
	node.name = "Mode_%s_%d" % [o.kind, o.id]
	add_child(node)
	return node


## The original shape when it was imported, else a pole with a cloth in `color`.
func _build_shape(shape_id: String, color: Color) -> Node3D:
	var shape := Assets.shape(shape_id) if shape_id != "" else {}
	if shape.get("lods", [{}])[0].get("pieces", []).is_empty():
		return _build_flag_stand_in(color)
	var inst := ShapeInstance.new()
	var root := Node3D.new()
	root.add_child(inst)
	var spack: String = Assets.split_id(shape_id)[0]
	var pal := Packs.default_palette(spack)
	inst.build(shape, 0, pal if pal != "" else battle.palette_id)
	return root


func _build_flag_stand_in(color: Color) -> Node3D:
	var root := Node3D.new()
	var pole := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = POLE_RADIUS
	cyl.bottom_radius = POLE_RADIUS
	cyl.height = POLE_HEIGHT
	pole.mesh = cyl
	pole.position.y = POLE_HEIGHT * 0.5
	root.add_child(pole)
	var cloth := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = CLOTH_SIZE
	cloth.mesh = box
	cloth.position = Vector3(CLOTH_SIZE.x * 0.5, POLE_HEIGHT - CLOTH_SIZE.y * 0.5, 0)
	cloth.material_override = _make_material(color)
	cloth.name = "Cloth"
	root.add_child(cloth)
	return root


func _build_sphere(radius: float, color: Color) -> Node3D:
	var m := MeshInstance3D.new()
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0
	m.mesh = s
	m.material_override = _make_material(color)
	return m


static func _make_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color * 0.6
	return mat


func _apply_color(node: Node3D, color: Color) -> void:
	var mi := node as MeshInstance3D
	if mi and mi.material_override is StandardMaterial3D:
		var mat := mi.material_override as StandardMaterial3D
		if mat.albedo_color != color:
			mat.albedo_color = color
			mat.emission = color * 0.6


func _team_color(team: int) -> Color:
	return MapTeams.make_team_color(team) if team >= 0 else NEUTRAL_COLOR
