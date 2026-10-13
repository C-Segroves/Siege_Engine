class_name Infantry
extends Herc
## A soldier on foot in Tribes / Tribes 2 powered armour (InfantryCatalog record; docs/formats/tribes_infantry.md):
## runs, jumps and flies on the jetpack, carries up to `max_weapons` infantry weapons (one in hand) with
## ammunition, and spends one energy pool on the jet and the energy weapons.
##
## It is a combat unit like a vehicle (it extends Herc): it takes damage from everything, counts kills and
## deaths, respawns, is snapshotted over the LAN and is driven through the same control fields:
##   throttle      forward (+1) / back (-1) movement input
##   turn          strafe: -1 left .. +1 right
##   torso_target  body yaw (absolute, radians), the look direction
##   pitch_target  look pitch
## plus jet_input, jump_input and weapon_slot. Inside a vehicle (VehicleOccupancy) it is `stowed`: hidden,
## without collision, out of the "vehicles" group, carried along by the OccupancyDirector; in an armed
## passenger seat (InfantrySeat) it keeps firing its own weapons within the seat's view arc.
## Besides its weapons it carries a kit (InfantryKit: grenades, mines, repair kits, a backpack, InfantryPack),
## takes falling damage (armour fall_min_speed / fall_damage_per_mps) and scales each hit by its armour's
## damage-type scale (DamageTypes).

## Tribes gravity: missions set contGravity "0 0 -20" (tribes.md section 4); the jetpack is tuned to it.
const TRIBES_GRAVITY := 20.0
const SOLDIER_FLOOR_SNAP := -1.0
## Held in a crease of steep faces (no floor, moving at less than this share of its velocity): the soldier keeps
## the velocity it really has, so its fall speed doesn't build up while it stays put - it would hit the faces
## harder every frame and die of "fall" damage where it stands.
const HELD_SPEED_SHARE := 0.1
## Held like that this long and overlapping the world's geometry, the soldier is stuck in it (a spawn point inside
## an interior): he dies and respawns, as the fall speed used to kill him (remake rule). Merely held on steep faces
## (no overlap) he stays.
const HELD_DEATH_SECONDS := 6.0
## The overlap probe uses the body's capsule this much smaller (metres), so touching a face is no overlap.
const INSIDE_PROBE_SHRINK := 0.1
## This far below the terrain the soldier has fallen out of the world (through a gap where an interior meets the
## terrain, e.g. a Tribes 2 base whose terrain holes the remake does not cut): he dies and respawns instead of
## falling for the rest of the match (remake rule).
const FELL_THROUGH_DEPTH := 100.0
## Ground friction while the soldier is dead (m/s^2).
const DEATH_FRICTION := 20.0
const LOOK_PITCH_LIMIT := deg_to_rad(80.0)
## The weapon grip relative to the eye (metres: right, down, forward): first-person view model and muzzle.
const HAND_OFFSET := Vector3(0.26, -0.34, -0.55)
const MUZZLE_AHEAD := Vector3(0.0, 0.0, -0.6)
## Snapshot field (after HercSnapshots.SNAP_DAMAGE, appended by BattleNetSync): make_snapshot_extra().
const SNAP_INFANTRY := HercSnapshots.SNAP_DAMAGE + 1
## Group of the soldiers sitting visibly in a vehicle (Nameplates names them on their seats).
const SEATED_RIDERS := "seated_riders"

var armor_id := ""
var armor: Dictionary = {}
var jet_input := false
var jump_input := false
var weapon_slot := 0
var jetting := false
var stowed := false
## Hand items and the backpack.
var kit := InfantryKit.new()
## The seat while stowed (null on foot).
var seat: InfantrySeat
## The look / first-person view node (cockpit_node()): at eye height, pitched with the look.
var eye: Node3D
## Another body for the armour ("" = the armour's own shape): the extraction mode's Bioderms wear the Tribes 2
## Bioderm bodies over the Tribes 2 armour stats (spawn spec "body_shape").
var body_shape := ""
## The skin of the drawn body ("" = its default; SkinCatalog, InfantryCatalog.make_skins).
var skin_id := ""
## The armour the soldier respawns in: the player's choice (BattleInfantry); "" = the pack's light armour, as
## Tribes respawns its players (Game::playerSpawn / DefaultGame::equip).
var spawn_armor_id := ""
## func(soldier: Infantry, attacker: Node) -> bool: returns true when it took the lethal hit itself, e.g. the
## extraction mode's downed state; the soldier then does not die. Called on the host only (puppets take no hits).
var lethal_hit_guard := Callable()

