class_name Herc
extends CharacterBody3D
## A walking combat vehicle (Herc or Cybrid) built from a catalog definition (Packs.vehicle()).
##
## Authority: on the server (or in single player) the Herc simulates itself from its control
## fields, which a pilot (player / AI / remote input) writes each physics frame.
## On network clients it is a "puppet": its state comes from server snapshots and is interpolated
## (HercSnapshots). Damage rules: HercDamage; visual model helpers: HercModel.

signal destroyed(herc: Herc, killer: Node)
signal damaged(herc: Herc, attacker: Node)

## Torso twist / turret rig (engine/torso_rig.gd, preloaded: no global class to register).
const TorsoRig := preload("res://engine/torso_rig.gd")
const NODE_TORSO := TorsoRig.DEFAULT_TORSO_NODE
const NODE_COCKPIT := HercModel.NODE_COCKPIT
const GRAVITY := WorldPhysics.DEFAULT_GRAVITY
## Ground-hugging push while on the floor.
const FLOOR_SNAP_SPEED := -0.5
## A dead Herc's slide comes to rest at this deceleration (m/s^2).
const DEATH_SLIDE_DECEL := 5.0
## Turning slows to this fraction at full speed.
const TURN_AT_SPEED := 0.6
const FOOTSTEP_DB_LOCAL := -6.0
const FOOTSTEP_DB_OTHER := -10.0
## Collision capsule from the model height.
const CAPSULE_RADIUS_FACTOR := 0.22
const CAPSULE_MIN_RADIUS := 1.2
const CAPSULE_MAX_RADIUS := 4.0
## The collision capsule's cylinder is at least this long (see _build_collision).
const HIT_CAPSULE_MIN_BODY := 0.1
const DEFAULT_MODEL_HEIGHT := 8.0
## ES2 equipment pods (effects per the original shell/manual text).
const ENERGY_BONUS := 1.5
const SPEED_BURST := 1.2
const ACCEL_BURST := 1.3
## A torso limit within this of 180 degrees is a turret that turns all the way round (catalog limits are rounded).
const TURRET_FULL_TURN_SLACK := 0.01

@export var vehicle_id := "es1:RAPTOR"
@export var team := 0
var display_name := ""
var net_id := 0
var owner_peer := 1          # peer that pilots this Herc (1 = server / AI)
var is_puppet := false
## Network pilot link (engine/net/pilot_link.gd): the server feeds a remote pilot's input frames through it, a predicting
## client simulates its own body through it. Null (a LAN host's default): the body is driven by its controls directly.
var pilot_link: PilotLink
var _hit_capsule := Vector2.ZERO
var palette_id := "es1:WORLD0"

var def: Dictionary
var max_speed := 14.0
var reverse_speed := 5.0
var accel := 4.0
var turn_rate := 0.9
var torso_rate := 1.6
var torso_limit := deg_to_rad(77.0)
var pitch_rate := 1.2
var pitch_max := deg_to_rad(40.0)
var pitch_min := deg_to_rad(-40.0)

# --- controls (written by the pilot)
var throttle := 0.0
var turn := 0.0
var torso_target := 0.0
var pitch_target := 0.0

# --- state
var speed := 0.0
var torso_yaw := 0.0
var pitch := 0.0
var alive := true
var shape: ShapeInstance
## Legs (walk / run / turn in place / death), per pack: engine/herc_animator.gd.
var animator: HercAnimator
## Torso twist / turret yaw and pitch on top of the legs: engine/torso_rig.gd.
var torso: TorsoRig
var weapons: Array = []
var target: Node3D = null

# --- damage model (original: front/rear shield banks, components with hp)
var shield_max := 3500.0
var shield_front := 1750.0
var shield_rear := 1750.0
var shield_recharge := 4.0 * Packs.TICK_HZ   # per second
## Seconds both shield banks stay off after an EMP hit (EsDamageModel; no recharge meanwhile).
var shields_down_s := 0.0
## Its game's gravity (WorldPhysics; Tribes vehicles fall at 20 m/s^2).
var gravity := GRAVITY
## How this vehicle's game lands weapon hits (DamageModel.for_vehicle).
var damage_model := DamageModel.new()
var components: Array = []    # [{name, hp, max, fatal, parent}]
var integrity := 1.0          # 0..1 summary for HUD
var capacitor := 960.0
var capacitor_max := 960.0
var capacitor_rate := 20.0 * Packs.TICK_HZ
var kills := 0
var deaths := 0
## Seconds of damage immunity after each (re)spawn; 0 = none. Remake addition (the originals have
## none): set by BattleSpawner for arena / versus matches, ended early when this vehicle fires.
var spawn_protection := 0.0
## Movement steps per physics tick (1; a Spider's lunge takes three: SelfDestructCharge).
var move_steps := 1
## The pilot's skin of this vehicle (SkinCatalog id, "" = default; spawn spec "skin").
var skin := ""

