class_name RaidPoints
extends Node
## Raid points (RP): the call-in currency of an extraction raid (child "RaidPoints" of the Callins node; every peer;
## docs/design/lobby_loadout_economy.md section 9.1, user answer O8).
##   keeping   the balance lives on the operator profile (OperatorProfile.raid_points): it carries over to the next
##             raid, is capped (economy option o8_raid_points.max), is lost when the operator dies and is never
##             converted to credits. Each machine saves its own player's balance.
##   earning   the host sees the events: a kill (scaled by the victim faction's difficulty), an assist, a finished
##             task (reward / task_divisor), a destroyed generator, a stolen faction flag, a revive.
##   telling   the host sends the balance to its owner only (rpc_id); the owner shows it ("RP 340") and saves it.

signal changed(balance: int, delta: int, why: String)

const NODE_NAME := "RaidPoints"
const WHY_KILL := "kill"
const WHY_ASSIST := "assist"
const WHY_TASK := "task"
const WHY_GENERATOR := "generator"
const WHY_FLAG := "flag"
const WHY_REVIVE := "revive"

var director: ExtractionDirector
var callins: CallinDirector
## Host: peer -> balance of the raid players.
var balances := {}
## Every peer: the local player's balance.
var mine := 0
## Every peer: the last gain ("+20 RP kill") and how long it stays on the HUD.
var last_gain := ""
var last_gain_left := 0.0
var _assist_hits := {}      # host: victim net id -> {peer: msec of his last hit}
var _flags_paid := {}       # host: container id -> true (a flag pays once)
var _save_left := 0.0
var _unsaved := false


func _init(p_director: ExtractionDirector, p_callins: CallinDirector) -> void:
	director = p_director
	callins = p_callins
	name = NODE_NAME


func _process(delta: float) -> void:
	last_gain_left = maxf(last_gain_left - delta, 0.0)
	if _unsaved:
		_save_left -= delta
		if _save_left <= 0.0:
			apply_save()


func _exit_tree() -> void:
	if _unsaved:
		apply_save()


## The cap on a balance.
static func make_cap() -> int:
	return OperatorProfile.make_raid_points_cap()


# ------------------------------------------------------------------ the local player

## Every peer, when the raid is built: the operator's raid begins on this machine (the balance he brings is read).
func apply_local_start() -> void:
	if not director.battle.config.get("roster", {}).has(multiplayer.get_unique_id()):
		return   # a dedicated server plays no operator
	mine = RaidOperator.apply_begin(Net.player_name, director.battle.config)


## Host, once the raid is set up: every player is asked for the balance he brings.
func request_reports() -> void:
	for peer in director.make_raid_peers():
		callins.send_to(int(peer), self, "_send_report", [])


## Every peer: tells the host the balance this machine's operator brings.
@rpc("authority", "reliable", "call_local")
func _send_report() -> void:
	if multiplayer.is_server():
		apply_start_balance(multiplayer.get_unique_id(), mine)
	else:
		_start_balance.rpc_id(1, mine)


