class_name RaidWatch
extends Node
## What a test client reports about the raid it plays in (tests/dedicated_client.gd, tests/party_client.gd), as lines through `say`:
## LANDED (its soldier rode a transport and got out), TEAM <team> RIDERS <names in its transport>, SEES <name:team,...> (every few
## seconds, the pilots' soldiers it knows), RESULT extracted|dead, RESULTS <headline> (the results screen is up).
##   var watch := RaidWatch.new(battle, say); add_child(watch); await watch.run()

const LAND_SECONDS := 300.0
const RAID_SECONDS := 600.0
const SEES_SECONDS := 3.0
const POLL_SECONDS := 0.2
const SETTLE_SECONDS := 2.0
const RESULT_SCREEN_SECONDS := 60.0

var battle: Battle
var say: Callable
var _riders: Array = []
var _seen_seat := false


func _init(p_battle: Battle, p_say: Callable) -> void:
	battle = p_battle
	say = p_say


## Reports until the results screen is up. Returns the MatchResults (null if it never came).
func run() -> MatchResults:
	var x := battle.extraction
	var landed := await _wait_for(_has_landed, LAND_SECONDS)
	say.call("LANDED" if landed else "FAILED never landed")
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	var me := battle.player as Infantry
	say.call("TEAM %d RIDERS %s" % [me.team if me != null else -1, ",".join(PackedStringArray(_riders))])
	var waited := 0.0
	var next_report := 0.0
	var status := x.my_status
	while status == ExtractionDirector.STATUS_IN_RAID and waited < RAID_SECONDS and is_instance_valid(x):
		if waited >= next_report:
			say.call("SEES %s" % _make_seen_text())
			next_report += SEES_SECONDS
		await get_tree().create_timer(POLL_SECONDS).timeout
		waited += POLL_SECONDS
		status = x.my_status if is_instance_valid(x) else status   # the results screen frees the battle a moment after the result
	say.call("RESULT %s" % status)
	await _wait_for(func() -> bool: return get_tree().current_scene is MatchResults, RESULT_SCREEN_SECONDS)
	var results := get_tree().current_scene as MatchResults
	say.call("RESULTS %s" % (str(results.summary.get("headline", "")) if results != null else "none"))
	return results


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


## True once this client's soldier rode in a transport and got out (members, not locals: a lambda keeps its own copy).
func _has_landed() -> bool:
	var me := battle.player as Infantry
	if me == null:
		return false
	if me.stowed:
		_seen_seat = true
		for rider in _make_riders(me):   # everybody seen aboard: the others get out one by one when it lands
			if not _riders.has(rider):
				_riders.append(rider)
		_riders.sort()
	return _seen_seat and not me.stowed


## "name:team,name:team" of the pilots' soldiers this client knows.
func _make_seen_text() -> String:
	var out := []
	for h in battle.vehicles.values():
		if is_instance_valid(h) and h is Infantry and not h.has_meta("bot_id") and h.owner_peer > 0:
			out.append("%s:%d" % [h.display_name, h.team])
	out.sort()
	return ",".join(PackedStringArray(out))


## The names of the pilots sitting in the vehicle of `me` (what the transport carries), sorted.
func _make_riders(me: Infantry) -> Array:
	var out := []
	if me.seat == null or not is_instance_valid(me.seat.vehicle):
		return out
	for peer in VehicleOccupancy.of(me.seat.vehicle).make_occupants():
		var soldier := battle.occupancy.soldier_of(int(peer))
		if soldier != null:
			out.append(soldier.display_name)
	out.sort()
	return out