var _death_t := 0.0
## A component's big explosion played in the current hit: it stands for the death blast and silences further
## component explosions of that hit (ES1 DBSIM 0xaf140, reset per damage application at 0x9ff2; ES2 0x4a98b0).
var _big_blast_played := false
var _protected_until_ms := 0
var _muzzles := {}   # gun dict -> Marker3D (explicit muzzle points)
var _snapshots := HercSnapshots.new()
var _last_yaw := 0.0
var _eye_mount := {}  # eye_mount(): {node, position}
## The pilot's missiles in flight: missile camera and steered EO missile (MissileSteering).
var missile_steering := MissileSteering.new(self)
## The cloak this unit carries (docs/formats/cloaking.md); CloakState does nothing until a profile is installed.
var cloak := CloakState.new()
## The pilot's (or a mission order's) wish to be cloaked: a vehicle follows it (a soldier's cloak follows his pack).
var cloak_input := false


func _ready() -> void:
	platform_on_leave = CharacterBody3D.PLATFORM_ON_LEAVE_DO_NOTHING
	platform_floor_layers = 0
	add_to_group("vehicles")
	add_child(missile_steering)
	_configure()
	_build_model()
	_build_collision()
	if is_self_destructing():
		add_child(SelfDestructCharge.new(self))


func _build_model() -> void:
	shape = ShapeInstance.new()
	var sdef := Assets.shape(def.get("shape", vehicle_id))
	shape.texture_overrides = SkinCatalog.make_texture_overrides(str(sdef.get("id", "")), skin)
	add_child(shape)
	shape.build(sdef, 0, palette_id)
	_stand_on_lowest_point()
	_muzzles = HercModel.build_mounts(def, shape)
	animator = HercAnimator.new(def, shape, float(def.get("max_speed", max_speed)))
	animator.footstep.connect(_play_footstep)
	torso = TorsoRig.new(def, shape, _muzzles.values())
	_last_yaw = rotation.y


## Collision capsule from the model height, standing on the middle of the hull's footprint: a hull off the
## vehicle origin (a long tank whose turret sits aft) would otherwise poke out of the capsule, and its own
## guns would fire into the capsule from outside.
func _build_collision() -> void:
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	var h := _shape_height()
	cap.radius = clampf(h * CAPSULE_RADIUS_FACTOR, CAPSULE_MIN_RADIUS, CAPSULE_MAX_RADIUS)
	cap.height = maxf(h, cap.radius * 2.0 + 0.1)
	col.shape = cap
	var footprint := _shape_footprint_centre()
	col.position = Vector3(footprint.x, cap.height * 0.5, footprint.y)
	add_child(col)


func _configure() -> void:
	def = Packs.vehicle(vehicle_id)
	if def.is_empty():
		push_error("unknown vehicle " + vehicle_id)
		def = {"shape": vehicle_id, "name": vehicle_id}
	if display_name == "":
		display_name = def.get("name", vehicle_id)
	_apply_vehicle_stats()
	components = HercDamage.make_components(def)
	integrity = 1.0
	cloak.apply_profile(CloakProfile.of_vehicle(vehicle_id, def))


func _apply_vehicle_stats() -> void:
	max_speed = def.get("max_speed", max_speed)
	reverse_speed = def.get("reverse_speed", reverse_speed)
	accel = def.get("accel", accel)
	turn_rate = def.get("turn_rate", turn_rate)
	torso_rate = def.get("torso_rate", torso_rate)
	torso_limit = def.get("torso_limit", torso_limit)
	pitch_rate = def.get("pitch_rate", pitch_rate)
	pitch_max = def.get("pitch_max", pitch_max)
	pitch_min = def.get("pitch_min", pitch_min)
	shield_max = def.get("shield_max", shield_max)
	shield_front = shield_max * 0.5
	shield_rear = shield_max * 0.5
	if has_meta("balanced"):
		var f: float = def.get("speed_balance", 1.0)
		max_speed *= f
		reverse_speed *= f
		accel *= f
	shield_recharge = def.get("shield_recharge", shield_recharge)
	capacitor_rate = def.get("capacitor_rate", capacitor_rate)
	damage_model = DamageModel.for_vehicle(def)
	gravity = WorldPhysics.gravity_of(def)


