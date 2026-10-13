class_name FxProjectileLook
extends Node3D
## What a projectile looks like in flight, from its weapon's fx "projectile" and "trail" blocks
## (weapon_fx.md 1.2): an animated bitmap billboard, a 3D shape rolling at the original spin rate, a
## velocity-aligned tracer streak or a coloured glow, an optional carried light, and a trail of puffs
## (effect library entries or plain soft puffs). A child of the Projectile, whose -z is the flight direction.

const TRACER_WIDTH_SHARE := 0.12
const MIN_TRACER_WIDTH := 0.08
const DEFAULT_SIZE := 0.8
const LIGHT_ENERGY := 1.5
const DEFAULT_TRAIL_INTERVAL := 0.06
## Ribbon trails (Torque blur) are drawn as dense puffs: at most this often.
const MIN_TRAIL_INTERVAL := 0.025

var _pack := ""
var _spin := Vector3.ZERO       # rad/s: a number is a roll about the flight axis (-z); [x, y, z] spins about
                                 # world-up-style axes (Battledrome mine yaw is [0, y, 0])
var _spinner: Node3D
var _lifetime := 0.0
var _streak: Node3D
var _cross: FxSprite
var _cross_view_cos := 1.0
var _trail := {}
var _trail_t := 0.0
var _shape: ShapeInstance
var _cycles: Array[int] = []    # cyclic Torque sequences of the shape (grenade spin, mortar wobble), looped
var _cycle_t := 0.0


## Builds the look for weapon definition `def` (FxLibrary.weapon_fx), `fallback_color` when it names none;
## `lifetime` (s) drives phased sprites.
static func create(def: Dictionary, fallback_color: Color, lifetime: float) -> FxProjectileLook:
	var look := FxProjectileLook.new()
	look.name = "FxLook"
	var fx := FxLibrary.weapon_fx(def)
	look._pack = FxLibrary.weapon_pack(def)
	var block: Dictionary = fx.projectile if fx.get("projectile") is Dictionary else {}
	look._lifetime = lifetime
	look._build_body(block, fallback_color)
	look._build_light(block.get("light"))
	look._trail = fx.trail if fx.get("trail") is Dictionary else {}
	return look


func _build_body(block: Dictionary, fallback_color: Color) -> void:
	var color := FxLibrary.make_block_color(block, _pack, fallback_color)
	var size := float(block.get("size", DEFAULT_SIZE))
	_spin = _make_spin(block.get("spin_dps"))
	_spinner = Node3D.new()
	add_child(_spinner)
	if block.get("shape") is String and _add_shape(str(block.shape), str(block.get("sequences", "")) == "cyclic"):
		return
	var along := str(block.get("face", "billboard")) == "velocity"
	if along and block.get("sprite") is String and _add_streak(block, color):
		return
	if block.get("sprite") is String and _add_sprite(str(block.sprite), size, block.get("color")):
		return
	if along:
		_spinner.add_child(_make_tracer(color, size, FxMaterials.glow_texture(), maxf(MIN_TRACER_WIDTH, size * TRACER_WIDTH_SHARE)))
	else:
		_spinner.add_child(FxMaterials.build_glow_quad(color, size))


static func _make_spin(v: Variant) -> Vector3:
	if v is Array and v.size() >= 3:
		return Vector3(float(v[0]), float(v[1]), float(v[2])) * deg_to_rad(1.0)
	return Vector3.FORWARD * deg_to_rad(float(v)) if (v is float or v is int) else Vector3.ZERO


## `play_cycles`: loop the shape's cyclic sequences in flight (fx projectile "sequences": "cyclic").
func _add_shape(id: String, play_cycles: bool) -> bool:
	var s := Assets.shape(id)
	if s.get("lods", [{}])[0].get("pieces", []).is_empty():
		return false
	var inst := ShapeInstance.new()
	_spinner.add_child(inst)
	# original projectile shapes face their +y (forward); ShapeInstance maps that onto our -z
	inst.build(s, 0)
	_shape = inst
	if play_cycles:
		_cycles = _make_cycles(s)
	return true


## Indices of the shape's cyclic Darkstar/Torque sequences, looped for the whole flight: the Tribes 2 grenade and
## mortar shells carry a cyclic "ambient" sequence on their spin / wobble nodes (DTS v18, Cyclic flag).
static func _make_cycles(s: Dictionary) -> Array[int]:
	var out: Array[int] = []
	var seqs: Array = s.get("ds_sequences", [])
	for i in seqs.size():
		var cyclic = seqs[i].get("cyclic")
		if cyclic and float(seqs[i].get("duration", 0.0)) > 0.0 and not seqs[i].get("tracks", []).is_empty():
			out.append(i)
	return out


