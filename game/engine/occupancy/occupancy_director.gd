class_name OccupancyDirector
extends Node
## Boarding, leaving and changing seats in a battle (child "Occupancy" of the Battle). Host-authoritative over
## the LAN:
##   * a player presses vehicle_enter_exit: the request goes to the host, which boards the nearest vehicle the
##     player's soldier may take through the hatch (BoardingRules HATCH family) or lets the player out of the
##     vehicle he is in (every family);
##   * in a Tribes / Tribes 2 vehicle the jump key (ascend) gets out too, as the originals' jump trigger does
##     (T1 Vehicle::jump / passengerJump, T2 Armor::doDismount);
##   * seat_next moves him to the next free seat his armour may take (remake addition; BoardingRules);
##   * Tribes / Tribes 2 vehicles are boarded by touching them (host, every physics frame);
##   * a destroyed vehicle throws its riders out (Tribes Vehicle::onDestroyed);
##   * each change goes to every peer as one reliable state message (_apply_state): seats, the soldier's
##     visibility, place and seat, who controls what (pilot: the vehicle; gunner: its TurretCrew; passenger:
##     his own soldier), the vehicle's team (the pilot's, T2 Armor::onMount) - and on the player's own machine
##     the controls and the view move to the new body (Battle.switch_control).
## A soldier inside a vehicle rides at his seat. The kills a piloted vehicle scores count for its pilot's soldier.
## Occupants are player peers or bot ids (InfantryBots, negative); registry: soldiers by peer / bot id (a player
## in a mission starts inside his vehicle without one: it is made when he first gets out, BattleInfantry).

## A seat changed hands (every peer, after the state message): bots attach or release vehicle brains.
signal seats_changed(vehicle: Herc)
## Host: `peer` asked to get out and exit_guard refused it for `reason` (a mode shows it to him).
signal exit_refused(peer: int, reason: String)

## Time before a soldier who left a vehicle boards that same vehicle by touch again (Tribes 1 newMountTime
## 3 s, only for the vehicle he left - `lastMount != %this` lets him take another at once; Tribes 2
## setMountVehicle after 4 s): the remake uses the Tribes 2 time with the Tribes 1 same-vehicle rule.
const REMOUNT_DELAY_MS := 4000
const MOUNT_SOUND_DB := -4.0
## One press boards or leaves once: a second request from the same peer this soon after is ignored.
const TOGGLE_DEBOUNCE_MS := 100

var battle: Battle
## Host: func(peer: int, vehicle: Herc) -> String: "" = he may get out, else why not (the extraction raid's safe
## drop, ExitSafety); unset = always.
var exit_guard := Callable()
var _soldier_of_peer := {}       # peer / bot id -> soldier net id
var _remount_after_ms := {}      # soldier net id -> [vehicle net id, ticks msec]
var _last_toggle_ms := {}        # peer id -> ticks msec of the last enter / exit request


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "Occupancy"


# ------------------------------------------------------------------ registry (every peer)

## A vehicle or soldier was built from `spec` (Battle._spawn): seats, ownership, the host's death watch.
func register(h: Herc, spec: Dictionary) -> void:
	if h is Infantry:
		_soldier_of_peer[int(spec.owner)] = h.net_id
		return
	var occ := VehicleOccupancy.of(h)
	if (spec.get("ai", {}) as Dictionary).has("skill"):
		occ.apply_seat(VehicleOccupancy.PILOT_SEAT, VehicleOccupancy.AI_PILOT)
	elif spec.has("pilot_peer"):
		occ.apply_seat(VehicleOccupancy.PILOT_SEAT, int(spec.pilot_peer))
	if VehicleSeats.make_gunner_seat(h.vehicle_id) >= 0:
		TurretCrew.of(h)
	if multiplayer.is_server():
		h.destroyed.connect(_on_vehicle_destroyed)


## The soldier of `peer` (null when he has none yet, or it is gone).
func soldier_of(peer: int) -> Infantry:
	var s = battle.vehicles.get(int(_soldier_of_peer.get(peer, -1)))
	return s as Infantry if is_instance_valid(s) else null