## Equips weapons from a list of weapon ids (one per hardpoint). A fixed-loadout vehicle (Tribes) always
## carries its standard weapons, whatever the list says.
func equip(loadout: Array) -> void:
	for w in weapons:
		w.queue_free()
	weapons.clear()
	if PackVehicleLoader.has_fixed_loadout(def):
		loadout = def.get("loadout", [])
	# slot index = hardpoint index (empty hardpoints keep their place)
	for i in loadout.size():
		var wid: String = str(loadout[i]) if loadout[i] != null else ""
		if wid == "":
			continue
		var wdef := Packs.weapon(wid)
		if wdef.is_empty() or wdef.get("category", "herc") != def.get("category", "herc"):
			continue  # weapon families never mix (herc / infantry / vehicle)
		var w := Weapon.from_def(wdef)
		w.herc = self
		w.mount_index = i
		add_child(w)
		weapons.append(w)
		_attach_weapon_model(i, wdef)
	_stand_on_lowest_point()
	_apply_equipment()


## Stands the model on its lowest visible point, weapon pods included: a pod slung under a low hull (the ES2
## Razor's belly guns) would otherwise hang below the ground and fire from inside it.
func _stand_on_lowest_point() -> void:
	shape.position.y = -shape.lowest_point() * shape.scale.y


## Passive pod effects (ES2 equipment; effects per the original shell/manual text).
func _apply_equipment() -> void:
	for w in weapons:
		var fx: Dictionary = w.effects
		if fx.has("shield_multiplier"):
			shield_max *= float(fx.shield_multiplier)
			shield_front = shield_max * 0.5
			shield_rear = shield_max * 0.5
		if fx.get("energy_bonus", false):
			capacitor_rate *= ENERGY_BONUS
		if fx.get("speed_burst", false):
			max_speed *= SPEED_BURST
			accel *= ACCEL_BURST
		if fx.has("missile_jam_deg"):
			set_meta("ecm_jam_deg", float(fx.missile_jam_deg))
		if fx.get("ecm_counter", false):
			set_meta("eccm", true)


## Visible weapon pod: the weapon's shape for this hardpoint's mount group (MECHWPNS library); an internal
## gun draws none but gets its muzzle (HercModel.apply_internal_muzzle).
func _attach_weapon_model(i: int, wdef: Dictionary) -> void:
	var model := HercModel.weapon_model(def, i, wdef, palette_id)
	var mounts := mount_points()
	if model == null:
		HercModel.apply_internal_muzzle(mounts[i % mounts.size()], def, i, wdef)
		return
	HercModel.attach_weapon_model(mounts[i % mounts.size()], model, def)


# ------------------------------------------------------------------ shared model helpers
# Deprecated aliases: use HercModel (kept for the hangar and older callers).

static func weapon_model(vdef: Dictionary, i: int, wdef: Dictionary, palette: String) -> ShapeInstance:
	return HercModel.weapon_model(vdef, i, wdef, palette)


static func attach_weapon_model(parent: Node3D, model: ShapeInstance, vdef: Dictionary) -> void:
	HercModel.attach_weapon_model(parent, model, vdef)


static func mount_nodes(vdef: Dictionary, s: ShapeInstance, muzzles: Dictionary) -> Array:
	return HercModel.mount_nodes(vdef, s, muzzles)


## Centre (x, z: Vector2 x, y) of the visible model's box in this vehicle's frame; zero without geometry.
func _shape_footprint_centre() -> Vector2:
	var box := AABB()
	var first := true
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree():
			continue
		var b: AABB = global_transform.affine_inverse() * mi.global_transform * mi.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var c := box.get_center()
	return Vector2(c.x, c.z)


func _shape_height() -> float:
	var top := -INF
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		if not mi.is_visible_in_tree():
			continue
		var aabb: AABB = mi.mesh.get_aabb()
		var xf: Transform3D = global_transform.affine_inverse() * mi.global_transform
		for k in 8:
			top = maxf(top, (xf * aabb.get_endpoint(k)).y)
	return top if top > -INF else DEFAULT_MODEL_HEIGHT


## The node carrying the view and the torso pitch (catalog "cockpit_node", default the 3Space cockpit;
## -1 = none, e.g. a Tribes tank: the view rides the turret (torso node) and the aim is built from the
## chassis, the torso yaw and the pitch).
func cockpit_node() -> Node3D:
	var i := _cockpit_index()
	if i < 0:
		return HercModel.attach_node(shape, _torso_index())
	return shape.nodes[i] if shape.nodes.size() > i else shape