@rpc("any_peer", "reliable")
func _start_balance(amount: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_start_balance(multiplayer.get_remote_sender_id(), amount)


## Host: `peer` starts the raid with `amount` raid points (what his profile carried over, cut to the cap).
func apply_start_balance(peer: int, amount: int) -> void:
	balances[peer] = clampi(amount, 0, make_cap())
	callins.send_to(peer, self, "_balance", [balances[peer], 0, ""])


## Every peer: the host's word on the local balance.
@rpc("authority", "reliable", "call_local")
func _balance(value: int, delta: int, why: String) -> void:
	mine = value
	if delta > 0:
		last_gain = "+%d RP  %s" % [delta, why]
		last_gain_left = 3.0
	_unsaved = true
	_save_left = float(CallinRules.points().get("save_every_s", 2.0))
	changed.emit(mine, delta, why)


## The balance is written to the profile (kept for the next raid).
func apply_save() -> void:
	_unsaved = false
	RaidOperator.apply_points(Net.player_name, mine)


## The local operator died: the balance is gone (the profile is cleared by RaidOperator.apply_died).
func apply_lost() -> void:
	mine = 0
	_unsaved = false


# ------------------------------------------------------------------ host: the balance

func get_balance(peer: int) -> int:
	return int(balances.get(peer, 0))


## Host: `amount` raid points for `peer` (cut to the cap); returns what was added.
func apply_add(peer: int, amount: int, why: String) -> int:
	if not balances.has(peer) or amount <= 0:
		return 0
	var before := get_balance(peer)
	balances[peer] = mini(before + amount, make_cap())
	var gained := get_balance(peer) - before
	callins.send_to(peer, self, "_balance", [balances[peer], gained, why])
	return gained


## Host: takes `amount` from `peer`; false (nothing taken) when he is short.
func apply_spend(peer: int, amount: int) -> bool:
	if get_balance(peer) < amount:
		return false
	balances[peer] = get_balance(peer) - amount
	callins.send_to(peer, self, "_balance", [balances[peer], 0, ""])
	return true


## Host: gives `amount` back (a cancelled order), whatever the cap says.
func apply_refund(peer: int, amount: int) -> void:
	if balances.has(peer):
		balances[peer] = mini(get_balance(peer) + amount, make_cap())
		callins.send_to(peer, self, "_balance", [balances[peer], 0, ""])


## Host: `peer` died: his balance is gone.
func apply_clear(peer: int) -> void:
	if balances.has(peer):
		balances[peer] = 0
		callins.send_to(peer, self, "_balance", [0, 0, ""])


# ------------------------------------------------------------------ host: earning

## `victim` is hit by `attacker`: a later kill by someone else pays this one an assist.
func apply_hit_seen(victim: Herc, attacker: Node) -> void:
	var peer := director.peer_of_unit(attacker)
	if peer == 0 or victim == null:
		return
	if not _assist_hits.has(victim.net_id):
		_assist_hits[victim.net_id] = {}
	_assist_hits[victim.net_id][peer] = Time.get_ticks_msec()


## `victim` was destroyed by `killer` (a node: his soldier or the vehicle he sits in): the killer's kill points, and
## assists for the others who hit it recently. Friendly fire pays nothing.
func apply_kill(victim: Herc, killer: Node) -> void:
	var peer := director.peer_of_unit(killer)
	var hits: Dictionary = _assist_hits.get(victim.net_id, {})
	_assist_hits.erase(victim.net_id)
	if peer == 0 or TeamRelations.is_allied(director.make_player_team(peer), victim.team):
		return
	apply_add(peer, make_kill_points(victim), WHY_KILL)
	var window := float(CallinRules.points().get("assist_window_s", 10.0)) * 1000.0
	for other in hits:
		if int(other) != peer and float(Time.get_ticks_msec() - int(hits[other])) <= window:
			apply_add(int(other), int(CallinRules.points().get("assist", 8)), WHY_ASSIST)


## Raid points a kill of `victim` is worth: a player, a vehicle or a soldier, scaled by his faction's difficulty.
func make_kill_points(victim: Herc) -> int:
	var table := CallinRules.points()
	var base: float
	if victim is Infantry and director.peer_of(victim as Infantry) != 0:
		return int(table.get("kill_player", 80))
	elif victim is Infantry:
		base = float(table.get("kill_infantry", 20))
	else:
		base = float(table.get("kill_vehicle", 60))
	return int(round(base * make_difficulty(victim.team)))


## The difficulty factor of the faction fielding `team` (1 for none, or when the scaling is off).
func make_difficulty(team: int) -> float:
	if not bool(CallinRules.points().get("difficulty_scaled", true)):
		return 1.0
	var faction := str(director.faction_teams.get(team, ""))
	if faction == "":
		return 1.0
	return float((RaidTaskBoard.rules().get("difficulty", {}) as Dictionary).get(ExtractionFactions.kind_of(faction), 1.0))


## A task of `peer` is done: its reward / task_divisor.
func apply_task_done(peer: int, task: Dictionary) -> void:
	var divisor := maxi(int(CallinRules.points().get("task_divisor", 10)), 1)
	apply_add(peer, int(task.get("reward", 0)) / divisor, WHY_TASK)


## A base generator was destroyed by `killer`.
func apply_generator_destroyed(killer: Node) -> void:
	apply_add(director.peer_of_unit(killer), int(CallinRules.points().get("objective_generator", 150)), WHY_GENERATOR)


## `peer` took a faction flag out of container `container_id` (it pays once per flag).
func apply_flag_taken(peer: int, container_id: int) -> void:
	if _flags_paid.has(container_id):
		return
	_flags_paid[container_id] = true
	apply_add(peer, int(CallinRules.points().get("objective_flag", 200)), WHY_FLAG)


## `peer` revived a teammate.
func apply_revive(peer: int) -> void:
	apply_add(peer, int(CallinRules.points().get("revive", 40)), WHY_REVIVE)


## "RP 340" for the HUD.
func make_hud_text() -> String:
	return "RP %d / %d" % [mine, make_cap()]
