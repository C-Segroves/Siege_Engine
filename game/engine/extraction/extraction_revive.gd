class_name ExtractionRevive
extends Node
## Downed and revive in an extraction raid (docs/design/extraction.md section 4; child "Revive" of the
## ExtractionDirector on every peer). Host-authoritative:
##   down      a player's soldier that takes a lethal hit while a teammate (same or allied team, in the raid, on his
##             feet) can still reach him goes down instead (Infantry.lethal_hit_guard -> make_guard): health set to
##             downed_health_fraction, prone, crawling, no fighting (DownedState); a bleed-out timer (bleed_out_s)
##             starts. Faction bots and a player with no teammate left die at once.
##   revive    a teammate holds interact by him (InfantryInteraction offer "revive"): revive_s of holding within
##             reach_m gets him up with revived_health_fraction; letting go, moving away, being downed or killed
##             interrupts it (the progress is lost)
##   death     the bleed-out ending, a hit while downed (execution) or the last teammate falling kills him: the
##             usual death (ExtractionDirector: the bag)
## A downed soldier riding a vehicle (crawled aboard an exfil) does not bleed out.
## Clients see states four times a second ({net_id: {left, progress, reviver}}) and the downed changes reliably.

const NODE_NAME := "Revive"
const SYNC_SECONDS := 0.25
## A killing blow larger than any armour's health (untyped: no armour scale).
const FINISHING_DAMAGE := 1.0e9

var director: ExtractionDirector
## Host: net id -> {peer, left (seconds)}; downed net id -> {reviver (peer), done (seconds)}.
var downed := {}
var revives := {}
## Every peer: net id -> {left, progress (0..1), reviver (peer)} of every downed soldier.
var states := {}
## The local player: the downed net id he is reviving (0 = none).
var my_target := 0
var hud: ReviveHud
var _sync_t := 0.0
var _pilot: DownedPilot


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	name = NODE_NAME


## The rules' "revive" table.
static func rules() -> Dictionary:
	return ExtractionRules.data().get("revive", {})


func _ready() -> void:
	var interaction := InfantryInteraction.of(director.battle)
	if interaction:
		interaction.add_provider(make_revive_offer)
	hud = ReviveHud.new(self)
	director.battle.overlay.add_child(hud)


## Host: every raid player's soldier carries the downed guard (Infantry.lethal_hit_guard), whenever it spawned.
func _apply_guards() -> void:
	for peer in director.make_raid_peers():
		var soldier := director.battle.occupancy.soldier_of(int(peer))
		if soldier and not soldier.lethal_hit_guard.is_valid():
			soldier.lethal_hit_guard = _on_lethal_hit


# ------------------------------------------------------------------ queries

## True when `soldier` is a downed player that `reviver` may pick up (allied, both in the raid).
func can_revive(reviver: Infantry, soldier: Infantry) -> bool:
	return is_instance_valid(reviver) and is_instance_valid(soldier) and reviver != soldier and reviver.alive \
		and not reviver.stowed and not DownedState.is_downed(reviver) and soldier.alive and DownedState.is_downed(soldier) \
		and TeamRelations.is_allied(reviver.team, soldier.team)


## The downed soldier nearest `reviver` within reach (null when none).
func find_downed_near(reviver: Infantry) -> Infantry:
	var reach := float(rules().get("reach_m", 2.5))
	var best: Infantry = null
	for net_id in states:
		var s := director.battle.vehicles.get(int(net_id)) as Infantry
		if can_revive(reviver, s) and s.global_position.distance_to(reviver.global_position) <= reach \
				and (best == null or s.global_position.distance_to(reviver.global_position) < best.global_position.distance_to(reviver.global_position)):
			best = s
	return best


## Host: true when a soldier of another raid player who could revive `peer` is still up.
func has_standing_teammate(peer: int) -> bool:
	var soldier := director.battle.occupancy.soldier_of(peer)
	if soldier == null:
		return false
	for other in director.make_raid_peers():
		var mate := director.battle.occupancy.soldier_of(int(other))
		if int(other) != peer and mate and mate.alive and not DownedState.is_downed(mate) \
				and TeamRelations.is_allied(mate.team, soldier.team):
			return true
	return false


