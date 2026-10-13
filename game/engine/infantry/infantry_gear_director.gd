class_name InfantryGearDirector
extends Node
## Soldiers' hand items and backpacks in a battle (child "Gear" of the Battle; docs/formats/tribes_infantry.md
## section 6). Host-authoritative over the LAN, like the OccupancyDirector:
##   * the local player holds and releases grenade_throw / mine_drop (the hold sets the throw strength, as the
##     originals' throwStart / throwRelease and startThrowCount / endThrowCount), presses pack_use (switch the
##     pack on / off, Backpack::onUse) and repair_kit_use (RepairKit::onUse); each goes to the host;
##   * the host checks the kit, takes the item and throws it (ThrownItem) on every peer; its burst is the
##     host's, the clients' copies only show it;
##   * bots call the same apply_* functions with their bot id.
## The kit's counts and the pack's state reach clients in the soldiers' snapshots (Infantry.make_snapshot_extra).

const NODE_NAME := "Gear"
const SLOT_GRENADE := "grenade"
const SLOT_MINE := "mine"
const THROW_ACTIONS := {"grenade_throw": SLOT_GRENADE, "mine_drop": SLOT_MINE}
## Where a throw starts: this far ahead of the eye (T2 getBoxCenter of the thrower; T1 engine-side).
const THROW_AHEAD := 0.6
const MSEC := 1000.0

var battle: Battle
## func(peer: int, soldier: Infantry) -> void: host, pack_use with no pack to switch (a mode's reload).
var reload_hook := Callable()
var _hold_started := {}         # action -> ticks msec of the press
var _items := {}                # item net id -> ThrownItem (every peer)
var _next_item_id := 1


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = NODE_NAME


# ------------------------------------------------------------------ local input

func _unhandled_input(event: InputEvent) -> void:
	if battle.is_over() or not (battle.player is Infantry):
		return
	for action in THROW_ACTIONS:
		if event.is_action_pressed(action):
			_hold_started[action] = Time.get_ticks_msec()
		elif event.is_action_released(action) and _hold_started.has(action):
			var held := (Time.get_ticks_msec() - int(_hold_started[action])) / MSEC
			_hold_started.erase(action)
			request_throw(THROW_ACTIONS[action], held)
	if event.is_action_pressed("pack_use"):
		request_pack()
	elif event.is_action_pressed("repair_kit_use"):
		request_repair_kit()


func request_throw(slot: String, held_s: float) -> void:
	if multiplayer.is_server():
		apply_throw(multiplayer.get_unique_id(), slot, held_s)
	else:
		_request_throw.rpc_id(1, slot, held_s)


@rpc("any_peer", "reliable")
func _request_throw(slot: String, held_s: float) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_throw(multiplayer.get_remote_sender_id(), slot, held_s)


func request_pack() -> void:
	if multiplayer.is_server():
		apply_pack_toggle(multiplayer.get_unique_id())
	else:
		_request_pack.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_pack() -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_pack_toggle(multiplayer.get_remote_sender_id())


func request_repair_kit() -> void:
	if multiplayer.is_server():
		apply_repair_kit(multiplayer.get_unique_id())
	else:
		_request_repair_kit.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_repair_kit() -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_repair_kit(multiplayer.get_remote_sender_id())


# ------------------------------------------------------------------ host: rules

## Host: `peer`'s soldier throws his grenade (slot "grenade") or a mine (slot "mine"), key held `held_s`.
func apply_throw(peer: int, slot: String, held_s: float) -> void:
	var s := battle.occupancy.soldier_of(peer)
	if s == null or not s.alive or (s.stowed and not (s.seat != null and s.seat.is_armed())):
		return
	var id := s.kit.grenade_id if slot == SLOT_GRENADE else InfantryKit.make_mine_id(s.armor)
	var now := Time.get_ticks_msec()
	if id == "" or s.kit.count(id) <= 0 or not s.kit.is_throw_ready(now):
		return
	var pack_name := str(s.armor.get("pack", "tribes"))
	var rules := InfantryGear.throw_rules(pack_name)
	s.kit.apply_take(id)
	s.kit.apply_throw_timeout(now, float(rules.get("timeout_s", 0.5)))
	var dir := -s.aim_basis().z
	var from := s.aim_origin() + dir * THROW_AHEAD
	var vel := make_throw_velocity(InfantryGear.item(id), rules, s, held_s)
	var net := _next_item_id
	_next_item_id += 1
	if Net.is_online():
		_spawn_item.rpc(net, id, from, vel, s.net_id)
	else:
		_spawn_item(net, id, from, vel, s.net_id)