var _muzzle: Marker3D
## The weapon in hand: world model on the hand node, first-person view model on the eye.
var held := InfantryHeldWeapon.new(HAND_OFFSET)
var _collision: CollisionShape3D
var _animation: InfantryAnimation
var _sounds := InfantrySounds.new()
var _last_position := Vector3.ZERO
var _held_seconds := 0.0


func _configure() -> void:
	armor = InfantryCatalog.armor(armor_id)
	if armor.is_empty():
		push_error("Infantry: unknown armour '%s'" % armor_id)
		armor_id = InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())
		armor = InfantryCatalog.armor(armor_id)
	def = armor
	vehicle_id = armor_id
	if display_name == "":
		display_name = str(armor.get("name", armor_id))
	_apply_armor_stats()


func _apply_armor_stats() -> void:
	max_speed = float(armor.get("max_forward_speed", 11.0))
	reverse_speed = float(armor.get("max_backward_speed", 10.0))
	accel = float(armor.get("ground_accel", 40.0))
	shield_max = 0.0
	shield_front = 0.0
	shield_rear = 0.0
	shield_recharge = 0.0
	capacitor_max = float(armor.get("max_energy", 60.0))
	capacitor = capacitor_max
	capacitor_rate = float(armor.get("energy_recharge_per_s", 8.0))
	torso_limit = PI
	pitch_max = LOOK_PITCH_LIMIT
	pitch_min = -LOOK_PITCH_LIMIT
	var hp := float(armor.get("hp", 1980.0))
	components = [{"name": "ARMOR", "hp": hp, "max": hp, "fatal": true, "parent": -1}]
	integrity = 1.0


# ------------------------------------------------------------------ model

func _build_model() -> void:
	shape = ShapeInstance.new()
	shape.texture_overrides = SkinCatalog.make_texture_overrides(make_body_shape_id(), skin_id)
	add_child(shape)
	var pack := str(armor.get("pack", "tribes"))
	shape.build(Assets.shape(make_body_shape_id()), 0, Packs.default_palette(pack))
	shape.position.y = -shape.lowest_point() * shape.scale.y
	_animation = InfantryAnimation.new(shape)
	eye = Node3D.new()
	eye.name = "Eye"
	eye.position.y = float(armor.get("eye_height_m", 1.8))
	add_child(eye)
	_muzzle = Marker3D.new()
	_muzzle.position = HAND_OFFSET + MUZZLE_AHEAD
	eye.add_child(_muzzle)
	_last_yaw = rotation.y


## The shape the soldier is drawn with: `body_shape` when set (and imported), else the armour's.
func make_body_shape_id() -> String:
	return body_shape if body_shape != "" else str(armor.get("shape", ""))


## The hand node of the drawn body: the armour's hand node, found by name in another body.
func make_hand_node() -> int:
	var hand := int(armor.get("hand_node", -1))
	if body_shape == "" or hand < 0:
		return hand
	var own: Array = Assets.shape(str(armor.get("shape", ""))).get("nodes", [])
	var wanted := str(own[hand].get("name", "")).to_lower() if hand < own.size() else ""
	var nodes: Array = Assets.shape(body_shape).get("nodes", [])
	for i in nodes.size():
		if str(nodes[i].get("name", "")).to_lower() == wanted:
			return i
	return -1


func _build_collision() -> void:
	_collision = CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = float(armor.get("capsule_radius", 0.6))
	cap.height = maxf(float(armor.get("height_m", 2.2)), cap.radius * 2.0 + 0.1)
	_collision.shape = cap
	_collision.position.y = cap.height * 0.5
	add_child(_collision)


## Changes armour (inventory station) and carries `loadout` (weapon ids allowed in the new armour), the
## grenade type `grenade` and the pack `pack_choice` ("" = none), everything full.
func apply_armor(new_armor_id: String, loadout: Array, grenade := "", pack_choice := "") -> void:
	_apply_armor_id(new_armor_id)
	_rebuild_body()
	kit.apply_purchase(armor, grenade, pack_choice)
	equip(loadout)


