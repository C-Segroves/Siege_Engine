class_name TribesBaseObject
extends Structure
## One piece of a Tribes base (docs/TRIBES_BASE_EQUIPMENT.md): a generator or solar panel, a pulse sensor, an
## inventory / ammo / command / vehicle station or pad, or (TribesTurret) a turret. Its values come from the
## pack's gameplay/base_equipment.json (tools/export_tribes_base.py: the game's own datablocks):
##   damage   destroyed at its hit points (maxDamage / destroyedLevel), Disabled from `disabled_damage` on
##            (Tribes 1: maxDamage x the engine's disabled ratio; Tribes 2: disabledLevel); a disabled or
##            destroyed object does nothing, a disabled generator powers nothing;
##   energy   a pool recharging while powered; with a shield it absorbs hits first (Tribes 1
##            StaticShape::shieldDamage shieldStrength, Tribes 2 isShielded energyPerDamagePoint);
##   scales   Tribes 2 damage profiles scale each hit by its damage type (DamageTypes.current);
##   repair   the repair pack brings it back from disabled or destroyed (apply_repair, host); a destroyed object
##            stays standing as a ruin (it is never removed), so a repairer can always bring it back;
##   capture  repair work by a soldier who is not allied to its team takes it for him for the RepairRules
##            capture.seconds (BaseCapture, Structure.apply_capture, host): its team becomes his, so a turret fires at
##            his enemies and a generator powers his side; it returns to its owner when the time is up, when it is
##            destroyed or when the owner repairs it back.
## Power is given by TribesBase (TribesPowerGrid). Host simulates; clients follow integrity and the repair RPC.

const KIND_GENERATOR := "generator"
const KIND_TURRET := "turret"
const KIND_SENSOR := "sensor"
## Station kinds the soldier uses (TribesStations) and every kind that needs base power to work.
const STATION_KINDS := ["inventory", "ammo", "command", "vehicle", "vehicle_pad"]
const UNPOWERED_KINDS := [KIND_GENERATOR]

var spec: Dictionary = {}
var kind := ""
## Lower-case datablock name (the mission's), the key game modes match objectives by.
var datablock := ""
var pack := ""
## Index into the map's power_groups (-1: in no group).
var power_group := -1
var powered := false
## Powers itself (a deployed object: Tribes 2 setSelfPowered, Tribes 1 deployables ignore base power).
var self_powered := false
## The shield's energy (DamageTarget) and its pool size.
var energy: float:
	get: return damage.shield_energy
	set(value): damage.shield_energy = value
var energy_max := 0.0
var energy_recharge := 0.0
var disabled_damage: float:
	get: return damage.profile.disabled_damage
var invincible: bool:
	get: return damage.profile.invincible
## Palette the shape was built in (a mounted part, the Tribes 2 turret barrel, uses it too).
var palette := ""
## Its glowing parts and cast light (null when the shape has none); lit while it works.
var lights: TribesBaseLights
var _was_enabled := true


## Builds the object for map station `record` (map.json entry with its MapBuilder transform `xf`) from `p_spec`.
static func make(parent: Node3D, record: Dictionary, xf: Transform3D, p_spec: Dictionary, pal: String) -> TribesBaseObject:
	var o: TribesBaseObject = TribesTurret.new() if p_spec.get("turret") is Dictionary else TribesBaseObject.new()
	o.build_object(parent, record, xf, p_spec, pal)
	return o


## Adds the object under `parent` (net name before add_child: the same path on every peer) and applies its spec.
func build_object(parent: Node3D, record: Dictionary, xf: Transform3D, p_spec: Dictionary, pal: String) -> void:
	transform = xf
	shape_id = str(record.get("shape", ""))
	team = int(record.get("team", -1))
	datablock = str(record.get("datablock", "")).to_lower()
	power_group = int(record.get("power_group", -1))
	pack = Assets.split_id(shape_id)[0]
	name = make_net_name(shape_id, xf.origin)
	parent.add_child(self)
	add_to_groups()
	add_to_group(Projectile.SPLASH_TARGETS)
	shape = ShapeInstance.new()
	add_child(shape)
	shape.build(Assets.shape(shape_id), 0, pal)
	palette = pal
	build_collision()
	lights = TribesBaseLights.make(self, shape)
	apply_spec(p_spec)