## Every vehicle with a cockpit or HUD (CockpitFit resolved a layout) starts in its cockpit view, as the Hercs do;
## one with neither a layout nor a cockpit node starts in the chase view.
func prefers_chase_view() -> bool:
	return not CockpitFit.has_cockpit(def) and _cockpit_index() < 0


func _cockpit_index() -> int:
	return int(def.get("cockpit_node", NODE_COCKPIT))


func _torso_index() -> int:
	return int(def.get("torso_node", NODE_TORSO))


## Weapon muzzle points: hardpoint markers if the shape has them, else the cockpit.
func mount_points() -> Array:
	return HercModel.mount_nodes(def, shape, _muzzles)


## The pilot's sight: the chassis heading turned by the torso twist and tilted by the pitch, the same angles
## the torso rig poses the model with. The cockpit camera looks along it (BattleCameras.apply_sight), so the
## crosshair - the view's projection centre - is this direction from aim_origin(), whatever the rest pose
## of the cockpit node (Starsiege head0, Tribes turrets) is.
func aim_basis() -> Basis:
	return global_basis.orthonormalized() * Basis(Vector3.UP, torso_yaw) * Basis(Vector3.RIGHT, pitch)


## The view's orientation: the sight (flyers add their bank, which does not move the crosshair).
func sight_basis() -> Basis:
	return aim_basis()


## The unit direction `weapon` fires in from `muzzle` when its pilot leads the shot (an AI flyer: the shot keeps the
## craft's speed), else ZERO: the weapon then fires at the crosshair point (Weapon.make_aim_direction).
func make_lead_direction(_weapon: Weapon, _muzzle: Vector3) -> Vector3:
	return Vector3.ZERO


## The pilot's eye point: where the cockpit camera sits and every shot's aim ray starts.
func aim_origin() -> Vector3:
	var mount := eye_mount()
	return (mount.node as Node3D).global_transform * (mount.position as Vector3)


## The eye's node and position in it: its game's eye point (CockpitEye), else in front of the cockpit node's
## meshes (BattleCameras.make_eye_position). Resolved once per model.
func eye_mount() -> Dictionary:
	if _eye_mount.is_empty() or not is_instance_valid(_eye_mount.node):
		_eye_mount = CockpitEye.make_mount(self)
		if _eye_mount.is_empty():
			var cn := cockpit_node()
			_eye_mount = {"node": cn, "position": BattleCameras.make_eye_position(cn)}
	return _eye_mount


func is_local_player() -> bool:
	return has_meta("local_player")


# ------------------------------------------------------------------ simulation

func _physics_process(delta: float) -> void:
	if pilot_link != null and pilot_link.is_predicting(self):
		_predicted_update(delta)
		return
	if is_puppet:
		_puppet_update(delta)
		return
	capacitor = minf(capacitor_max, capacitor + capacitor_rate * delta)
	cloak.apply_follow(cloak_input, self)
	cloak.apply_step(self, delta)
	if not alive:
		_death_slide(delta)
		return
	_apply_shield_recharge(delta)
	if pilot_link != null:
		pilot_link.begin_step(self, delta)
	if has_meta("disabled_until") and Time.get_ticks_msec() < int(get_meta("disabled_until")):
		_hold_controls()
	_drive(delta)
	apply_torso_step(delta)
	if pilot_link != null:
		pilot_link.end_step(self)
	_animate(delta)


## One step of the movement a PilotLink replays when it reconciles: whatever decides where the body goes next.
func step_movement(delta: float) -> void:
	capacitor = minf(capacitor_max, capacitor + capacitor_rate * delta)
	_drive(delta)


## The local pilot's own body on a predicting client: it runs its movement from the pilot's controls now and the
## server's echo corrects it later (Prediction); damage, weapons and everything else still come from the server.
func _predicted_update(delta: float) -> void:
	cloak.apply_step(self, delta)
	pilot_link.begin_step(self, delta)
	step_movement(delta)
	apply_torso_step(delta)
	pilot_link.end_step(self)
	_animate(delta)


## Capsule (radius, height in metres) standing on the position that shots are tested against (HitHistory).
func make_hit_capsule() -> Vector2:
	if _hit_capsule == Vector2.ZERO:
		var size := make_body_size()
		_hit_capsule = Vector2(size.x, maxf(size.y, size.x * 2.0 + HIT_CAPSULE_MIN_BODY))
	return _hit_capsule