## Interact offer: "revive NAME" by a downed teammate in reach ({} when none, or the local soldier is down himself).
func make_revive_offer(soldier: Infantry) -> Dictionary:
	if DownedState.is_downed(soldier) or director.my_status != ExtractionDirector.STATUS_IN_RAID:
		return {}
	var target := find_downed_near(soldier)
	if target == null:
		return {}
	return {"distance": target.global_position.distance_to(soldier.global_position),
		"text": "hold to revive %s" % target.display_name, "apply": func() -> void: _start_local_revive(target.net_id)}


## The local player's progress text and fraction while he revives somebody ({} when he does not).
func make_local_revive_state() -> Dictionary:
	if my_target == 0 or not states.has(my_target):
		return {}
	var s := director.battle.vehicles.get(my_target) as Infantry
	return {"name": s.display_name if s else "", "progress": float(states[my_target].progress)}


func is_local_reviving() -> bool:
	return my_target != 0


# ------------------------------------------------------------------ the local player

func _start_local_revive(net_id: int) -> void:
	my_target = net_id
	_request("_request_revive", [net_id, true])


func _process(_delta: float) -> void:
	if my_target != 0 and (not Input.is_action_pressed("interact") or not states.has(my_target)):
		_request("_request_revive", [my_target, false])
		my_target = 0


func _request(method: String, args: Array) -> void:
	if multiplayer.is_server():
		callv("_apply" + method.trim_prefix("_request"), [multiplayer.get_unique_id()] + args)
	else:
		callv("rpc_id", [1, method] + args)


@rpc("any_peer", "reliable")
func _request_revive(net_id: int, on: bool) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_revive(multiplayer.get_remote_sender_id(), net_id, on)


# ------------------------------------------------------------------ host

## Host: `peer` starts (`on`) or stops holding interact by downed soldier `net_id`.
func _apply_revive(peer: int, net_id: int, on: bool) -> void:
	if not on:
		if revives.has(net_id) and int(revives[net_id].reviver) == peer:
			revives.erase(net_id)
		return
	var reviver := director.battle.occupancy.soldier_of(peer)
	var target := director.battle.vehicles.get(net_id) as Infantry
	if downed.has(net_id) and _is_in_reach(reviver, target) and not revives.has(net_id):
		revives[net_id] = {"reviver": peer, "done": 0.0}


func _is_in_reach(reviver: Infantry, target: Infantry) -> bool:
	return can_revive(reviver, target) and reviver.global_position.distance_to(target.global_position) <= float(rules().get("reach_m", 2.5)) + 0.5


## Host (Infantry.lethal_hit_guard): a lethal hit on a player's soldier downs him when a teammate can come.
func _on_lethal_hit(soldier: Infantry, _attacker: Node) -> bool:
	var peer := director.peer_of(soldier)
	if peer == 0 or DownedState.is_downed(soldier) or not director.is_in_raid(peer) or not has_standing_teammate(peer):
		return false
	DownedState.apply_health_fraction(soldier, float(rules().get("downed_health_fraction", 0.25)))
	downed[soldier.net_id] = {"peer": peer, "left": ExtractionRules.timer(director.battle.config, "bleed_out_s")}
	_cancel_revives_by(peer)
	ExtractionDirector.send_all_from(self, "_set_downed", [soldier.net_id, true])
	director.notify_all("%s is down - revive him!" % soldier.display_name)
	return true


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or director.battle.is_over():
		return
	_apply_guards()
	for net_id in downed.keys():
		_update_downed(int(net_id), delta)
	for net_id in revives.keys():
		_update_revive(int(net_id), delta)
	_sync_t -= delta
	if _sync_t <= 0.0:
		_sync_t = SYNC_SECONDS
		ExtractionDirector.send_all_from(self, "_revive_states", [make_states()])