## The launch velocity of `record` thrown by `s` after holding the key `held_s` seconds:
##   Tribes 1 (GameBase::throw): throw_speed x (min + span x the hold, up to hold_max_s), plus the
##     thrower's velocity (engine-side; assumed);
##   Tribes 2 (HandInventory::onUse): impulse = eye x strength x per_strength + up x lift x (1 - |eye.z|)
##     + the thrower's velocity x inherit, over the item's mass; strength = hold / hold_ms_per_strength
##     within [strength_min, strength_max], divided by strength_divisor.
static func make_throw_velocity(record: Dictionary, rules: Dictionary, s: Infantry, held_s: float) -> Vector3:
	var eye := -s.aim_basis().z
	if rules.has("per_strength"):
		var strength := clampf(held_s * MSEC / float(rules.hold_ms_per_strength), float(rules.strength_min),
			float(rules.strength_max)) / float(rules.strength_divisor)
		var impulse: Vector3 = eye * strength * float(rules.per_strength) \
			+ Vector3.UP * float(rules.lift) * (1.0 - absf(eye.y)) + s.velocity * float(rules.inherit)
		return impulse / maxf(float(record.get("mass", 1.0)), 0.01)
	var hold := clampf(held_s / maxf(float(rules.get("hold_max_s", 1.0)), 0.01), 0.0, 1.0)
	var strength := float(rules.get("min", 0.3)) + float(rules.get("span", 0.7)) * hold
	return eye * float(record.get("throw_speed", 10.0)) * strength + s.velocity


## Host: a deploy pack places its object (TribesDeployables). Otherwise `peer` switches his toggled pack on or off
## (on only with the pack's min_energy). A pack that is not
## toggled (energy, ammo; or none) has nothing to switch: pack_use then asks for a reload instead (the
## reload_hook, e.g. the extraction mode loading rounds from the carried inventory; the originals have no reload).
func apply_pack_toggle(peer: int) -> void:
	var s := battle.occupancy.soldier_of(peer)
	if s == null or not s.alive:
		return
	var deployables := TribesDeployables.of(battle)
	if deployables and TribesDeployables.is_deploy_pack(s.kit.pack_id):
		deployables.apply_deploy(peer, s)      # Tribes: using a deploy pack places it (agent H)
		return
	if not s.kit.is_pack_toggled():
		if reload_hook.is_valid():
			reload_hook.call(peer, s)
		return
	var need := float(InfantryGear.pack(s.kit.pack_id).get("min_energy", 0.0))
	s.kit.pack_active = not s.kit.pack_active and s.capacitor >= need


## Host: `peer` uses a repair kit when he is hurt (T2 RepairKit::onUse; the remake applies that rule to Tribes 1 too).
func apply_repair_kit(peer: int) -> void:
	var s := battle.occupancy.soldier_of(peer)
	var id := InfantryKit.make_repair_kit_id(s.armor) if s else ""
	if id == "" or not s.alive or s.kit.count(id) <= 0 or s.integrity >= 1.0:
		return
	s.kit.apply_take(id)
	InfantryPack.apply_repair(s, float(InfantryGear.item(id).get("repair", 0.0)))


# ------------------------------------------------------------------ every peer: thrown items

@rpc("authority", "reliable", "call_local")
func _spawn_item(net: int, id: String, from: Vector3, vel: Vector3, thrower_id: int) -> void:
	var t := ThrownItem.new()
	t.item = InfantryGear.item(id)
	t.item_net_id = net
	t.velocity = vel
	t.thrower = battle.vehicles.get(thrower_id) as Herc
	t.visual_only = not multiplayer.is_server()
	t.name = "Thrown%d" % net
	battle.add_child(t)
	t.global_position = from
	_items[net] = t
	if multiplayer.is_server():
		t.burst.connect(_on_burst)


func _on_burst(t: ThrownItem) -> void:
	_items.erase(t.item_net_id)
	if Net.is_online():
		_show_burst.rpc(t.item_net_id, str(t.item.id), t.global_position)
	else:
		_show_burst(t.item_net_id, str(t.item.id), t.global_position)


@rpc("authority", "reliable", "call_local")
func _show_burst(net: int, id: String, pos: Vector3) -> void:
	var copy = _items.get(net)
	_items.erase(net)
	if is_instance_valid(copy) and copy.visual_only:
		copy.queue_free()
	ThrownItem.play_burst(battle, InfantryGear.item(id), pos)


## Thrown items in flight or lying (tests).
func make_items() -> Array:
	return _items.values().filter(func(t) -> bool: return is_instance_valid(t))
