class_name CallinCrate
extends TempStation
## The crate a call-in pod leaves (armour drop, ammo drop; docs/design/lobby_loadout_economy.md section 9.5): a cargo-box model the
## soldier uses with interact (CallinDirector provides the offer). Like a station it is a destructible structure of the
## caller's team (enemies may shoot it; the order ends with it) and blinks while it is about to vanish. Every peer builds it
## from the host's record, the host decides what a use does.
## Record (network form): {id, kind, variant, team, pos: Vector3, uses, hp}.

const MIN_SIZE := 0.9
const MAX_SIZE := 1.6
const FALLBACK_SIZE := Vector3(1.2, 0.9, 0.9)
const BEAM_HEIGHT := 14.0
const BEAM_WIDTH := 0.12
const FALLBACK_COLORS := {"armor_drop": Color(0.3, 0.45, 0.75), "ammo_drop": Color(0.75, 0.65, 0.2)}
const BEAM_COLOR := Color(0.4, 1.0, 0.6, 0.5)

var variant := ""
var uses_left := 1
var _model: Node3D
var _beam: MeshInstance3D


static func create_crate(parent: Node3D, record: Dictionary) -> CallinCrate:
	var c := CallinCrate.new()
	c.variant = str(record.get("variant", ""))
	c.uses_left = int(record.get("uses", 1))
	c.apply_record(record, "CallinCrate%d" % int(record.id))
	parent.add_child(c)
	c.global_position = record.pos
	c.add_to_group(TARGET_GROUP)
	c.add_to_group("callin_crates")
	c._build_visual()
	return c


## "Armour drop: medium", "Ammo drop (2 uses left)".
func make_title() -> String:
	var title := CallinRules.make_label(station_kind) if variant == "" else "%s: %s" % [CallinRules.make_label(station_kind), variant]
	return title if uses_left <= 1 else "%s (%d uses left)" % [title, uses_left]


func _process(_delta: float) -> void:
	super._process(_delta)
	if _beam != null:
		_beam.visible = visible


func _build_visual() -> void:
	if ServerProfile.is_collision_only():
		_build_collision_box()
		return
	var shape_id := CallinRules.pick_imported_shape(CallinRules.rule(station_kind).get("shapes", []))
	if shape_id == "":
		_model = _make_fallback_box()
		add_child(_model)
	else:
		var model := ShapeInstance.new()
		add_child(model)
		model.build(Assets.shape(shape_id), 0, Packs.default_palette(Assets.split_id(shape_id)[0]))
		var extent := LootContainer._make_world_box(model).get_longest_axis_size()
		if extent > 0.0:
			model.scale *= clampf(extent, MIN_SIZE, MAX_SIZE) / extent
		model.position.y -= LootContainer._make_world_box(model).position.y - global_position.y   # standing on its base
		_model = model
	_build_collision_box()
	_build_beam()


func _build_collision_box() -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = FALLBACK_SIZE
	col.shape = box
	col.position.y = FALLBACK_SIZE.y * 0.5
	add_child(col)


func _make_fallback_box() -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = FALLBACK_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FALLBACK_COLORS.get(station_kind, Color(0.5, 0.5, 0.5))
	box.material = mat
	mesh.mesh = box
	mesh.position.y = FALLBACK_SIZE.y * 0.5
	return mesh


## A light column over it so it can be found from afar.
func _build_beam() -> void:
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = BEAM_WIDTH
	cyl.bottom_radius = BEAM_WIDTH
	cyl.height = BEAM_HEIGHT
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = BEAM_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cyl.material = mat
	_beam.mesh = cyl
	_beam.position.y = BEAM_HEIGHT * 0.5
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)


func apply_ruined_look() -> void:
	if _model != null:
		_model.scale = RUINED_SCALE
	if _beam != null:
		_beam.queue_free()
		_beam = null


func make_body_size() -> Vector2:
	return Vector2(FALLBACK_SIZE.x * 0.5, FALLBACK_SIZE.y)
