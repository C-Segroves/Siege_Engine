extends Node3D
## Weapon visual effects of every installed pack (docs/formats/weapon_fx.md, engine/fx):
##   1. every weapon resolves its own fx data (no generated fallback look);
##   2. firing weapons have a projectile look (beam block for beams), every referenced sprite has frames,
##      every shape has geometry, and the impact lists name known effects;
##   3. impacts pick among all the original variants;
##   4. every effect, beam, muzzle and projectile look spawns without script errors (headless);
##   5. the live caps hold when far more effects are requested than the budget allows;
##   6. Tribes 2 model projectiles (grenade, mortar, missile...) fly their DTS models, not glows, and the
##      blaster has its hand-weapon model;
##   7. Earthsiege 1/2 effect bitmaps and palette-index colours follow the world palette, cached per world.
## godot --headless --audio-driver Dummy --path game res://tests/weapon_fx_check.tscn [-- --pack=es1]

const PASSIVE_KINDS := ["ecm", "other"]
const BEAM_KINDS := ["beam", "emp", "flame"]
const PICKS_PER_SURFACE := 64
const SPAWN_FRAMES := 3
const FLOOD_EFFECTS := 2000
## Tribes 2 weapons whose projectile is a DTS model (projectileShapeName of Linear / Grenade / Seeker / Bomb data).
const T2_MODEL_WEAPONS := ["tribes2:GRENADE_LAUNCHER", "tribes2:MORTAR", "tribes2:MISSILE_LAUNCHER", "tribes2:SPINFUSOR",
	"tribes2:TANK_MORTAR", "tribes2:BOMBER_BOMB"]
const T2_BLASTER := "tribes2:BLASTER"
## World palettes compared for the per-world effect colours (both exist in ES1 and ES2).
const WORLD_A := "WORLD0"
const WORLD_B := "WORLD2"

var _failures := 0
var _errors := ErrorCounter.new()
var _checked := 0
var _only_pack := ""


## Counts engine and script errors raised while effects spawn (any is a failure).
class ErrorCounter extends Logger:
	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_WARNING:
			count += 1