## Turns the torso / turret toward torso_target and pitch_target at the vehicle's rates, within its limits.
func apply_torso_step(delta: float) -> void:
	torso_yaw = make_torso_yaw_step(torso_yaw, torso_target, torso_limit, torso_rate * delta)
	pitch = move_toward(pitch, clampf(pitch_target, pitch_min, pitch_max), pitch_rate * delta)


## One step of a torso yaw from `current` toward `wanted` by at most `step` (radians). A turret whose limit is
## a half turn or more (tanks: Starsiege turretAngleLimit 180) turns all the way round by the shorter way;
## any other torso is clamped to +-limit.
static func make_torso_yaw_step(current: float, wanted: float, limit: float, step: float) -> float:
	if limit >= PI - TURRET_FULL_TURN_SLACK:
		var d := wrapf(wanted - current, -PI, PI)
		return wrapf(current + clampf(d, -step, step), -PI, PI)
	return move_toward(current, clampf(wanted, -limit, limit), step)


func _death_slide(delta: float) -> void:
	_death_anim(delta)
	velocity.y -= gravity * delta
	velocity.x = move_toward(velocity.x, 0, DEATH_SLIDE_DECEL * delta)
	velocity.z = move_toward(velocity.z, 0, DEATH_SLIDE_DECEL * delta)
	move_and_slide()


## EMP / disabled: no movement and no fire.
func _hold_controls() -> void:
	throttle = 0.0
	turn = 0.0
	for w in weapons:
		w.trigger = false


## Throttle and turn into chassis motion (legs cap the speed; turning slows with speed).
func _drive(delta: float) -> void:
	var target_speed := throttle * (max_speed if throttle >= 0.0 else reverse_speed) * HercDamage.leg_speed_factor(components)
	speed = move_toward(speed, target_speed, accel * delta)
	var tr := turn_rate * lerpf(1.0, TURN_AT_SPEED, clampf(absf(speed) / maxf(max_speed, 0.1), 0.0, 1.0))
	rotate_y(-turn * tr * delta * move_steps)
	var fwd := -global_basis.z
	velocity.x = fwd.x * speed * move_steps
	velocity.z = fwd.z * speed * move_steps
	if is_on_floor():
		velocity.y = FLOOR_SNAP_SPEED
	else:
		velocity.y -= gravity * delta
	var moved_at := velocity
	move_and_slide()
	CollisionDamage.apply_contacts(self, moved_at)


func _animate(delta: float) -> void:
	var yaw_delta := wrapf(rotation.y - _last_yaw, -PI, PI)
	_last_yaw = rotation.y
	animator.update(speed, yaw_delta, delta)
	torso.apply(torso_yaw, pitch, animator.animates)


func _play_footstep() -> void:
	Sfx.play_at("footstep", global_position, FOOTSTEP_DB_LOCAL if is_local_player() else FOOTSTEP_DB_OTHER)


# ------------------------------------------------------------------ damage (server side)

## The banks recharge, except while an EMP holds them down.
func _apply_shield_recharge(delta: float) -> void:
	if shields_down_s > 0.0:
		shields_down_s = maxf(0.0, shields_down_s - delta)
		return
	var rech := shield_recharge * delta
	shield_front = minf(shield_max * 0.5, shield_front + rech)
	shield_rear = minf(shield_max * 0.5, shield_rear + rech)


## A hit without its weapon (rams, scripts, blasts): the game's damage model with no weapon class or splash.
func apply_hit(shield_dmg: float, armor_dmg: float, attacker: Node = null, hit_pos := Vector3.ZERO) -> void:
	apply_weapon_hit(DamageModel.make_hit(shield_dmg, armor_dmg, attacker, hit_pos))


## A weapon hit (DamageModel hit record): the game's damage model takes the shields, then lands the armour damage
## that gets through on the components; then the death test.
func apply_weapon_hit(raw_hit: Dictionary) -> void:
	if not alive or is_puppet or is_spawn_protected():
		return
	var hit := damage_model.make_hit_scaled(raw_hit)
	_big_blast_played = false
	var through := damage_model.make_shield_through(self, hit)
	if through > 0.0:
		damage_model.apply_armor(self, hit, float(hit.armor) * through)
		integrity = HercDamage.integrity_of(components)
	cloak.apply_damaged(float(hit.armor))
	damaged.emit(self, hit.attacker)
	if alive and HercDamage.is_destroyed(components, integrity):
		_die(hit.attacker)


