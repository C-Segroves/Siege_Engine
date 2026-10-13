class_name FxPlayer
extends Node
## Plays data-driven weapon effects (docs/formats/weapon_fx.md): effect library entries (explosions,
## impact sparks, shield flashes, smoke puffs, muzzle flashes), beams, and impacts chosen at random among
## the original variants for the surface hit. Owned by the Effects autoload (Effects.fx).
##
## Budget for 24-player battles: sprites come from a pool; live sprites, particle bursts and dynamic lights
## are capped (oldest effects are not cut short - new ones are skipped while a cap is reached, lights first).

const MAX_LIVE_SPRITES := 320
const MAX_LIVE_BURSTS := 48
const MAX_LIVE_LIGHTS := 16
const MAX_POOLED_SPRITES := 128
const LIGHT_ENERGY := 2.0
const IMPACT_VOLUME_DB := -2.0
## Built-in looks for weapons without data (FxLibrary.make_fallback_fx).
const BUILTIN_SPARK := "@spark"
const BUILTIN_EXPLOSION := "@explosion"
const SPARK_SIZE := 0.8
const EXPLOSION_SIZE := 3.0
const MAX_LIGHTNING_SEGMENTS := 64
## Trail puffs grow to this multiple of their size while fading.
const PUFF_GROW := 2.5

## Deaths and grenade bursts that fell back to the generic explosion (an import without their data).
var generic_explosions := 0
## Library effects played so far (diagnostics and tests).
var effects_played := 0
var _pool: Array[FxSprite] = []
var _live_sprites := 0
var _live_bursts := 0
var _live_lights := 0


## Plays effect `ref` (pack-local or "<pack>:<name>") at `pos`; `forward` orients oriented layers
## (the impact normal or the shot direction).
func play_effect(parent: Node, ref: String, pack: String, pos: Vector3, forward := Vector3.UP) -> void:
	if parent == null or not parent.is_inside_tree():
		return
	if ref.begins_with("@"):
		_play_builtin(parent, ref, pos)
		return
	var e := FxLibrary.effect(ref, pack)
	if e.is_empty():
		push_warning("fx: unknown effect %s (pack %s)" % [ref, pack])
		return
	effects_played += 1
	for layer in e.get("layers", []):
		if layer is Dictionary:
			_play_layer(parent, layer, str(e.pack), pos, forward)
	if e.get("light") is Dictionary:
		_play_light(parent, e.light, pos)
	if e.get("sound") is String and e.sound != "":
		Sfx.play_at(_qualified_sound(str(e.sound), str(e.pack)), pos, IMPACT_VOLUME_DB)


## A random one of the weapon's impact effects for `surface` ("miss" / "shield" / "armor" / "water").
## Returns true when the effect carries its own sound (callers then skip the weapon's generic hit sound).
func play_impact(parent: Node, def: Dictionary, surface: String, pos: Vector3, normal := Vector3.UP) -> bool:
	var fx := FxLibrary.weapon_fx(def)
	var options := FxLibrary.impact_effects(fx, surface)
	if options.is_empty():
		return false
	var ref := str(options[randi() % options.size()])
	var pack := FxLibrary.weapon_pack(def)
	play_effect(parent, ref, pack, pos, normal)
	var e := FxLibrary.effect(ref, pack)
	return e.get("sound") is String and e.sound != ""


## The weapon's beam from `from` to `to` (its fx "beam" block; nothing for weapons without one).
func play_beam(parent: Node, def: Dictionary, from: Vector3, to: Vector3) -> void:
	var block = FxLibrary.weapon_fx(def).get("beam")
	if not (block is Dictionary) or parent == null:
		return
	var pack := FxLibrary.weapon_pack(def)
	var jag: Dictionary = block.jagged if block.get("jagged") is Dictionary else {}
	if str(block.get("style", "")) == "lightning" or not jag.is_empty():
		var segment := float(jag.get("segment", block.get("segment_length", 4.0)))
		var points := make_lightning_points(from, to, segment, float(jag.get("jitter", block.get("jitter", 0.5))))
		for i in points.size() - 1:
			parent.add_child(FxBeam.create(block, pack, points[i], points[i + 1]))
		return
	parent.add_child(FxBeam.create(block, pack, from, to))


