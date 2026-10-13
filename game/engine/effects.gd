extends Node
## Transient visual effects. Weapon shots, beams, impacts and deaths are data-driven per game through `fx`
## (FxPlayer, DeathFx; docs/formats/weapon_fx.md); the plain shapes below are only the generic look of things
## without original effect data (weapons and deaths of a pack imported without fx data). Game code never calls
## explosion() directly: FxPlayer does, as the documented last resort (counted in fx.generic_explosions).

## Data-driven weapon effects player (engine/fx).
var fx: FxPlayer


func _ready() -> void:
	fx = FxPlayer.new()
	fx.name = "FxPlayer"
	add_child(fx)


func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _fade_and_free(n: Node3D, mat: StandardMaterial3D, time: float, grow := 1.0) -> void:
	var tw := n.create_tween()
	tw.set_parallel(true)
	tw.tween_property(mat, "albedo_color:a", 0.0, time)
	if grow != 1.0:
		tw.tween_property(n, "scale", n.scale * grow, time)
	tw.chain().tween_callback(n.queue_free)


func beam(parent: Node, from: Vector3, to: Vector3, color: Color, width := 0.18, time := 0.12) -> void:
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	var length := from.distance_to(to)
	m.size = Vector3(width, width, length)
	mi.mesh = m
	var mat := _unshaded(color)
	mi.material_override = mat
	parent.add_child(mi)
	mi.global_position = (from + to) * 0.5
	if length > 0.01:
		mi.look_at(to, Vector3.UP if absf((to - from).normalized().y) < 0.99 else Vector3.RIGHT)
	_fade_and_free(mi, mat, time)


## Small trail puff (missile smoke / plasma glow).
func puff(parent: Node, pos: Vector3, kind := "smoke") -> void:
	var c := Color(0.75, 0.75, 0.72, 0.6) if kind == "smoke" else Color(0.5, 1.0, 0.6, 0.7)
	_ball(parent, pos, 0.6, c, 0.6, 2.5)


func spark(parent: Node, pos: Vector3, size := 0.8) -> void:
	_ball(parent, pos, size, Color(1.0, 0.85, 0.4), 0.25, 2.0)


func explosion(parent: Node, pos: Vector3, size := 3.0) -> void:
	Sfx.play_at("big_explosion" if size > 2.0 else "explosion", pos, 4.0)
	_ball(parent, pos, size, Color(1.0, 0.55, 0.15), 0.9, 3.0)
	_ball(parent, pos + Vector3.UP * size * 0.5, size * 0.7, Color(0.25, 0.22, 0.2), 1.8, 3.5)


func _ball(parent: Node, pos: Vector3, size: float, color: Color, time: float, grow: float) -> void:
	if parent == null:
		return
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = size * 0.5
	m.height = size
	m.radial_segments = 8
	m.rings = 4
	mi.mesh = m
	var mat := _unshaded(color)
	mi.material_override = mat
	parent.add_child(mi)
	mi.global_position = pos
	_fade_and_free(mi, mat, time, grow)