## True when a shot takes the front shield bank: the side the shot comes from, i.e. the attacker's side of the
## unit (ES1 DBSIM 0xfca8 picks the bank by the shot's origin in the unit's frame, y > 0 = front), not where it
## lands (a shot dropping onto the top of the hull lands behind the centre but still comes from the front).
## Without a positioned attacker: the side of the hit point.
func is_front_hit(hit_pos: Vector3, attacker: Node = null) -> bool:
	var from := (attacker as Node3D).global_position if attacker is Node3D and attacker != self else hit_pos
	return (global_transform.affine_inverse() * from).z < 0.0


## Shield charge of the bank facing `hit_pos` (front / rear, as apply_hit chooses it); FxSurface uses it.
func shield_bank_at(hit_pos: Vector3) -> float:
	var local := global_transform.affine_inverse() * hit_pos
	return shield_front if local.z < 0.0 else shield_rear


## Takes shield damage from the front or rear bank; returns the fraction that gets through (DamageModel).
func absorb_with_shield(shield_dmg: float, front: bool) -> float:
	var bank := shield_front if front else shield_rear
	var through := 1.0
	if shield_dmg > 0.0:
		if bank >= shield_dmg:
			bank -= shield_dmg
			through = 0.0
		else:
			through = (shield_dmg - bank) / shield_dmg
			bank = 0.0
	if front:
		shield_front = bank
	else:
		shield_rear = bank
	return through


## Armour damage straight to component `index`, past the shields (Earthsiege blast splash: DBSIM 0x13a7c ->
## 0x13250), with the death check of a hit.
func apply_component_hit(index: int, amount: float, attacker: Node) -> void:
	if not alive or is_puppet or is_spawn_protected() or index < 0 or index >= components.size():
		return
	_big_blast_played = false
	wound_component(index, amount)
	integrity = HercDamage.integrity_of(components)
	damaged.emit(self, attacker)
	if alive and HercDamage.is_destroyed(components, integrity):
		_die(attacker)


## The shield bank facing world point `from` takes `amount`; returns what gets through (Earthsiege 2 blast:
## DBSIM 1.0 0x4187d0 -> 0x413c68).
func apply_shield_absorb(amount: float, from: Vector3) -> float:
	if is_puppet or amount <= 0.0:
		return amount
	return amount * absorb_with_shield(amount, (global_transform.affine_inverse() * from).z < 0.0)


## World point of damage component `index`: its COL sphere in its part (catalog "component_points"), else the
## unit's centre (DBSIM vtable slot 0x5c 0x15990).
func make_component_position(index: int) -> Vector3:
	var points: Array = def.get("component_points", [])
	if index < 0 or index >= points.size() or (points[index] as Array).is_empty() or shape == null:
		return global_position
	var p: Array = points[index]
	return WeaponMount.part_node(shape, int(p[0])).global_transform * ShapeInstance.es_to_godot(p[1])


## True for a unit that blows itself up on contact (the Earthsiege Spider, catalog "self_destruct").
func is_self_destructing() -> bool:
	return not (def.get("self_destruct", {}) as Dictionary).is_empty()


## Takes `amount` off component `index`; a component that breaks shows its damaged part and its explosion.
func wound_component(index: int, amount: float) -> void:
	var comp: Dictionary = components[index]
	if comp.hp <= 0.0:
		return
	comp.hp -= amount
	if comp.hp <= 0.0:
		comp.hp = 0.0
		_show_component_damaged(comp)
		play_component_destroyed(index)


## The broken component's own shape part switches to its damaged state (3Space DMG shape_part = the cells' damage
## slot, docs/formats/gameplay.md section 5): only that part, so the rest of the Herc keeps its textures. Units
## whose damage data names no parts (shape_part absent) show random cells, as before.
func _show_component_damaged(comp: Dictionary) -> void:
	var slot := int(comp.get("shape_part", HercDamage.NO_SHAPE_PART))
	if slot >= 0:
		shape.set_slot_state(slot, HercDamage.DAMAGED_CELL_STATE)
	elif not comp.has("shape_part"):
		for ci in shape.cell_count():
			if randf() < HercDamage.CELL_DAMAGE_CHANCE:
				shape.set_cell_state(ci, HercDamage.DAMAGED_CELL_STATE)