## The vehicle `peer` sits in (null when on foot).
func vehicle_of(peer: int) -> Herc:
	for h in battle.vehicles.values():
		if is_instance_valid(h) and not (h is Infantry) and VehicleOccupancy.of(h).seat_of(peer) >= 0:
			return h
	return null


func set_soldier_of(peer: int, net_id: int) -> void:
	_soldier_of_peer[peer] = net_id


## Every peer / bot id with a soldier.
func make_occupant_ids() -> Array:
	return _soldier_of_peer.keys()


# ------------------------------------------------------------------ local input

func _unhandled_input(event: InputEvent) -> void:
	if battle.is_over():
		return
	if event.is_action_pressed("vehicle_enter_exit") and _is_enter_exit_mine(event):
		request_enter_exit()
	elif event.is_action_pressed("seat_next"):
		request_seat_change()
	elif event.is_action_pressed("ascend") and _is_in_tribes_vehicle(multiplayer.get_unique_id()):
		request_jump_out()


## On foot the same key as interact (E) boards through InfantryInteraction (the nearest thing in reach), so
## only a control of vehicle_enter_exit alone (pad B) boards from here; inside, every one of them gets out.
func _is_enter_exit_mine(event: InputEvent) -> bool:
	return vehicle_of(multiplayer.get_unique_id()) != null or not event.is_action("interact")


## Interact offer (InfantryInteraction provider): the vehicle whose hatch is in reach and may be boarded.
func make_boarding_offer(soldier: Infantry) -> Dictionary:
	var choice := make_hatch_choice(soldier)
	if choice.is_empty() or not bool(choice.check.ok):
		return {}
	return {"distance": soldier.global_position.distance_to((choice.vehicle as Herc).global_position),
		"text": "enter the %s" % str((choice.vehicle as Herc).def.get("name", "vehicle")), "apply": request_enter_exit}


## True when `peer` may get out of his vehicle: he has a soldier, or the battle can make one (an infantry pack
## is installed). Without Tribes there are no soldiers: pilots stay in their vehicles (PLAYTEST C5).
func can_leave_vehicle(peer: int) -> bool:
	return soldier_of(peer) != null or battle.infantry == null or battle.infantry.pack != ""


func _is_in_tribes_vehicle(peer: int) -> bool:
	var v := vehicle_of(peer)
	return v != null and BoardingRules.is_boarded_by_touch(v.def)


## Asks the host to board a vehicle / leave the vehicle for the local player.
func request_enter_exit() -> void:
	if multiplayer.is_server():
		apply_enter_exit(multiplayer.get_unique_id())
	else:
		_request_enter_exit.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_enter_exit() -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_enter_exit(multiplayer.get_remote_sender_id())


func request_jump_out() -> void:
	if multiplayer.is_server():
		apply_jump_out(multiplayer.get_unique_id())
	else:
		_request_jump_out.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_jump_out() -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_jump_out(multiplayer.get_remote_sender_id())


func request_seat_change() -> void:
	if multiplayer.is_server():
		apply_seat_change(multiplayer.get_unique_id())
	else:
		_request_seat_change.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_seat_change() -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_seat_change(multiplayer.get_remote_sender_id())


# ------------------------------------------------------------------ host: rules

## Host: `peer` pressed vehicle_enter_exit.
func apply_enter_exit(peer: int) -> void:
	var now := Time.get_ticks_msec()
	if now - int(_last_toggle_ms.get(peer, -TOGGLE_DEBOUNCE_MS)) < TOGGLE_DEBOUNCE_MS:
		return
	var inside := vehicle_of(peer)
	if inside:
		if not can_leave_vehicle(peer):
			return
		var why := str(exit_guard.call(peer, inside)) if exit_guard.is_valid() else ""
		if why != "":
			exit_refused.emit(peer, why)
			return
		_last_toggle_ms[peer] = now
		apply_exit(peer, inside)
		return
	var soldier := soldier_of(peer)
	var choice := make_hatch_choice(soldier) if soldier else {}
	if not choice.is_empty() and bool(choice.check.ok):
		_last_toggle_ms[peer] = now
		apply_board(peer, choice.vehicle, int(choice.check.seat))