func _apply_cycles(delta: float) -> void:
	_cycle_t += delta
	for i in _cycles:
		ShapeCycles.pose(_shape, i, _cycle_t / float(_shape.shape.ds_sequences[i].duration))


func _add_sprite(ref: String, size: float, color: Variant) -> bool:
	var layer := {"size": size}
	if color is Array:
		layer["color"] = color
	var s := Effects.fx.build_looping_sprite(ref, _pack, layer)
	if s == null:
		return false
	s.phase_lifetime = _lifetime
	_spinner.add_child(s)
	return true


## A streak `length` long along the flight axis: two crossed strips so it reads from any side.
static func _make_tracer(color: Color, length: float, texture: Texture2D, width: float) -> Node3D:
	var root := Node3D.new()
	for roll in [0.0, PI * 0.5]:
		var mi := MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(width, length)
		mi.mesh = q
		mi.material_override = FxMaterials.make_unshaded(color, texture, true)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# quad y along -z (flight), rolled about it
		mi.basis = Basis(Vector3.FORWARD, roll) * Basis(Vector3.RIGHT, -PI * 0.5)
		mi.position = Vector3(0, 0, length * 0.5)
		root.add_child(mi)
	return root


## Torque tracer / energy bolt: the sprite stretched `length` along the flight path, `size` wide; seen nearly
## end-on (view within acos(cross.view_cos) of the axis) the cross bitmap is drawn instead.
func _add_streak(block: Dictionary, color: Color) -> bool:
	var sprite := FxLibrary.sprite(str(block.sprite), _pack)
	if sprite.is_empty() or float(block.get("length", 0.0)) <= 0.0:
		return false
	_streak = _make_tracer(color, float(block.length), sprite.textures[0], float(block.get("size", DEFAULT_SIZE)))
	_spinner.add_child(_streak)
	var cross = block.get("cross")
	if cross is Dictionary and cross.get("sprite") is String:
		_cross = Effects.fx.build_looping_sprite(str(cross.sprite), _pack, {"size": float(cross.get("size", 0.5)), "color": block.get("color")})
		if _cross:
			_cross_view_cos = float(cross.get("view_cos", 0.99))
			_cross.visible = false
			_spinner.add_child(_cross)
	return true


## Shows the cross bitmap instead of the streak while the camera looks along the flight axis.
func _apply_cross_view() -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var view := (global_position - cam.global_position).normalized()
	var end_on := absf(view.dot(-global_basis.z)) > _cross_view_cos
	_cross.visible = end_on
	_streak.visible = not end_on


func _build_light(block: Variant) -> void:
	if not (block is Dictionary):
		return
	var l := DynamicLights.make_transient({"color": FxLibrary.make_color(block.get("color"), Color.WHITE),
		"range": float(block.get("range", 6.0)), "energy": LIGHT_ENERGY})
	if l != null:
		add_child(l)


func _process(delta: float) -> void:
	if not _cycles.is_empty():
		_apply_cycles(delta)
	if _cross:
		_apply_cross_view()
	if _spin != Vector3.ZERO and _spinner:
		if _spin.normalized().is_equal_approx(Vector3.FORWARD):
			_spinner.rotate_object_local(Vector3.FORWARD, _spin.length() * delta)
		else:
			_spinner.global_rotate(_spin.normalized(), _spin.length() * delta)
	if _trail.is_empty():
		return
	_trail_t -= delta
	if _trail_t <= 0.0:
		_trail_t = maxf(MIN_TRAIL_INTERVAL, float(_trail.get("interval", DEFAULT_TRAIL_INTERVAL)))
		_emit_trail()


func _emit_trail() -> void:
	var parent := get_parent().get_parent() if get_parent() else null
	if parent == null:
		return
	if _trail.get("effect") is String and _trail.effect != "":
		Effects.fx.play_effect(parent, str(_trail.effect), _pack, global_position, global_basis.z)
		return
	Effects.fx.play_puff(parent, global_position, FxLibrary.make_color(_trail.get("color"), Color(0.75, 0.75, 0.72, 0.6)),
		float(_trail.get("size", 0.6)), float(_trail.get("lifetime", 0.8)))
