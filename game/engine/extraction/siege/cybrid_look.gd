class_name CybridLook
extends RefCounted
## The Cybrid look of the siege, made without any copied art: a dark brushed-metal shader with glowing red panel seams
## (engine/shaders/cybrid_metal.gdshader) laid over every mesh of the body, and for a soldier a red visor bar on the eye
## node. Cybrid Hercs of the games keep their own models; soldiers (which no game has as Cybrids) and the Hercs that
## stand in where no Cybrid pack is installed wear this. SiegeLooks applies it on every peer by team.

const SHADER := preload("res://engine/shaders/cybrid_metal.gdshader")
const META_LOOKED := "cybrid_look"
const VISOR_NAME := "CybridVisor"
const VISOR_SIZE := Vector3(0.22, 0.04, 0.05)
const VISOR_AT := Vector3(0.0, -0.08, -0.2)
const VISOR_COLOR := Color(1.0, 0.08, 0.04)
const VISOR_ENERGY := 6.0

static var _material: ShaderMaterial


static func get_material() -> ShaderMaterial:
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
	return _material


## True when `unit` should wear the look: a soldier, or a vehicle that is not a Cybrid by its own data.
static func is_wanted(unit: Node) -> bool:
	if unit is Infantry:
		return true
	return unit is Herc and str((unit as Herc).def.get("side", "")) != ExtractionFactions.KIND_CYBRID


static func is_applied(unit: Node) -> bool:
	return unit.has_meta(META_LOOKED)


## Lays the look over `unit`'s meshes (and a soldier's visor); false when there was nothing to draw on yet.
static func apply(unit: Node) -> bool:
	var meshes := CloakVisual.make_meshes(unit)
	if meshes.is_empty():
		return false
	for m in meshes:
		m.material_override = get_material()
	if unit is Infantry:
		_apply_visor(unit as Infantry)
	unit.set_meta(META_LOOKED, true)
	return true


static func _apply_visor(soldier: Infantry) -> void:
	if soldier.eye == null or soldier.eye.get_node_or_null(VISOR_NAME) != null:
		return
	var visor := MeshInstance3D.new()
	visor.name = VISOR_NAME
	var box := BoxMesh.new()
	box.size = VISOR_SIZE
	visor.mesh = box
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = VISOR_COLOR
	mat.emission_enabled = true
	mat.emission = VISOR_COLOR
	mat.emission_energy_multiplier = VISOR_ENERGY
	visor.material_override = mat
	visor.position = VISOR_AT
	visor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	soldier.eye.add_child(visor)