func _update_downed(net_id: int, delta: float) -> void:
	var soldier := director.battle.vehicles.get(net_id) as Infantry
	if soldier == null or not soldier.alive or not DownedState.is_downed(soldier):
		apply_forget(net_id)
		return
	DownedState.apply_held_controls(soldier, DownedState.make_crawl_share(soldier))
	if soldier.stowed:
		return
	downed[net_id].left = float(downed[net_id].left) - delta
	if float(downed[net_id].left) <= 0.0 or not has_standing_teammate(int(downed[net_id].peer)):
		apply_finish(soldier)


func _update_revive(net_id: int, delta: float) -> void:
	var target := director.battle.vehicles.get(net_id) as Infantry
	var reviver := director.battle.occupancy.soldier_of(int(revives[net_id].reviver))
	if not downed.has(net_id) or not _is_in_reach(reviver, target):
		revives.erase(net_id)
		return
	revives[net_id].done = float(revives[net_id].done) + delta
	if float(revives[net_id].done) >= ExtractionRules.timer(director.battle.config, "revive_s"):
		_apply_revived(target, reviver)


func _apply_revived(soldier: Infantry, reviver: Infantry) -> void:
	DownedState.apply_health_fraction(soldier, float(rules().get("revived_health_fraction", 0.3)))
	downed.erase(soldier.net_id)
	revives.erase(soldier.net_id)
	ExtractionDirector.send_all_from(self, "_set_downed", [soldier.net_id, false])
	director.notify_all("%s revived %s." % [reviver.display_name, soldier.display_name])
	director.callins.points.apply_revive(director.peer_of(reviver))


## Host: kills downed `soldier` (bled out, or nobody left to come): the usual death follows.
func apply_finish(soldier: Infantry) -> void:
	DamageTypes.apply_typed_hit(soldier, [0.0, FINISHING_DAMAGE, null, soldier.global_position], "")


## Host: `net_id` is no longer downed (dead, gone): its records and its prone pose go.
func apply_forget(net_id: int) -> void:
	if downed.has(net_id) or states.has(net_id):
		downed.erase(net_id)
		revives.erase(net_id)
		ExtractionDirector.send_all_from(self, "_set_downed", [net_id, false])


## A reviver who goes down stops reviving.
func _cancel_revives_by(peer: int) -> void:
	for net_id in revives.keys():
		if int(revives[net_id].reviver) == peer:
			revives.erase(net_id)


func make_states() -> Dictionary:
	var out := {}
	var needed := ExtractionRules.timer(director.battle.config, "revive_s")
	for net_id in downed:
		var r: Dictionary = revives.get(net_id, {})
		out[net_id] = {"left": float(downed[net_id].left), "reviver": int(r.get("reviver", 0)),
			"progress": clampf(float(r.get("done", 0.0)) / maxf(needed, 0.01), 0.0, 1.0)}
	return out


# ------------------------------------------------------------------ every peer

@rpc("authority", "reliable", "call_local")
func _set_downed(net_id: int, on: bool) -> void:
	var soldier := director.battle.vehicles.get(net_id) as Infantry
	if on:
		states[net_id] = {"left": ExtractionRules.timer(director.battle.config, "bleed_out_s"), "progress": 0.0, "reviver": 0}
	else:
		states.erase(net_id)
	if soldier == null:
		return
	DownedState.apply_downed(soldier, on)
	if soldier == director.battle.player:
		_apply_local_pilot(soldier, on)


@rpc("authority", "unreliable", "call_local")
func _revive_states(p_states: Dictionary) -> void:
	states = p_states


## The local player's soldier went down (crawl controls) or got up (his own pilot back).
func _apply_local_pilot(soldier: Infantry, on: bool) -> void:
	if on and _pilot == null:
		InventoryPanel.close_open(director)
		_pilot = DownedPilot.make(director.battle, soldier)
		add_child(_pilot)
	elif not on and _pilot != null:
		remove_child(_pilot)
		_pilot.queue_free()
		_pilot = null