## Wears armour `new_armor_id`, keeping the kind of body (female, Bioderm) when the new armour has one.
func _apply_armor_id(new_armor_id: String) -> void:
	var kind := _body_label()
	armor_id = new_armor_id
	_configure()
	body_shape = make_matching_body(armor_id, kind)


## The body of armour `id` with label `kind` ("Female", "Bioderm"); "" = the armour's own.
static func make_matching_body(id: String, kind: String) -> String:
	var bodies := InfantryCatalog.make_bodies(id)
	for i in range(1, bodies.size()):
		if str(bodies[i].label) == kind:
			return str(bodies[i].id)
	return ""


func _body_label() -> String:
	if body_shape == "":
		return ""
	for b in InfantryCatalog.make_bodies(armor_id):
		if str(b.id) == body_shape:
			return str(b.label)
	return ""


func _rebuild_body() -> void:
	for n in [shape, eye, _collision]:
		if is_instance_valid(n):
			remove_child(n)
			n.queue_free()
	held.clear()
	_build_model()
	_build_collision()
	_apply_stowed_state()


# ------------------------------------------------------------------ weapons

## Carries the weapons of `loadout` the armour allows (at most max_weapons), the first in hand.
func equip(loadout: Array) -> void:
	for w in weapons:
		w.queue_free()
	weapons.clear()
	for wid in loadout:
		if weapons.size() >= int(armor.get("max_weapons", 3)):
			break
		var wdef := Packs.weapon(str(wid))
		if wdef.is_empty() or wdef.get("category", "") != "infantry" or not InfantryCatalog.allows_weapon(armor_id, str(wid)):
			continue   # weapon families never mix; the armour's $ItemMax decides the rest
		var w := InfantryWeapon.make(wdef, make_rounds(str(wid)))
		w.herc = self
		add_child(w)
		weapons.append(w)
	apply_weapon_slot(0)


## Wears pack `pack_id` ("" = none): the weapons' full loads follow the ammo pack's extra rounds (T1 $AmmoPackMax,
## T2 AmmoPack max[]); rounds beyond a smaller load stay loaded until spent.
func apply_worn_pack(pack_id: String) -> void:
	if kit.pack_id == pack_id:
		return
	kit.pack_id = pack_id
	kit.pack_active = false
	for w in weapons:
		if w.ammo_max >= 0:
			w.ammo_max = make_rounds(w.weapon_id)


## Rounds of weapon `wid` the soldier carries full: the armour's limit plus the ammo pack's (-1: no ammunition).
func make_rounds(wid: String) -> int:
	var rounds := int((armor.get("ammo", {}) as Dictionary).get(wid, -1))
	return rounds + kit.make_extra_rounds(wid) if rounds >= 0 else rounds


## Weapon ids carried, in slot order.
func make_loadout() -> Array:
	return weapons.map(func(w: Weapon) -> String: return w.weapon_id)


func current_weapon() -> Weapon:
	return weapons[weapon_slot] if weapon_slot >= 0 and weapon_slot < weapons.size() else null


## Puts weapon `slot` in hand (Tribes nextWeapon / use(item)); the others stop firing.
func apply_weapon_slot(slot: int) -> void:
	weapon_slot = clampi(slot, 0, maxi(weapons.size() - 1, 0))
	for i in weapons.size():
		if i != weapon_slot:
			weapons[i].trigger = false
	_show_held_weapon()


## The next carried weapon's slot (wraps round).
func make_next_slot() -> int:
	return (weapon_slot + 1) % maxi(weapons.size(), 1)


func _show_held_weapon() -> void:
	held.build(current_weapon(), shape, make_hand_node(), eye)


func mount_points() -> Array:
	return [_muzzle]


# ------------------------------------------------------------------ view

func cockpit_node() -> Node3D:
	return eye


## Tribes plays in first person (the original's default view); chase on request. Riding in a vehicle the
## view starts outside (the seat nodes sit inside the hulls).
func prefers_chase_view() -> bool:
	return stowed


func aim_basis() -> Basis:
	return Basis(Vector3.UP, rotation.y) * Basis(Vector3.RIGHT, pitch)


func aim_origin() -> Vector3:
	return eye.global_position if eye else global_position