## Host: `peer` pressed the jump key inside a vehicle: out of a Tribes vehicle (the others keep the key for
## their own controls).
func apply_jump_out(peer: int) -> void:
	if _is_in_tribes_vehicle(peer):
		apply_enter_exit(peer)


## Host: `peer` moves to the next free seat (in seat order, wrapping) his armour may take; nothing when none.
func apply_seat_change(peer: int) -> void:
	var vehicle := vehicle_of(peer)
	var soldier := soldier_of(peer)
	if vehicle == null or soldier == null:
		return
	var occ := VehicleOccupancy.of(vehicle)
	var seat := make_next_seat(soldier, vehicle, occ.seat_of(peer))
	if seat < 0:
		return
	occ.apply_leave(peer)
	occ.apply_seat(seat, peer)
	_send_state(vehicle, soldier, true, soldier.global_transform, peer)


## The next free seat after `from` that `soldier` may take in `vehicle` (-1 when none).
static func make_next_seat(soldier: Infantry, vehicle: Herc, from: int) -> int:
	var occ := VehicleOccupancy.of(vehicle)
	var n := occ.seats.size()
	for k in range(1, n):
		var seat := (from + k) % n
		if occ.is_seat_free(seat) and BoardingRules.is_seat_allowed(soldier, vehicle, seat):
			return seat
	return -1


## The nearest non-Tribes vehicle within hatch reach of `soldier` and the rules' answer for it:
## {vehicle, check} ({} when no vehicle is within reach).
func make_hatch_choice(soldier: Infantry) -> Dictionary:
	var best := {}
	var best_d := INF
	for h in battle.vehicles.values():
		if not is_instance_valid(h) or h is Infantry or BoardingRules.is_boarded_by_touch(h.def):
			continue
		if not h.alive or not BoardingRules.is_within_hatch_reach(soldier, h):
			continue
		var d: float = soldier.global_position.distance_to(h.global_position)
		if d < best_d:
			best_d = d
			best = {"vehicle": h, "check": BoardingRules.make_check(soldier, h, VehicleOccupancy.of(h))}
	return best


## Host: `peer`'s soldier takes `seat` of `vehicle`.
func apply_board(peer: int, vehicle: Herc, seat: int) -> void:
	var soldier := soldier_of(peer)
	if soldier == null:
		push_error("OccupancyDirector: peer %d has no soldier to board with" % peer)
		return
	var occ := VehicleOccupancy.of(vehicle)
	occ.apply_seat(seat, peer)
	_send_state(vehicle, soldier, true, soldier.global_transform, peer)


## Host: `peer` leaves `vehicle` next to its hull (a soldier is made for him if he has none yet).
func apply_exit(peer: int, vehicle: Herc) -> void:
	var xf := VehicleExit.make_transform(battle, vehicle)
	var soldier := soldier_of(peer)
	if soldier == null:
		soldier = battle.spawn_soldier_for(peer, vehicle.team, battle.make_pilot_name(peer), xf)
	VehicleOccupancy.of(vehicle).apply_leave(peer)
	_remount_after_ms[soldier.net_id] = [vehicle.net_id, Time.get_ticks_msec() + REMOUNT_DELAY_MS]
	_send_state(vehicle, soldier, false, xf, peer)


func _physics_process(_delta: float) -> void:
	if not multiplayer.is_server() or battle.is_over():
		return
	_carry_riders()
	_board_by_touch()


## Soldiers inside vehicles ride along at their seats (Infantry.apply_seat_transform: the seat node, else the
## vehicle's origin for vehicles without seat nodes), so the host's physics sees them there.
func _carry_riders() -> void:
	for peer in _soldier_of_peer:
		var s := soldier_of(int(peer))
		if s != null and s.stowed and s.seat != null and is_instance_valid(s.seat.vehicle):
			s.apply_seat_transform()


