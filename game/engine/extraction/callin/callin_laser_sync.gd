class_name CallinLaserSync
extends RefCounted
## Teammates see each other's laser dot. The painter sends where his laser is (about ten times a second, unreliable) to the host,
## the host passes it on to the raid players of the painter's side, and each of them shows a dot (CallinLaserDot) with the painter's
## name until it is turned off or stops coming. Visual only: the host does not keep what it relays.

const SEND_SECONDS := 0.1
## A dot that was not refreshed for this long is gone (the painter left, a message was lost).
const STALE_MSEC := 1500

var callins: CallinDirector
## Every peer: painter peer -> {dot: CallinLaserDot, seen: msec}.
var dots := {}
var _clock := MissionClock.new()


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


# ------------------------------------------------------------------ the painter

## True when a paint message is due (about every SEND_SECONDS).
func is_send_due(delta: float) -> bool:
	return _clock.make_step(delta, SEND_SECONDS) > 0.0


## The local player tells his team where his laser is (`on` false: it is lowered).
func send_paint(on: bool, point: Vector3, ok: bool) -> void:
	if callins.multiplayer.is_server():
		apply_relay(callins.multiplayer.get_unique_id(), on, point, ok)
	else:
		callins.rpc_id(1, "_laser_paint", on, point, ok)


# ------------------------------------------------------------------ the host

## Host: `painter`'s dot goes to the raid players on his side (never back to him).
func apply_relay(painter: int, on: bool, point: Vector3, ok: bool) -> void:
	var soldier := callins.battle.occupancy.soldier_of(painter)
	if soldier == null or not callins.director.is_in_raid(painter):
		return
	for peer in callins.director.make_raid_peers():
		var other := callins.battle.occupancy.soldier_of(int(peer))
		if int(peer) != painter and other != null and TeamRelations.is_allied(other.team, soldier.team):
			callins.telling.send_to(int(peer), callins, "_laser_seen", [painter, on, point, ok])


# ------------------------------------------------------------------ the teammates

## Every peer told: shows (or removes) the dot of teammate `painter`.
func apply_seen(painter: int, on: bool, point: Vector3, ok: bool) -> void:
	if not on:
		apply_forget(painter)
		return
	if painter == callins.multiplayer.get_unique_id() or ServerProfile.is_collision_only():
		return
	if not dots.has(painter) or not is_instance_valid(dots[painter].dot):
		var dot := CallinLaserDot.new()
		dot.name = "TeammateLaser%d" % painter
		callins.battle.add_child(dot)
		dots[painter] = {"dot": dot, "seen": 0}
	dots[painter].seen = Time.get_ticks_msec()
	(dots[painter].dot as CallinLaserDot).apply_paint(point, ok, _make_name(painter))


func apply_forget(painter: int) -> void:
	if dots.has(painter):
		if is_instance_valid(dots[painter].dot):
			(dots[painter].dot as Node).queue_free()
		dots.erase(painter)


## Drops the dots that stopped coming.
func apply_forget_stale() -> void:
	var now := Time.get_ticks_msec()
	for painter in dots.keys():
		if now - int(dots[painter].seen) > STALE_MSEC:
			apply_forget(int(painter))


func _make_name(painter: int) -> String:
	var soldier := callins.battle.occupancy.soldier_of(painter)
	var shown = soldier.get("display_name") if soldier != null else null
	return str(shown) if shown != null else ""
