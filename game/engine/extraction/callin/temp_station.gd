class_name TempStation
extends Structure
## A temporary station a call-in pod leaves (repair station, inventory station; docs/design/lobby_loadout_economy.md section 9.5): a
## destructible structure of the caller's team with reduced hit points that CallinDirector removes when its time is up.
## Every peer builds it from the host's record, under the same node name (hits and the destruction reach it by rpc). It
## shows the first imported shape of its call-in's "shapes" else a plain pillar on a pad, and blinks while it expires.
## Record (network form): {id, kind, team, pos: Vector3, hp}.

const PAD_RADIUS := 1.6
const PAD_HEIGHT := 0.15
const PILLAR_SIZE := Vector3(0.9, 2.2, 0.9)
const COLORS := {"repair_station": Color(0.25, 0.7, 0.4), "inventory_station": Color(0.3, 0.5, 0.8)}
const BLINK_HZ := 4.0
## Collision of the plain model (a cylinder the size of the pad and pillar).
const PLAIN_COLLISION_HEIGHT := 2.4

var station_id := 0
var station_kind := ""
var expiring := false
var _plain: Node3D


static func create_station(parent: Node3D, record: Dictionary) -> TempStation:
	var s := TempStation.new()
	s.apply_record(record, make_node_name(int(record.id)))
	parent.add_child(s)
	s.global_position = record.pos
	s.add_to_group(TARGET_GROUP)
	s._build_visual()
	return s


## Takes the fields of the host's record (shared with CallinCrate).
func apply_record(record: Dictionary, node_name: String) -> void:
	station_id = int(record.id)
	station_kind = str(record.kind)
	team = int(record.team)
	max_hp = float(record.hp)
	hp = max_hp
	display_name = CallinRules.make_label(station_kind)
	name = node_name


static func make_node_name(id: int) -> String:
	return "CallinStation%d" % id


func _process(_delta: float) -> void:
	if expiring:
		visible = int(Time.get_ticks_msec() / 1000.0 * BLINK_HZ * 2.0) % 2 == 0


func _build_visual() -> void:
	var candidate := CallinRules.pick_imported_shape(CallinRules.rule(station_kind).get("shapes", []))
	if candidate != "" and not ServerProfile.is_collision_only():
		shape = ShapeInstance.new()
		add_child(shape)
		shape.build(Assets.shape(candidate), 0, Packs.default_palette(Assets.split_id(candidate)[0]))
		shape_id = candidate
		build_collision()
		return
	_build_plain()


## The plain station: a pad with a pillar, and a cylinder collision (hits land on it).
func _build_plain() -> void:
	_plain = Node3D.new()
	add_child(_plain)
	var color: Color = COLORS.get(station_kind, Color(0.5, 0.5, 0.5))
	_plain.add_child(_make_mesh(_make_cylinder(PAD_RADIUS, PAD_HEIGHT), color.darkened(0.4), PAD_HEIGHT * 0.5))
	var pillar := BoxMesh.new()
	pillar.size = PILLAR_SIZE
	_plain.add_child(_make_mesh(pillar, color, PILLAR_SIZE.y * 0.5 + PAD_HEIGHT))
	var col := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = PAD_RADIUS
	cyl.height = PLAIN_COLLISION_HEIGHT
	col.shape = cyl
	col.position.y = PLAIN_COLLISION_HEIGHT * 0.5
	add_child(col)


static func _make_cylinder(radius: float, height: float) -> CylinderMesh:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = height
	return cyl


static func _make_mesh(mesh: Mesh, color: Color, y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh.material = mat
	mi.mesh = mesh
	mi.position.y = y
	return mi


# ------------------------------------------------------------------ Structure overrides (a plain model has no shape)

func apply_ruined_look() -> void:
	if shape != null:
		super.apply_ruined_look()
	elif _plain != null:
		_plain.scale = RUINED_SCALE


func apply_intact_look() -> void:
	if shape != null:
		super.apply_intact_look()


func make_body_size() -> Vector2:
	return super.make_body_size() if shape != null else Vector2(PAD_RADIUS, PILLAR_SIZE.y)


## A destroyed station flashes and smokes; the host removes it a moment later.
func _play_destruction() -> void:
	if ServerProfile.is_collision_only():
		return
	Effects.puff(get_parent(), global_position + Vector3.UP * 1.5, "smoke")
	Sfx.play_at("big_explosion", global_position, 0.0)