func _ready() -> void:
	OS.add_logger(_errors)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			_only_pack = a.substr(7)
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(0, 5, 30)
	for pack in Assets.installed_packs():
		if _only_pack == "" or pack == _only_pack:
			await _check_pack(pack)
	await _check_caps()
	if _only_pack in ["", "tribes2"]:
		_check_tribes2_models()
	for pack in ["es1", "es2"]:
		if pack in Assets.installed_packs() and _only_pack in ["", pack]:
			_check_world_palettes(pack)
	_expect(_errors.count == 0, "no engine / script errors while spawning (%d)" % _errors.count)
	OS.remove_logger(_errors)
	print("weapon_fx_check: %d weapons, %s (%d failures)" % [_checked, "OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _check_pack(pack: String) -> void:
	var lib := FxLibrary.library(pack)
	print("pack %s: %d sprites, %d effects" % [pack, lib.get("sprites", {}).size(), lib.get("effects", {}).size()])
	_check_library(pack, lib)
	for id in Packs.weapons:
		var def: Dictionary = Packs.weapons[id]
		if FxLibrary.weapon_pack(def) == pack:
			_checked += 1
			_check_weapon(def)
			await _spawn_weapon(def)
	await _spawn_library(pack, lib)


func _check_library(pack: String, lib: Dictionary) -> void:
	for name in lib.get("sprites", {}):
		_expect(not FxLibrary.sprite(name, pack).is_empty(), "%s sprite %s loads its frames" % [pack, name])
	for name in lib.get("effects", {}):
		for layer in lib.effects[name].get("layers", []):
			_check_layer(pack, name, layer)


func _check_layer(pack: String, effect: String, layer: Dictionary) -> void:
	if layer.get("sprite") is String:
		_expect(FxLibrary.has_sprite(layer.sprite, pack), "%s effect %s: sprite %s exists" % [pack, effect, layer.sprite])
	var p = layer.get("particles")
	if p is Dictionary and p.get("sprite") is String:
		_expect(FxLibrary.has_sprite(p.sprite, pack), "%s effect %s: particle sprite %s exists" % [pack, effect, p.sprite])
	if layer.get("shape") is String:
		_expect(_shape_has_geometry(layer.shape), "%s effect %s: shape %s has geometry" % [pack, effect, layer.shape])


func _check_weapon(def: Dictionary) -> void:
	var id := str(def.id)
	var fx := FxLibrary.weapon_fx(def)
	_expect(not FxLibrary.is_fallback(fx), "%s has fx data" % id)
	if FxLibrary.is_fallback(fx) or str(def.kind) in PASSIVE_KINDS:
		return
	var pack := FxLibrary.weapon_pack(def)
	if str(def.kind) in BEAM_KINDS and not (def.get("projectile") is Dictionary):
		_expect(fx.get("beam") is Dictionary, "%s (beam) has a beam look" % id)
		_check_beam_texture(id, fx.get("beam"), pack)
	else:
		_expect(fx.get("projectile") is Dictionary, "%s has a projectile look" % id)
		_check_projectile(id, fx.get("projectile"), pack)
	for ref in [fx.get("muzzle"), (fx.trail if fx.get("trail") is Dictionary else {}).get("effect")]:
		if ref is String and ref != "":
			_expect(not FxLibrary.effect(ref, pack).is_empty(), "%s: effect %s exists" % [id, ref])
	_check_impacts(id, fx, pack)


func _check_projectile(id: String, block: Variant, pack: String) -> void:
	if not (block is Dictionary):
		return
	if block.get("sprite") is String:
		_expect(not FxLibrary.sprite(block.sprite, pack).is_empty(), "%s: projectile sprite %s has frames" % [id, block.sprite])
	if block.get("shape") is String:
		_expect(_shape_has_geometry(block.shape), "%s: projectile shape %s has geometry" % [id, block.shape])


func _check_beam_texture(id: String, block: Variant, pack: String) -> void:
	if block is Dictionary and block.get("texture") is String and block.texture != "":
		var tex := FxLibrary.texture(block.texture, pack, str(block.get("texture_format", "rgba")), str(block.get("palette", "")))
		_expect(tex != null, "%s: beam texture %s loads" % [id, block.texture])


func _check_impacts(id: String, fx: Dictionary, pack: String) -> void:
	for surface in ["miss", "shield", "armor"]:
		var options := FxLibrary.impact_effects(fx, surface)
		_expect(not options.is_empty(), "%s: %s impact effects" % [id, surface])
		var distinct := {}
		for ref in options:
			distinct[ref] = true
			_expect(not FxLibrary.effect(str(ref), pack).is_empty(), "%s: impact effect %s exists" % [id, ref])
		_expect(_picked_variants(options) == distinct.size(), "%s: %s impacts pick every variant" % [id, surface])


## How many distinct variants random picks reach (the same choice FxPlayer.play_impact makes).
static func _picked_variants(options: Array) -> int:
	var seen := {}
	for i in PICKS_PER_SURFACE:
		seen[options[randi() % options.size()]] = true
	return seen.size()


static func _shape_has_geometry(id: String) -> bool:
	for lod in Assets.shape(id).get("lods", []):
		if not lod.get("pieces", []).is_empty():
			return true
	return false


# ------------------------------------------------------------------ spawning

## Fires the weapon's look (muzzle, beam, impacts, a flying projectile for a few frames); any SCRIPT ERROR
## raised meanwhile fails the weapon by name.
func _spawn_weapon(def: Dictionary) -> void:
	var errors_before := _errors.count
	var from := Vector3(-10, 2, 0)
	var to := Vector3(10, 2, 0)
	Effects.fx.play_muzzle(self, def, from, Vector3.RIGHT)
	Effects.fx.play_beam(self, def, from, to)
	for surface in ["miss", "shield", "armor"]:
		Effects.fx.play_impact(self, def, surface, to, Vector3.LEFT)
	if def.get("projectile") is Dictionary or not (str(def.kind) in BEAM_KINDS):
		var p := Weapon.make_projectile(def, null, from, Vector3.RIGHT, null, true)
		add_child(p)
		p.global_position = from
	for i in SPAWN_FRAMES:
		await get_tree().process_frame
	_expect(_errors.count == errors_before, "%s: no script errors while its projectile / beam plays (%d)"
		% [def.id, _errors.count - errors_before])
	_clear_scene()


func _spawn_library(pack: String, lib: Dictionary) -> void:
	for name in lib.get("effects", {}):
		Effects.fx.play_effect(self, name, pack, Vector3.ZERO)
	for i in SPAWN_FRAMES:
		await get_tree().process_frame
	_clear_scene()


func _clear_scene() -> void:
	for c in get_children():
		if not (c is Camera3D):
			c.queue_free()


func _check_caps() -> void:
	var pack := ""
	var ref := ""
	for p in Assets.installed_packs():
		var effects: Dictionary = FxLibrary.library(p).get("effects", {})
		if not effects.is_empty():
			pack = p
			ref = effects.keys()[0]
			break
	for i in FLOOD_EFFECTS:
		Effects.fx.play_effect(self, ref if ref != "" else FxPlayer.BUILTIN_SPARK, pack, Vector3(i % 40, 0, 0))
		Effects.fx.play_puff(self, Vector3.ZERO, Color.WHITE, 1.0, 1.0)
	await get_tree().process_frame
	var live := Effects.fx.live_counts()
	print("flood: ", live)
	_expect(live.sprites <= FxPlayer.MAX_LIVE_SPRITES, "live sprites capped (%d)" % live.sprites)
	_expect(live.bursts <= FxPlayer.MAX_LIVE_BURSTS, "particle bursts capped (%d)" % live.bursts)
	_expect(live.lights <= FxPlayer.MAX_LIVE_LIGHTS, "lights capped (%d)" % live.lights)
	_clear_scene()
	await get_tree().process_frame


# ------------------------------------------------------------------ data rules

func _check_tribes2_models() -> void:
	if not ("tribes2" in Assets.installed_packs()):
		return
	for id in T2_MODEL_WEAPONS:
		if not Packs.weapons.has(id):
			continue
		var block = FxLibrary.weapon_fx(Packs.weapons[id]).get("projectile")
		var shape: Variant = block.get("shape") if block is Dictionary else null
		_expect(shape is String and _shape_has_geometry(shape), "%s flies its DTS model (%s), not a glow" % [id, shape])
	if Packs.weapons.has(T2_BLASTER):
		var model = Packs.weapons[T2_BLASTER].get("model", {})
		var mounts: Array = model.get("mount_shapes", []) if model is Dictionary else []
		_expect(not mounts.is_empty() and _shape_has_geometry(str(mounts[0])), "%s has its hand-weapon model" % T2_BLASTER)


## A per-world sprite and a palette-index colour of `pack` change with the world palette, and the
## sprite cache keeps one entry per (pack, world).
func _check_world_palettes(pack: String) -> void:
	var name := _per_world_sprite(pack)
	_expect(name != "", "%s has per-world effect sprites" % pack)
	if name == "":
		return
	FxLibrary.set_world_palette("%s:%s" % [pack, WORLD_A])
	var a := FxLibrary.sprite(name, pack)
	_expect(a == FxLibrary.sprite(name, pack), "%s sprite %s cached per world" % [pack, name])
	var index := _differing_index(pack, name)
	FxLibrary.set_world_palette("%s:%s" % [pack, WORLD_B])
	var b := FxLibrary.sprite(name, pack)
	var block := {"palette_index": index, "palette": WORLD_A}
	var color_b := FxLibrary.make_block_color(block, pack)
	FxLibrary.set_world_palette("%s:%s" % [pack, WORLD_A])
	var color_a := FxLibrary.make_block_color(block, pack)
	FxLibrary.clear_world_palettes()
	_expect(a.textures[0].get_image().get_data() != b.textures[0].get_image().get_data(),
		"%s sprite %s is drawn in the world palette" % [pack, name])
	_expect(not color_a.is_equal_approx(color_b), "%s palette index %d follows the world palette" % [pack, index])


## A per-world sprite of `pack` that uses a colour the two test worlds draw differently ("" none).
static func _per_world_sprite(pack: String) -> String:
	var sprites: Dictionary = FxLibrary.library(pack).get("sprites", {})
	for name in sprites:
		if bool(sprites[name].get("palette_per_world", false)) and _differing_index(pack, name) >= 0:
			return name
	return ""


## A palette index used by sprite `name`'s first frame whose colour differs between the two worlds (-1 none).
static func _differing_index(pack: String, name: String) -> int:
	var d: Dictionary = FxLibrary.library(pack).sprites[name]
	var img := Assets.load_image(str(d.frames[0]), pack)
	if img == null:
		return -1
	img.convert(Image.FORMAT_L8)
	var pal_a: Array = Assets.palette("%s:%s" % [pack, WORLD_A])
	var pal_b: Array = Assets.palette("%s:%s" % [pack, WORLD_B])
	for v in img.get_data():
		if v != 0 and pal_a[v] != pal_b[v]:
			return v
	return -1


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		print("FAIL: ", what)