## Host: a collision of `amount` at `contact` (CollisionDamage, Earthsiege's ramming rule 0x13a7c): it bypasses the
## shields; each component is hit at RAM_COMPONENT_CHANCE and takes the amount falling off with its sphere's
## distance from the contact over RAM_REACH_UNITS (Blast); a unit without positioned components takes the
## falloff's mean on each. `attacker` is credited.
func apply_collision_damage(amount: float, attacker: Node, contact := Vector3.INF) -> void:
	if not alive or is_puppet or is_spawn_protected():
		return
	_big_blast_played = false
	if contact == Vector3.INF or (def.get("component_points", []) as Array).is_empty():
		for i in components.size():
			if randf() < CollisionDamage.RAM_COMPONENT_CHANCE:
				wound_component(i, amount * CollisionDamage.RAM_COMPONENT_SHARE)
	else:
		for hit in Blast.make_component_hits(self, contact, {"amount": amount, "chance": CollisionDamage.RAM_COMPONENT_CHANCE,
				"radius": CollisionDamage.RAM_REACH_UNITS * Assets.UNIT}):
			wound_component(int(hit[0]), float(hit[1]))
	KillText.apply_cause(self, KillText.CAUSE_COLLISION)   # the kill message says how (KillText)
	_apply_damage_result(attacker)
	KillText.apply_cause(self, "")


## A mission unit that starts damaged (mission record health < 100): the Earthsiege pre-damage (ES1 DBSIM 0x12f20,
## ES2 0x4178e8; HercDamage.make_start_level, docs/formats/gameplay.md section 5). Below 20 % a front quad (and on a
## four-legged unit a rear quad) is blown off; then each component, at a chance of (level + 25) / 256, loses
## (level / 2 + random(level)) / 256 of its hit points. No cockpit can be destroyed, so the unit starts alive (the
## original runs no death check here either).
func apply_start_health(health: int) -> void:
	var level := HercDamage.make_start_level(health)
	if level == 0:
		return
	_big_blast_played = true   # no explosions at spawn: the original only marks the damage
	if health < HercDamage.START_LEG_LOSS_HEALTH:
		for pair in HercDamage.make_start_lost_legs(components):
			wound_component(pair[randi() % 2], HercDamage.START_LEG_DAMAGE)
	for i in components.size():
		if randi() % HercDamage.START_DAMAGE_ROLL < level + HercDamage.START_DAMAGE_CHANCE_BONUS:
			var share := float(level / 2 + randi() % level) / HercDamage.START_DAMAGE_ROLL
			wound_component(i, float(components[i].max) * share)
	integrity = HercDamage.integrity_of(components)
	_big_blast_played = false


## Host: damage from the world itself (out of bounds, BattleBounds): every component loses `share` of its full
## hit points; nobody is credited. `cause` names it in the kill message (KillText).
func apply_environment_damage(share: float, cause := KillText.CAUSE_BOUNDS) -> void:
	if not alive or is_puppet:
		return
	_big_blast_played = false
	for i in components.size():
		wound_component(i, float(components[i].max) * share)
	KillText.apply_cause(self, cause)
	_apply_damage_result(null)
	KillText.apply_cause(self, "")


func _apply_damage_result(attacker: Node) -> void:
	integrity = HercDamage.integrity_of(components)
	damaged.emit(self, attacker)
	if alive and HercDamage.is_destroyed(components, integrity):
		_die(attacker)


## The destroyed component's explosion, as its game draws it (DeathFx "component" / "component_big"); every
## peer plays it (puppets from the damage block, HercSnapshots).
func play_component_destroyed(index: int) -> void:
	if _big_blast_played or index < 0 or index >= components.size():
		return
	var big := bool(components[index].get("big_explosion", false))
	_big_blast_played = big
	DeathFx.play(get_parent(), DeathFx.make_body(self, vehicle_id,
		DeathFx.KIND_COMPONENT_BIG if big else DeathFx.KIND_COMPONENT, make_body_size()))


## Destroys every component at once (the Spider's self-destruct: DBSIM 0x182e3 deals 32000 to each of them).
func apply_destruction(attacker: Node) -> void:
	if not alive or is_puppet:
		return
	for c in components:
		c.hp = 0.0
	integrity = HercDamage.integrity_of(components)
	_die(attacker)


## A new damage application: big component blasts of earlier hits no longer stand for the death.
func begin_damage_application() -> void:
	_big_blast_played = false


func _die(killer: Node) -> void:
	alive = false
	throttle = 0.0
	speed = 0.0
	for w in weapons:
		w.trigger = false
	deaths += 1
	if killer is Herc and killer != self:
		killer.kills += 1
	destroyed.emit(self, killer)
	_explode()