# ------------------------------------------------------------------ simulation

func _physics_process(delta: float) -> void:
	if is_puppet:
		_puppet_update(delta)
		return
	capacitor = minf(capacitor_max, capacitor + (capacitor_rate + InfantryPack.make_recharge_bonus(kit)) * delta)
	if alive:
		InfantryPack.apply_frame(self, delta)
	if stowed:
		InfantrySeat.apply_rider(self)
		return
	if not alive:
		_fall_dead(delta)
		return
	if has_meta("disabled_until") and Time.get_ticks_msec() < int(get_meta("disabled_until")):
		_hold_controls()
		jet_input = false
	_drive(delta)
	_animate(delta)


## Look, run, jump and jet (Tribes PlayerData movement; docs/formats/tribes_infantry.md section 3).
func _drive(delta: float) -> void:
	rotation.y = torso_target
	pitch = clampf(pitch_target, pitch_min, pitch_max)
	var wish := InfantryMotion.make_wish_direction(self)
	var on_floor := is_on_floor()
	if on_floor and not jump_input:
		InfantryMotion.apply_ground_movement(self, wish, delta)
	if on_floor and jump_input:
		velocity.y = maxf(velocity.y, 0.0) + float(armor.get("jump_speed", 8.3))
	jetting = jet_input and capacitor > float(armor.get("min_jet_energy", 1.0))
	if jetting:
		InfantryMotion.apply_jet(self, wish, delta)
	velocity.y = SOLDIER_FLOOR_SNAP if on_floor and not jetting and velocity.y <= 0.0 else velocity.y - TRIBES_GRAVITY * delta
	var before := velocity
	move_and_slide()
	InfantryMotion.apply_fall_damage(self, before)
	_apply_held_fall(delta)
	_apply_fell_through()
	speed = Vector3(velocity.x, 0.0, velocity.z).length()
	_sounds.apply_jet(self)


## Wedged where no floor holds it (see HELD_SPEED_SHARE): the velocity becomes the real one; wedged for
## HELD_DEATH_SECONDS inside the geometry: dead.
func _apply_held_fall(delta: float) -> void:
	var real := get_real_velocity()
	if is_on_floor() or velocity.y >= 0.0 or real.length() >= velocity.length() * HELD_SPEED_SHARE:
		_held_seconds = 0.0
		return
	velocity = real
	_held_seconds += delta
	if _held_seconds < HELD_DEATH_SECONDS:
		return
	_held_seconds = 0.0
	if is_inside_geometry():
		jetting = false
		_die_of(KillText.CAUSE_STUCK)
	# else: only resting in a crease of steep faces (a soldier who landed in a gully): he lives (PLAYTEST G2 -
	# such rests killed soldiers "by the environment" after 6 s)


## True when the soldier's body overlaps the world's static geometry (a spawn point inside an interior): stuck,
## not merely resting on faces too steep to stand on.
func is_inside_geometry() -> bool:
	if _collision == null or not (_collision.shape is CapsuleShape3D):
		return false
	var cap := (_collision.shape as CapsuleShape3D).duplicate() as CapsuleShape3D
	cap.radius = maxf(cap.radius - INSIDE_PROBE_SHRINK, 0.05)
	cap.height = maxf(cap.height - INSIDE_PROBE_SHRINK * 2.0, cap.radius * 2.0)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.transform = _collision.global_transform
	q.exclude = [get_rid()]
	for hit in get_world_3d().direct_space_state.intersect_shape(q, 4):
		if hit.collider is StaticBody3D:
			return true
	return false


func _apply_fell_through() -> void:
	var p := global_position
	if is_on_floor() or velocity.y >= 0.0:
		return
	if get_parent().get("bounds") != null:
		return   # the battle's BattleBounds knows the buildings below the terrain (underground bases)
	if p.y < MapBuilder.ground_height(get_parent() as Node3D, p) - FELL_THROUGH_DEPTH:
		jetting = false
		_die_of(KillText.CAUSE_BOUNDS)


## Dies of the world itself, the kill message naming `cause` (KillText).
func _die_of(cause: String) -> void:
	KillText.apply_cause(self, cause)
	_die(null)
	KillText.apply_cause(self, "")