## Tribes vehicles: a soldier on foot who touches one boards it (Vehicle::onCollision / Armor::onCollision).
func _board_by_touch() -> void:
	for peer in _soldier_of_peer:
		var s := soldier_of(int(peer))
		if s == null or s.stowed or not s.alive:
			continue
		for h in battle.vehicles.values():
			if not is_instance_valid(h) or h is Infantry or not BoardingRules.is_boarded_by_touch(h.def):
				continue
			if is_remount_blocked(s, h):
				continue
			var check := BoardingRules.make_check(s, h, VehicleOccupancy.of(h))
			if bool(check.ok):
				apply_board(int(peer), h, int(check.seat))
				break


## True while `soldier` may not board `vehicle` by touch again (he just left it).
func is_remount_blocked(soldier: Infantry, vehicle: Herc) -> bool:
	var r: Array = _remount_after_ms.get(soldier.net_id, [])
	return not r.is_empty() and int(r[0]) == vehicle.net_id and Time.get_ticks_msec() < int(r[1])


## Host: a vehicle was destroyed: its riders get out (Tribes Vehicle::onDestroyed); a kill scored by a piloted
## vehicle counts for the pilot's soldier.
func _on_vehicle_destroyed(h: Herc, killer: Node) -> void:
	for peer in VehicleOccupancy.of(h).make_occupants():
		apply_exit(peer, h)
	_credit_pilot(killer, h)


func _credit_pilot(killer: Node, victim: Herc) -> void:
	if not (killer is Herc) or killer is Infantry or killer == victim:
		return
	var pilot := VehicleOccupancy.of(killer).pilot()
	var soldier := soldier_of(pilot) if pilot != VehicleOccupancy.EMPTY and pilot != VehicleOccupancy.AI_PILOT else null
	if soldier == null:
		return
	(killer as Herc).kills -= 1
	soldier.kills += 1
	if BattleRules.uses_frag_limit(battle.config) and soldier.kills >= BattleRules.frag_limit(battle.config):
		battle.end_match("%s wins the match!" % soldier.display_name, {}, soldier.display_name)


## Host: gunner input from a client (BattleNetSync): the vehicle whose gunner `sender` is takes it.
## Returns whether `sender` is a gunner.
func apply_crew_controls(sender: int, controls: Dictionary) -> bool:
	for h in battle.vehicles.values():
		var crew := TurretCrew.find(h) if is_instance_valid(h) else null
		if crew and crew.gunner == sender:
			crew.apply_controls(controls)
			return true
	return false


# ------------------------------------------------------------------ every peer: the state message

func _send_state(vehicle: Herc, soldier: Infantry, stowed: bool, xf: Transform3D, peer: int) -> void:
	var seats := VehicleOccupancy.of(vehicle).seats.duplicate()
	if Net.is_online():
		_apply_state.rpc(vehicle.net_id, seats, soldier.net_id, stowed, xf, peer)
	else:
		_apply_state(vehicle.net_id, seats, soldier.net_id, stowed, xf, peer)


@rpc("authority", "reliable", "call_local")
func _apply_state(vehicle_id: int, seats: Array, soldier_id: int, stowed: bool, xf: Transform3D, peer: int) -> void:
	var vehicle: Herc = battle.vehicles.get(vehicle_id)
	var soldier := battle.vehicles.get(soldier_id) as Infantry
	if not is_instance_valid(vehicle) or soldier == null:
		push_error("OccupancyDirector: state for missing vehicle %d / soldier %d" % [vehicle_id, soldier_id])
		return
	_soldier_of_peer[peer] = soldier_id
	var occ := VehicleOccupancy.of(vehicle)
	var was_aboard := soldier.stowed
	occ.apply_seats(seats)
	if not stowed:
		soldier.global_transform = xf
		soldier.torso_target = soldier.rotation.y
	soldier.apply_stowed(stowed, InfantrySeat.make(vehicle, occ.seat_of(peer)) if stowed else null)
	_apply_pilot_team(vehicle, soldier, peer)
	_apply_ownership(vehicle, soldier, peer, stowed)
	_apply_gunner(vehicle)
	if stowed != was_aboard:
		_play_mount_sound(soldier, vehicle, stowed)
	if peer == multiplayer.get_unique_id():
		_apply_local_control(_controlled_body(vehicle, soldier, peer, stowed))
		if stowed:
			soldier.apply_own_view_layer()   # after the camera switch: his seated body never blocks his view
	seats_changed.emit(vehicle)