## A zig-zag through a node every `segment` metres, inner nodes offset up to `jitter` per axis
## (ES1 ELF ribbon: a node per 0x400 units, rand & 0x7f per axis).
static func make_lightning_points(from: Vector3, to: Vector3, segment: float, jitter: float) -> Array:
	var count := clampi(int(from.distance_to(to) / maxf(segment, 0.1)), 1, MAX_LIGHTNING_SEGMENTS)
	var points := [from]
	for i in range(1, count):
		var j := Vector3(randf(), randf(), randf()) * jitter
		points.append(from.lerp(to, float(i) / count) + j)
	points.append(to)
	return points


## The weapon's muzzle flash at `pos` facing `dir`.
func play_muzzle(parent: Node, def: Dictionary, pos: Vector3, dir: Vector3) -> void:
	var ref = FxLibrary.weapon_fx(def).get("muzzle")
	if ref is String and ref != "":
		play_effect(parent, ref, FxLibrary.weapon_pack(def), pos, dir)


## A looping sprite for a projectile (not pooled: it lives as long as the projectile).
func build_looping_sprite(ref: String, pack: String, layer: Dictionary) -> FxSprite:
	var sprite := FxLibrary.sprite(ref, pack)
	if sprite.is_empty():
		return null
	var s := FxSprite.new()
	s.setup(sprite, layer, true)
	return s


## A plain soft puff (trails without an effect of their own): grows and fades over `lifetime`.
func play_puff(parent: Node, pos: Vector3, color: Color, size: float, lifetime: float) -> void:
	if _live_sprites >= MAX_LIVE_SPRITES or parent == null:
		return
	_play_flash(parent, {"flash": {"color": [color.r, color.g, color.b, color.a], "size": size, "blend": "alpha"},
		"duration": lifetime, "grow": PUFF_GROW}, pos)


## Last resort for a death or burst the pack's data does not describe (DeathFx, ThrownItem): the generic explosion.
func play_generic_explosion(parent: Node, pos: Vector3, size: float) -> void:
	generic_explosions += 1
	push_warning("fx: no effect data for this death / burst, generic explosion at %s" % pos)
	Effects.explosion(parent, pos, size)


func live_counts() -> Dictionary:
	return {"sprites": _live_sprites, "bursts": _live_bursts, "lights": _live_lights, "pooled": _pool.size()}


# ------------------------------------------------------------------ layers

func _play_layer(parent: Node, layer: Dictionary, pack: String, pos: Vector3, forward: Vector3) -> void:
	var delay := float(layer.get("delay", 0.0))
	if delay > 0.0:
		get_tree().create_timer(delay).timeout.connect(_play_layer_now.bind(parent, layer, pack, pos, forward))
	else:
		_play_layer_now(parent, layer, pack, pos, forward)


func _play_layer_now(parent: Node, layer: Dictionary, pack: String, pos: Vector3, forward: Vector3) -> void:
	if not is_instance_valid(parent) or not parent.is_inside_tree():
		return
	var at := pos + _make_offset(layer, forward) + _make_random_offset(float(layer.get("offset_random", 0.0)))
	if layer.get("sprite") is String:
		_play_sprite(parent, layer, pack, at, forward)
	elif layer.get("particles") is Dictionary:
		_play_burst(parent, layer, pack, at, forward)
	elif layer.get("ring") is Dictionary:
		_play_ring(parent, layer, pack, at, forward)
	elif layer.get("flash") is Dictionary:
		_play_flash(parent, layer, at)
	elif layer.get("shape") is String:
		_play_shape(parent, layer, at, forward)


## Layer offset in the effect frame (y along `forward`).
static func _make_offset(layer: Dictionary, forward: Vector3) -> Vector3:
	var o = layer.get("offset")
	if not (o is Array) or o.size() < 3:
		return Vector3.ZERO
	return Vector3(float(o[0]), float(o[1]), float(o[2])) if forward == Vector3.UP else forward.normalized() * float(o[1])


