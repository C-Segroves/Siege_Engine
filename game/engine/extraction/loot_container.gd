class_name LootContainer
extends Node3D
## A lootable object in a raid (ExtractionDirector; docs/design/extraction.md section 4): a cache placed when the
## raid starts (supply cache, weapons locker, salvage crate), the bag a killed soldier drops or the salvage of a
## wreck. It shows the first model of its kind's "shapes" the user has imported (ExtractionRules caches), sized to
## a crate, else a plain box. Every peer builds it from the host's record; the host decides its contents.
## Record (network form): {id, kind, pos: Vector3, stacks: [[item id, count], ...], money}.

## The model's largest extent is kept within these (metres): ammo boxes grow, cargo boxes shrink to a crate.
const MIN_SIZE := 0.9
const MAX_SIZE := 1.6
const FALLBACK_SIZE := Vector3(1.0, 0.7, 0.7)
const FALLBACK_COLOR := Color(0.35, 0.42, 0.3)
const BAG_COLOR := Color(0.55, 0.3, 0.2)
const BEACON_HEIGHT := 40.0
const BEACON_COLOR := Color(1.0, 0.85, 0.2, 0.55)

var container_id := 0
var kind := "supply"
var stacks: Array = []
var money := 0
## A model of its own instead of its kind's (a faction flag: the map flag's shape), kept at its size.
var shape_override := ""


static func make(record: Dictionary) -> LootContainer:
	var c := LootContainer.new()
	c.container_id = int(record.id)
	c.kind = str(record.kind)
	c.name = "Loot%d" % c.container_id
	c.position = record.pos
	c.shape_override = str(record.get("shape", ""))
	c.apply_contents(record.get("stacks", []), int(record.get("money", 0)))
	return c


func _ready() -> void:
	add_to_group("loot_containers")
	_build_model()


func apply_contents(p_stacks: Array, p_money: int) -> void:
	stacks = p_stacks.duplicate(true)
	money = p_money


func is_empty() -> bool:
	return stacks.is_empty() and money <= 0


## Items (units) and money left in it.
func make_item_count() -> int:
	var n := 0
	for s in stacks:
		n += int(s[1])
	return n


## "Supply cache", "Dropped gear".
func make_title() -> String:
	return str(ExtractionRules.cache(kind).get("name", kind.capitalize()))


func make_record() -> Dictionary:
	return {"id": container_id, "kind": kind, "pos": position, "stacks": stacks.duplicate(true), "money": money,
		"shape": shape_override}


func _build_model() -> void:
	if ServerProfile.is_collision_only():
		return   # a container is a point to open; nobody sees it on the server
	if kind == "flag":
		_build_beacon()
	var shape_id := shape_override if _is_imported(shape_override) else make_shape_id(kind)
	if shape_id == "":
		_build_fallback_box()
		return
	var model := ShapeInstance.new()
	add_child(model)
	model.build(Assets.shape(shape_id), 0, Packs.default_palette(Assets.split_id(shape_id)[0]))
	var extent := _make_world_box(model).get_longest_axis_size()
	if extent > 0.0 and shape_id != shape_override:
		model.scale *= clampf(extent, MIN_SIZE, MAX_SIZE) / extent
	model.position.y -= _make_world_box(model).position.y - global_position.y   # standing on its base


## A faction flag shows from afar: a tall, unshaded light column over it.
func _build_beacon() -> void:
	var beam := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.15
	cyl.bottom_radius = 0.15
	cyl.height = BEACON_HEIGHT
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = BEACON_COLOR
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	cyl.material = mat
	beam.mesh = cyl
	beam.position.y = BEACON_HEIGHT * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(beam)


## The first imported model of the kind's shapes ("" when none is imported).
static func make_shape_id(container_kind: String) -> String:
	for shape_id in ExtractionRules.cache(container_kind).get("shapes", []):
		if _is_imported(str(shape_id)):
			return str(shape_id)
	return ""


static func _is_imported(shape_id: String) -> bool:
	if shape_id == "" or not shape_id.contains(":"):
		return false
	var parts := Assets.split_id(shape_id)
	return FileAccess.file_exists(Assets.path("shapes/%s.json" % parts[1], parts[0]))


## The model's bounding box (world metres).
static func _make_world_box(model: ShapeInstance) -> AABB:
	var box := AABB()
	var first := true
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		if not (mi as MeshInstance3D).is_visible_in_tree():
			continue
		var aabb: AABB = (mi as MeshInstance3D).get_aabb()
		for k in 8:
			var p: Vector3 = (mi as MeshInstance3D).global_transform * aabb.get_endpoint(k)
			box = AABB(p, Vector3.ZERO) if first else box.expand(p)
			first = false
	return box


func _build_fallback_box() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = FALLBACK_SIZE
	var mat := StandardMaterial3D.new()
	mat.albedo_color = BAG_COLOR if kind == "bag" else FALLBACK_COLOR
	box.material = mat
	mesh.mesh = box
	mesh.position.y = FALLBACK_SIZE.y * 0.5
	add_child(mesh)