## The look yaw the player may have: inside an armed seat's arc, else any.
func make_allowed_yaw(yaw: float) -> float:
	return seat.make_clamped_yaw(yaw) if stowed and seat != null and seat.is_armed() else yaw


## A blast's push (T2 kickBackStrength / mass): added to the velocity.
func apply_kick(push: Vector3) -> void:
	if alive and not stowed and not is_puppet:
		velocity += push


func _fall_dead(delta: float) -> void:
	_death_anim(delta)
	velocity.y -= TRIBES_GRAVITY * delta
	velocity.x = move_toward(velocity.x, 0.0, DEATH_FRICTION * delta)
	velocity.z = move_toward(velocity.z, 0.0, DEATH_FRICTION * delta)
	move_and_slide()


func _animate(delta: float) -> void:
	if eye:
		eye.rotation.x = pitch
	if stowed:
		return   # a rider holds his seat's pose (_process)
	if is_puppet:
		velocity = (global_position - _last_position) / maxf(delta, 0.001)
		_last_position = global_position
	var local := global_basis.inverse() * velocity
	var airborne := not is_on_floor() if not is_puppet else absf(velocity.y) > 1.0
	_animation.update(local, airborne, jetting, delta)
	_sounds.apply_steps(self, _animation, delta)
	held.update(current_weapon(), delta)


func _death_anim(delta: float) -> void:
	_death_t += delta
	_animation.apply_death(_death_t, make_death_choice())


## Which of the body's death animations this death plays: the same on every peer (net id and death count travel
## in the snapshots). The originals pick by where the killing hit struck (T1 Player::onDamage, T2
## Armor::damageObject); the remake does not track hit locations on soldiers.
func make_death_choice() -> int:
	return net_id + deaths


func _repair_model() -> void:
	shape.reset_pose()


## A killed soldier: its game's infantry death (DeathFx; Tribes / Tribes 2 play only the death animation).
func _explode() -> void:
	var size := Vector2(float(armor.get("capsule_radius", 0.6)), float(armor.get("height_m", 2.2)))
	DeathFx.play(get_parent(), DeathFx.make_body(self, armor_id, DeathFx.KIND_INFANTRY, size))


# ------------------------------------------------------------------ damage

## A soldier has no shields of its own: a worn shield pack takes the hit out of the energy first, the rest is
## scaled by the armour's damage scale of the hit's type ($DamageScale / damageScale[], DamageTypes.current)
## and comes off its health; dead at zero (Tribes maxDamage). A soldier inside a vehicle cannot be hit.
## A weapon hit (DamageModel): soldiers take it through their own armour rules (apply_hit), not a vehicle's.
func apply_weapon_hit(hit: Dictionary) -> void:
	apply_hit(float(hit.shield), float(hit.armor), hit.attacker, hit.pos)


func apply_hit(_shield_dmg: float, armor_dmg: float, attacker: Node = null, _hit_pos := Vector3.ZERO) -> void:
	if not alive or is_puppet or stowed or is_spawn_protected():
		return
	var type := DamageTypes.current
	var dmg := InfantryPack.apply_shield(self, armor_dmg, type) * DamageTypes.make_scale(armor.get("damage_scale", {}), type)
	var c: Dictionary = components[0]
	c.hp = maxf(0.0, float(c.hp) - dmg)
	integrity = HercDamage.integrity_of(components)
	damaged.emit(self, attacker)
	if c.hp <= 0.0:
		if lethal_hit_guard.is_valid() and bool(lethal_hit_guard.call(self, attacker)):
			return
		jetting = false
		_sounds.apply_jet(self)
		_die(attacker)


## Out-of-bounds damage (BattleBounds): `share` of the full health, no shield pack, no armour scale.
func apply_environment_damage(share: float, cause := KillText.CAUSE_BOUNDS) -> void:
	if not alive or is_puppet or stowed:
		return
	var c: Dictionary = components[0]
	c.hp = maxf(0.0, float(c.hp) - float(c.max) * share)
	integrity = HercDamage.integrity_of(components)
	damaged.emit(self, null)
	if c.hp <= 0.0:
		jetting = false
		_sounds.apply_jet(self)
		_die_of(cause)