## Torque explosion offset: a random direction, this far.
static func _make_random_offset(distance: float) -> Vector3:
	if distance <= 0.0:
		return Vector3.ZERO
	return Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)).normalized() * distance


## `normal`: the hit surface's normal (or the shot direction) that surface-facing layers lie across.
func _play_sprite(parent: Node, layer: Dictionary, pack: String, at: Vector3, normal: Vector3) -> void:
	if _live_sprites >= MAX_LIVE_SPRITES:
		return
	var sprite := FxLibrary.sprite(str(layer.sprite), pack)
	if sprite.is_empty():
		push_warning("fx: unknown sprite %s (pack %s)" % [layer.sprite, pack])
		return
	var s := _take_sprite()
	parent.add_child(s)
	s.global_position = at
	s.setup(sprite, layer, false, normal)
	_live_sprites += 1


func _take_sprite() -> FxSprite:
	if not _pool.is_empty():
		return _pool.pop_back()
	var s := FxSprite.new()
	s.finished.connect(_on_sprite_finished)
	s.tree_exiting.connect(_on_sprite_exiting.bind(s))
	return s


func _on_sprite_finished(s: FxSprite) -> void:
	s.get_parent().remove_child(s)
	if _pool.size() < MAX_POOLED_SPRITES:
		_pool.append(s)
	else:
		s.queue_free()


## Every way a live sprite leaves the tree (finished, or its battle freed) ends its slot.
func _on_sprite_exiting(_s: FxSprite) -> void:
	_live_sprites = maxi(0, _live_sprites - 1)


func _play_burst(parent: Node, layer: Dictionary, pack: String, at: Vector3, forward: Vector3) -> void:
	if _live_bursts >= MAX_LIVE_BURSTS:
		return
	var block: Dictionary = layer.particles
	var sprite := FxLibrary.sprite(str(block.sprite), pack) if block.get("sprite") is String else {}
	var p := FxParticles.build(block, sprite, 1.0)
	parent.add_child(p)
	p.global_position = at
	if forward.length() > 0.001 and absf(forward.normalized().dot(Vector3.UP)) < 0.999:
		p.direction = forward.normalized()
	_live_bursts += 1
	p.tree_exiting.connect(func() -> void: _live_bursts = maxi(0, _live_bursts - 1))


func _play_flash(parent: Node, layer: Dictionary, at: Vector3) -> void:
	if _live_sprites >= MAX_LIVE_SPRITES:
		return
	var block: Dictionary = layer.flash
	var color := FxLibrary.make_color(block.get("color"), Color(1, 0.7, 0.3))
	var q := FxMaterials.build_glow_quad(color, float(block.get("size", 2.0)), str(block.get("blend", "additive")) == "additive")
	parent.add_child(q)
	q.global_position = at
	_live_sprites += 1
	q.tree_exiting.connect(func() -> void: _live_sprites = maxi(0, _live_sprites - 1))
	_fade_out(q, q.material_override as StandardMaterial3D, float(layer.get("duration", 0.2)), float(layer.get("grow", 1.0)))


## Torque shockwave / splash ring (counts against the sprite cap).
func _play_ring(parent: Node, layer: Dictionary, pack: String, at: Vector3, normal: Vector3) -> void:
	if _live_sprites >= MAX_LIVE_SPRITES:
		return
	var r := FxRing.create(layer.ring, pack, normal)
	parent.add_child(r)
	r.global_position = at
	_live_sprites += 1
	r.tree_exiting.connect(func() -> void: _live_sprites = maxi(0, _live_sprites - 1))


func _play_shape(parent: Node, layer: Dictionary, at: Vector3, forward: Vector3) -> void:
	var inst := ShapeInstance.new()
	parent.add_child(inst)
	inst.build(Assets.shape(str(layer.shape)), 0)
	inst.global_position = at
	if forward.length() > 0.001 and absf(forward.normalized().dot(Vector3.UP)) < 0.999:
		inst.look_at(at + forward, Vector3.UP)
	var duration := float(layer.get("duration", 0.5))
	var tw := inst.create_tween().set_parallel(true)
	var grow := float(layer.get("grow", 1.0))
	if grow != 1.0:
		tw.tween_property(inst, "scale", Vector3.ONE * grow, duration)
	var spin = layer.get("spin_dps")
	if spin is Array and spin.size() >= 3:
		var turn := Vector3(float(spin[0]), float(spin[1]), float(spin[2])) * deg_to_rad(1.0) * duration
		tw.tween_property(inst, "rotation", inst.rotation + turn, duration)
	if layer.get("cells_per_frame", false):
		tw.tween_method(_apply_cell_frame.bind(inst), 0.0, 1.0, duration)
	tw.chain().tween_callback(inst.queue_free)