## The pilot takes the vehicle to his team (T2 Armor::onMount: setTargetSensorGroup to the pilot's).
static func _apply_pilot_team(vehicle: Herc, soldier: Infantry, peer: int) -> void:
	if VehicleOccupancy.of(vehicle).pilot() != peer or vehicle.team == soldier.team:
		return
	vehicle.remove_from_group("team_%d" % vehicle.team)
	vehicle.team = soldier.team
	vehicle.add_to_group("team_%d" % vehicle.team)


## Input from `peer` drives the vehicle while he pilots it (BattleNetSync routes by owner_peer), the turret
## while he guns it (apply_crew_controls), else his soldier (on foot, or a passenger firing from his seat).
func _apply_ownership(vehicle: Herc, soldier: Infantry, peer: int, stowed: bool) -> void:
	var occ := VehicleOccupancy.of(vehicle)
	var role := VehicleSeats.make_role(vehicle.vehicle_id, occ.seat_of(peer)) if stowed else ""
	var piloting := stowed and occ.pilot() == peer
	soldier.owner_peer = VehicleOccupancy.EMPTY if role in [VehicleSeats.PILOT, VehicleSeats.GUNNER] else peer
	if piloting:
		vehicle.owner_peer = peer
	elif vehicle.owner_peer == peer:
		vehicle.owner_peer = VehicleOccupancy.EMPTY
		_apply_idle(vehicle)


## The gunner seat's occupant works the turret (nobody: the pilot fires, TurretCrew idle).
static func _apply_gunner(vehicle: Herc) -> void:
	var seat := VehicleSeats.make_gunner_seat(vehicle.vehicle_id)
	if seat < 0:
		return
	var crew := TurretCrew.of(vehicle)
	crew.gunner = VehicleOccupancy.of(vehicle).seats[seat]
	crew.apply_idle()


## What `peer` controls after the change: the vehicle he pilots or guns, else his soldier (a passenger looks
## out of his seat; an armed one fires his own weapons).
static func _controlled_body(vehicle: Herc, soldier: Infantry, peer: int, stowed: bool) -> Herc:
	if not stowed:
		return soldier
	var role := VehicleSeats.make_role(vehicle.vehicle_id, VehicleOccupancy.of(vehicle).seat_of(peer))
	return vehicle if role in [VehicleSeats.PILOT, VehicleSeats.GUNNER] else soldier


## The local player's controls move to `body`; the same body in a new seat gets new controls.
func _apply_local_control(body: Herc) -> void:
	if body == battle.player:
		battle.refresh_player_view()
	else:
		battle.switch_control(body)


## The controls for the local player's body `h`: on foot or a passenger his soldier's, a gunner the turret's,
## else the vehicle's (Battle._attach_player).
func make_pilot_for(h: Herc) -> PlayerPilot:
	if h is Infantry:
		return InfantryPilot.make_for_soldier(h as Infantry)
	var crew := TurretCrew.find(h)
	if crew and crew.gunner == multiplayer.get_unique_id():
		return GunnerPilot.make_for_gunner(h)
	return PlayerPilot.make_for(h)


## An empty vehicle stops where it is: no throttle, no fire.
static func _apply_idle(vehicle: Herc) -> void:
	vehicle.throttle = 0.0
	vehicle.turn = 0.0
	for w in vehicle.weapons:
		w.trigger = false
	if vehicle is Flyer:
		(vehicle as Flyer).apply_controls(FlightControls.make(0.0, 0.0, Vector2.ZERO, 0.0))


func _play_mount_sound(soldier: Infantry, vehicle: Herc, stowed: bool) -> void:
	var stem := str(soldier.armor.get("sounds", {}).get("mount" if stowed else "dismount", ""))
	if stem != "":
		Sfx.play_at(stem, vehicle.global_position, MOUNT_SOUND_DB)


# ------------------------------------------------------------------ HUD hint

## The hint for the local player's soldier: what vehicle_enter_exit or touching would do here (OccupancyHint).
func make_local_hint() -> String:
	return OccupancyHint.make_local(self)