## Respawns as a Tribes soldier does: in light armour (or the player's chosen spawn armour) with the spawn loadout (Game::playerSpawn /
## DefaultGame::equip).
func respawn(xf: Transform3D) -> void:
	var again := spawn_armor_id if spawn_armor_id != "" else InfantryCatalog.light_armor_id(str(armor.get("pack", "tribes")))
	if again != armor_id:
		_apply_armor_id(again)
		_rebuild_body()
	super.respawn(xf)
	kit.apply_spawn(armor)
	equip(armor.get("default_loadout", []))
	velocity = Vector3.ZERO
	torso_target = rotation.y


# ------------------------------------------------------------------ inside a vehicle

## Puts the soldier inside a vehicle in `p_seat` (`on`) or back in the world (`p_seat` null). Inside, he is out of
## collision and targeting; he shows on his seat where the original draws riders (InfantrySeat.shown), else he is
## hidden.
func apply_stowed(on: bool, p_seat: InfantrySeat = null) -> void:
	stowed = on
	seat = p_seat if on else null
	_apply_stowed_state()


## True while the soldier sits visibly in a vehicle (posed on his seat every frame, on every peer).
func is_seated_visibly() -> bool:
	return stowed and seat != null and seat.shown and is_instance_valid(seat.vehicle)


func _apply_stowed_state() -> void:
	visible = not stowed or is_seated_visibly()
	if is_seated_visibly():
		add_to_group(SEATED_RIDERS)
	elif is_in_group(SEATED_RIDERS):
		remove_from_group(SEATED_RIDERS)
	held.apply_world_shown(not stowed or seat == null or seat.weapon_shown)
	if not stowed:
		rotation.x = 0.0
		rotation.z = 0.0
	if _collision:
		_collision.disabled = stowed
	if stowed:
		remove_from_group("vehicles")
		jetting = false
		jet_input = false
		velocity = Vector3.ZERO
		for w in weapons:
			w.trigger = false
		_sounds.apply_jet(self)
	elif not is_in_group("vehicles"):
		add_to_group("vehicles")


## A seated rider follows his seat every rendered frame (after the vehicle moved: host and clients alike) and
## holds the seat's pose; the eye keeps the look pitch. Hidden riders just ride along with the vehicle.
func _process(delta: float) -> void:
	if not stowed or seat == null or not is_instance_valid(seat.vehicle):
		return
	apply_seat_transform()
	if is_seated_visibly() and alive:
		_animation.apply_hold(seat.pose, delta)
		held.update(current_weapon(), delta)


## Puts the body and its weapon on the player's own layer (BattleCameras.OWN_VEHICLE_LAYER): every first-person
## camera of this player (the vehicle's cockpit, his own eye) leaves it out, the chase camera draws it.
func apply_own_view_layer() -> void:
	for model in [shape, held.world_model]:
		if is_instance_valid(model):
			InfantryHeldWeapon.apply_layers(model, BattleCameras.OWN_VEHICLE_LAYER)


## The body's current sequence (a seat pose while riding visibly).
func make_pose_name() -> String:
	return _animation.make_current_name()


## Places the soldier on his seat (InfantrySeat.make_rider_transform); an armed passenger keeps his own yaw.
func apply_seat_transform() -> void:
	global_transform = seat.make_rider_transform(rotation.y)


# ------------------------------------------------------------------ networking

## Extra controls sent with BattleNetSync.make_controls (InfantryNet).
func make_extra_controls() -> Array:
	return InfantryNet.make_controls(self)


func apply_extra_controls(c: Array) -> void:
	InfantryNet.apply_controls(self, c)


## Extra snapshot state, appended after the damage block (InfantryNet).
func make_snapshot_extra() -> Array:
	return InfantryNet.make_snapshot(self)


func apply_snapshot(s: Array, dt: float) -> void:
	super.apply_snapshot(s, dt)
	if s.size() <= SNAP_INFANTRY or not (s[SNAP_INFANTRY] is Array):
		return
	InfantryNet.apply_snapshot(self, s[SNAP_INFANTRY])
	_sounds.apply_jet(self)


## A client's own soldier looks where its player looks at once (the host's pose follows a moment later).
func _puppet_update(delta: float) -> void:
	super._puppet_update(delta)
	if is_local_player():
		rotation.y = make_allowed_yaw(torso_target)
		pitch = clampf(pitch_target, pitch_min, pitch_max)
		if eye:
			eye.rotation.x = pitch