## Steps every cell of an effect shape through its states over the effect (ES1 FLAT ground ring, 0x5c06).
static func _apply_cell_frame(t: float, inst: ShapeInstance) -> void:
	if not is_instance_valid(inst):
		return
	var cells: Array = inst.shape.get("lods", [{}])[0].get("cells", [])
	for ci in mini(cells.size(), inst.cell_count()):
		var states := maxi(1, int(cells[ci].get("states", 1)))
		inst.set_cell_state(ci, mini(states - 1, int(t * states)))


func _play_light(parent: Node, block: Dictionary, at: Vector3) -> void:
	if _live_lights >= MAX_LIVE_LIGHTS:
		return
	var l := DynamicLights.make_transient({"color": FxLibrary.make_color(block.get("color"), Color(1, 0.7, 0.3)),
		"range": float(block.get("range", 10.0)), "energy": LIGHT_ENERGY})
	if l == null:
		return
	PaletteLights.adopt(l, block)
	parent.add_child(l)
	l.global_position = at
	_live_lights += 1
	l.tree_exiting.connect(func() -> void: _live_lights = maxi(0, _live_lights - 1))
	var tw := l.create_tween()
	var curve = block.get("energy")
	if curve is Array and not curve.is_empty():
		_tween_light_curve(l, tw, block, curve)
	else:
		tw.tween_property(l, "light_energy", 0.0, maxf(0.05, float(block.get("duration", 0.3))))
	tw.tween_callback(l.queue_free)


## ES1/ES2 3Space lights: the intensity of each explosion frame (ES1 word 6 + frame 0x5e0c, ES2 record +8
## 0x4081d7); with `range_follows_energy` the reach scales with it, as the original radius = 198.4 units x I.
static func _tween_light_curve(l: OmniLight3D, tw: Tween, block: Dictionary, curve: Array) -> void:
	var step := maxf(0.01, float(block.get("frame_s", 0.08)))
	var peak := 0.0
	for e in curve:
		peak = maxf(peak, float(e))
	var full_range := l.omni_range
	var scale_range := bool(block.get("range_follows_energy", false)) and peak > 0.0
	l.light_energy = LIGHT_ENERGY * float(curve[0])
	if scale_range:
		l.omni_range = full_range * float(curve[0]) / peak
	for e in curve.slice(1):
		tw.tween_property(l, "light_energy", LIGHT_ENERGY * float(e), step)
		if scale_range:
			tw.parallel().tween_property(l, "omni_range", full_range * float(e) / peak, step)
	tw.tween_property(l, "light_energy", 0.0, step)


func _fade_out(n: Node3D, mat: StandardMaterial3D, time: float, grow: float) -> void:
	var tw := n.create_tween().set_parallel(true)
	tw.tween_property(mat, "albedo_color:a", 0.0, maxf(0.02, time))
	if grow != 1.0:
		tw.tween_property(n, "scale", Vector3.ONE * grow, time)
	tw.chain().tween_callback(n.queue_free)


func _play_builtin(parent: Node, ref: String, pos: Vector3) -> void:
	if ref == BUILTIN_EXPLOSION:
		Effects.explosion(parent, pos, EXPLOSION_SIZE)
	else:
		Effects.spark(parent, pos, SPARK_SIZE)


## Sounds of an effect are stems of its own pack (Sfx resolves "<pack>:<stem>").
static func _qualified_sound(stem: String, pack: String) -> String:
	return stem if stem.contains(":") else "%s:%s" % [pack, stem]


func _exit_tree() -> void:
	for s in _pool:
		s.free()
	_pool.clear()