## Hit points, disabled damage, energy, shield and damage scales of `p_spec` (base_equipment.json block).
func apply_spec(p_spec: Dictionary) -> void:
	spec = p_spec
	kind = str(p_spec.get("kind", ""))
	display_name = str(p_spec.get("display_name", datablock))
	var dmg: Dictionary = p_spec.get("damage", {})
	max_hp = float(dmg.get("hp", max_hp))
	hp = max_hp
	damage.profile = TribesDamageProfile.make_object(p_spec, pack, kind)
	damage.shield_online = has_power
	var en: Dictionary = p_spec.get("energy", {})
	energy_max = float(en.get("max", 0.0))
	energy_recharge = float(en.get("recharge_per_s", 0.0))
	energy = energy_max
	repairs_ruins = true
	SensorTowers.apply_register(self)


## A trimesh collision of `shape`'s visible meshes on `body` (in the body's frame; Structure.make_shape_collision).
static func add_shape_collision(body: CollisionObject3D, shape: ShapeInstance) -> void:
	var col := Structure.make_shape_collision(body, shape)
	if col != null:
		body.add_child(col)


## Bounds of `shape`'s visible meshes in `frame`'s space (pieces that start hidden, like muzzle flashes and
## deploy effects, stay out of it; an empty box at the origin when it has none).
static func make_shape_bounds(frame: Node3D, shape: ShapeInstance) -> AABB:
	var box := AABB()
	var found := false
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		if not (mi as MeshInstance3D).visible:
			continue
		var b: AABB = frame.global_transform.affine_inverse() * mi.global_transform * (mi as MeshInstance3D).get_aabb()
		box = b if not found else box.merge(b)
		found = true
	return box


# ------------------------------------------------------------------ state

## Damage taken so far (engine points), from the integrity every peer has.
func make_damage_taken() -> float:
	return damage.make_damage_taken()


## Enabled: not destroyed and below its disabled damage (Tribes damage state "Enabled").
func is_enabled() -> bool:
	return damage.is_enabled()


## "Enabled", "Disabled" or "Destroyed" (GameBase::getDamageState).
func make_damage_state() -> String:
	return damage.make_state()


## Does its job: enabled and powered (a generator only needs to be enabled).
func is_working() -> bool:
	return is_enabled() and has_power()


## Powered by its base, or needing none (a generator, a deployed object, a captured object).
func has_power() -> bool:
	return powered or not needs_power()


func needs_power() -> bool:
	return not (kind in UNPOWERED_KINDS) and not self_powered and not is_captured()


## A generator that feeds its power group (Generator::isPowering: not disabled).
func is_power_source() -> bool:
	return kind == KIND_GENERATOR and is_enabled()


## Called by TribesBase with the power of its group.
func apply_power(on: bool) -> void:
	powered = on
	_apply_lights()


func _apply_lights() -> void:
	if lights:
		lights.apply_lit(is_working())


## Emits state_changed when the enabled state flipped since the last check (TribesBase polls every peer).
func apply_state_check() -> void:
	_apply_lights()
	var now := is_enabled()
	if now != _was_enabled:
		_was_enabled = now
		state_changed.emit(self)


func _physics_process(delta: float) -> void:
	if has_power() and is_enabled() and energy < energy_max:
		energy = minf(energy_max, energy + energy_recharge * delta)
	apply_capture_tick(delta)


# ------------------------------------------------------------------ repair and capture (Structure)

func can_repair() -> bool:
	return not invincible and super()


## A turret drops its target when its side changes (TribesTurret).
func apply_side_changed() -> void:
	target_cleared()


## A turret drops its target when its side changes (nothing to do for the other kinds).
func target_cleared() -> void:
	pass