## The game's own death blast (DeathFx "vehicle"), unless the destroyed cockpit's big explosion already is it.
func _explode() -> void:
	if _big_blast_played:
		return
	var body := DeathFx.make_body(self, vehicle_id, DeathFx.KIND_VEHICLE, make_body_size())
	body.keys.append(str(def.get("kind", "")))
	DeathFx.play(get_parent(), body)


## Radius (m) of the contact sphere: the catalog's (Earthsiege DAT 0x6e), else the collision capsule's.
func make_contact_radius() -> float:
	var r := float(def.get("collision_radius", 0.0))
	return r if r > 0.0 else make_body_size().x


## Half width and height of the model (metres): where death effects scatter.
func make_body_size() -> Vector2:
	var h := _shape_height() if shape else DEFAULT_MODEL_HEIGHT
	return Vector2(clampf(h * CAPSULE_RADIUS_FACTOR, CAPSULE_MIN_RADIUS, CAPSULE_MAX_RADIUS), h)


func _death_anim(delta: float) -> void:
	_death_t += delta
	animator.apply_death(_death_t)


## Resets for a respawn (arena modes).
func respawn(xf: Transform3D) -> void:
	global_transform = xf
	apply_spawn_protection()
	_last_yaw = rotation.y
	alive = true
	_death_t = 0.0
	_big_blast_played = false
	speed = 0.0
	throttle = 0.0
	_configure()
	_repair_model()
	for w in weapons:
		w.reload()


## Starts the spawn protection window (spawn_protection seconds from now).
func apply_spawn_protection() -> void:
	_protected_until_ms = Time.get_ticks_msec() + int(spawn_protection * 1000.0)


## Ends the spawn protection window (the vehicle opened fire).
func end_spawn_protection() -> void:
	_protected_until_ms = 0


func is_spawn_protected() -> bool:
	return Time.get_ticks_msec() < _protected_until_ms


func _repair_model() -> void:
	for ci in shape.cell_count():
		shape.set_cell_state(ci, 0)
	shape.reset_pose()
	animator.apply_stand()


# ------------------------------------------------------------------ networking

## Compact state for snapshots (HercSnapshots.SNAP_*; the damage block is appended by BattleNetSync).
func snapshot() -> Array:
	return [net_id, global_position, rotation.y, torso_yaw, pitch, speed, alive,
		shield_front, shield_rear, integrity, capacitor, kills, deaths, HercSnapshots.make_trigger_bits(self)]


func apply_snapshot(s: Array, dt: float) -> void:
	_snapshots.push(s, dt)
	if s.size() > HercSnapshots.SNAP_TRIGGERS and not is_local_player():   # the local pilot owns its triggers
		HercSnapshots.apply_trigger_bits(self, int(s[HercSnapshots.SNAP_TRIGGERS]))
	if s.size() > HercSnapshots.SNAP_DAMAGE and not (s[HercSnapshots.SNAP_DAMAGE] as PackedByteArray).is_empty():
		HercSnapshots.apply_damage_block(self, s[HercSnapshots.SNAP_DAMAGE])
	if s.size() > HercSnapshots.SNAP_MISSILE_STEER and s[HercSnapshots.SNAP_MISSILE_STEER] is Vector2 and not is_local_player():
		missile_steering.stick = s[HercSnapshots.SNAP_MISSILE_STEER]
	if s.size() > HercSnapshots.SNAP_CLOAK:
		cloak.apply_remote(bool(s[HercSnapshots.SNAP_CLOAK]))
	var predicted := pilot_link != null and pilot_link.is_predicting(self)
	if not predicted:
		speed = s[5]
		capacitor = s[10]   # a predicted body spends its own capacitor on jets and is corrected by the server's echo
	shield_front = s[7]
	shield_rear = s[8]
	integrity = s[9]
	kills = s[11]
	deaths = s[12]
	if alive and not s[6]:
		alive = false
		_explode()
	elif not alive and s[6]:
		alive = true
		_death_t = 0.0
		global_position = s[1]
		_snapshots.snap_to_latest()
		_repair_model()


func _puppet_update(delta: float) -> void:
	cloak.apply_step(self, delta)
	if _snapshots.is_empty():
		return
	var pose := _snapshots.advance(delta)
	global_position = pose.pos
	rotation.y = pose.yaw
	torso_yaw = pose.torso
	pitch = pose.pitch
	if alive:
		_animate(delta)
	else:
		_death_anim(delta)
