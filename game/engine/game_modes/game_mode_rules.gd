class_name GameModeRules
extends RefCounted
## The rules of one game mode (docs/formats/game_modes.md): scoring, objectives, win conditions. Pure logic with
## no scene, so the headless tests drive it directly; GameModeDirector feeds it the battle's events on the host and
## sends its state (make_state) to every peer.
##
## A player is a Dictionary (GameModeDirector.make_player): {id: net id of the body he is in, key: name scores go
## to, team, alive, pos: Vector3, can_touch: may pick up / touch objects now (a Tribes rider may not), vehicle:
## a Herc or other vehicle, integrity: 0..1}. Killers may be {} (the environment).
##
## Subclasses override _on_setup, _on_kill, apply_touch, apply_destroyed, _on_tick, make_hud_lines.

const SECONDS_PER_MINUTE := 60.0
const NO_LIMIT := 0.0

var mode_id := ""
var team_based := false
var settings := {}
var score := ModeScore.new()
## id -> ModeObject
var objects := {}
## Team ids playing and their names.
var teams: Array = []
var team_names := {}
## The players seen in the last tick (key -> player), for modes that pick among them (Bounty, Football).
var players := {}
## net id -> player key of the bodies seen (sent to the peers: "taken by <name>").
var names_by_id := {}
var elapsed := 0.0
var over := false
var result_text := ""
var winner := ""
## Messages for every screen since the host last read them (take_messages).
var messages: Array[String] = []
## Bumped on every change the peers must see.
var revision := 0
## Things the battle must do (take_requests): {"kind": "respawn_all"} (Siege halftime, a Football touchdown),
## {"kind": "kill", "id": net id} (a Football foul).
var requests: Array = []


func configure(p_mode_id: String, p_team_based: bool, p_settings: Dictionary) -> void:
	mode_id = p_mode_id
	team_based = p_team_based
	settings = p_settings


## Host: the match starts with the map's `mode_objects` (dicts) and the playing `p_teams` ({id: name}).
func setup(mode_objects: Array, p_teams: Dictionary) -> void:
	team_names = p_teams.duplicate()
	teams = p_teams.keys()
	teams.sort()
	for d in mode_objects:
		var o := ModeObject.from_map(d)
		objects[o.id] = o
	for t in teams:
		score.add_team(t, 0.0)
	_on_setup()
	_changed()


func _on_setup() -> void:
	pass


# ------------------------------------------------------------------ events (host)

## `victim` was killed by `killer` ({} for the environment).
func apply_kill(victim: Dictionary, killer: Dictionary) -> void:
	if over:
		return
	_apply_kill_score(victim, killer)
	_apply_defend_bonuses(victim, killer)
	_on_kill(victim, killer)
	_changed()


func _on_kill(_victim: Dictionary, _killer: Dictionary) -> void:
	pass


## The usual kill points (score_per_kill / suicide / teamkill / death).
func _apply_kill_score(victim: Dictionary, killer: Dictionary) -> void:
	if is_suicide(victim, killer):
		score.add_player(str(victim.get("key", "")), _num("score_per_suicide", -1.0))
		return
	if is_teamkill(victim, killer):
		score.add_player(str(killer.key), _num("score_per_teamkill", -1.0))
		return
	score.add_player(str(killer.key), _num("score_per_kill", 1.0))
	score.add_player(str(victim.get("key", "")), _num("score_per_death", 0.0))


## Kills that defend (T1 Flag / TowerSwitch::clientKilled, T2 CTF / CnH updateKillScores), each when its
## setting is there: the victim died near the killer's flag at home (defend_radius_m) or his team's generator
## (gen_defend_radius_m); the killer stood near a switch his team holds (switch_defend_radius_m) or near his team's
## flag carrier (escort_radius_m). A carrier's death is a carrier kill instead of a flag defence.
func _apply_defend_bonuses(victim: Dictionary, killer: Dictionary) -> void:
	if killer.is_empty() or is_suicide(victim, killer) or is_teamkill(victim, killer):
		return
	var team := int(killer.team)
	var key := str(killer.key)
	var at: Vector3 = victim.get("pos", Vector3.ZERO)
	var by: Vector3 = killer.get("pos", Vector3.ZERO)
	if make_carried(int(victim.get("id", 0))).is_empty() and _is_near(ModeObject.KIND_FLAG, team, at, "defend_radius_m"):
		_award(key, "score_per_flag_defend", "%s defends the flag.")
	if _is_near(ModeObject.KIND_GENERATOR, team, at, "gen_defend_radius_m"):
		_award(key, "score_per_gen_defend", "%s defends a generator.")
	if _is_near(ModeObject.KIND_SWITCH, team, by, "switch_defend_radius_m"):
		_award(key, "score_per_switch_defend", "%s defends a switch.")
	if _is_near_own_carrier(killer, by):
		_award(key, "score_per_escort", "%s defends the flag carrier.")


func _award(key: String, setting: String, text: String) -> void:
	var points := _num(setting, 0.0)
	if points != 0.0:
		score.add_player(key, points)
		announce(text % make_label(key))


## An object of `kind` belonging to `team` (a switch: held by it; a flag: at home or dropped) within the
## setting's radius of `p` (no setting: never).
func _is_near(kind: String, team: int, p: Vector3, radius_setting: String) -> bool:
	var radius := _num(radius_setting, 0.0)
	if radius <= 0.0:
		return false
	for o in objects_of(kind):
		var mine: bool = o.owner_team == team if kind == ModeObject.KIND_SWITCH else o.team == team
		if mine and o.state != ModeObject.CARRIED and o.pos.distance_to(p) <= radius:
			return true
	return false


func _is_near_own_carrier(killer: Dictionary, by: Vector3) -> bool:
	var radius := _num("escort_radius_m", 0.0)
	if radius <= 0.0:
		return false
	for o in objects.values():
		if o.state != ModeObject.CARRIED or o.carrier == int(killer.id):
			continue
		for p in players.values():
			if int(p.id) == o.carrier and int(p.team) == int(killer.team) and (p.pos as Vector3).distance_to(by) <= radius:
				return true
	return false


## A hit landed on `victim` from `attacker` (Football fumbles).
func apply_hit(_victim: Dictionary, _attacker: Dictionary) -> void:
	pass


static func is_suicide(victim: Dictionary, killer: Dictionary) -> bool:
	return killer.is_empty() or str(killer.get("key", "")) == str(victim.get("key", "")) \
		or int(killer.get("id", 0)) == int(victim.get("id", -1))


func is_teamkill(victim: Dictionary, killer: Dictionary) -> bool:
	return team_based and not killer.is_empty() and int(killer.team) == int(victim.get("team", -2))


## `player` touches object `object_id` (within its reach).
func apply_touch(_player: Dictionary, _object_id: int) -> void:
	pass


## Objective `object_id` was destroyed by `by` ({} unknown).
func apply_destroyed(_object_id: int, _by: Dictionary) -> void:
	pass


## Host, every physics frame: time passes; `p_players` = every combatant now (make_player dicts).
func apply_tick(delta: float, p_players: Array) -> void:
	if over:
		return
	elapsed += delta
	players.clear()
	for p in p_players:
		players[str(p.key)] = p
		names_by_id[int(p.id)] = str(p.key)
	_on_tick(delta)
	var limit := _num("time_limit_s", NO_LIMIT)
	if not over and limit > NO_LIMIT and elapsed >= limit:
		_on_time_limit()


func _on_tick(_delta: float) -> void:
	pass


## Time is up: the best team (or player) wins; a tie is a draw.
func _on_time_limit() -> void:
	finish_by_score("Time limit reached.")


# ------------------------------------------------------------------ results

func finish_by_score(reason: String) -> void:
	if team_based:
		var t := score.make_best_team()
		if t == ModeScore.NO_TEAM:
			finish("%s The match is a draw." % reason, "")
		else:
			finish("%s %s wins!" % [reason, make_team_name(t)], make_team_name(t))
	else:
		var k := score.make_best_player()
		if k == ModeScore.NOBODY:
			finish("%s The match is a draw." % reason, "")
		else:
			finish("%s %s wins!" % [reason, k], k)


func finish(text: String, p_winner: String) -> void:
	if over:
		return
	over = true
	result_text = text
	winner = p_winner
	_changed()


## Team score limit reached by `team` (score_limit 0 = none).
func check_team_limit(team: int) -> void:
	var limit := _num("score_limit", NO_LIMIT)
	if limit > NO_LIMIT and score.team_score(team) >= limit:
		finish("%s reaches %d points." % [make_team_name(team), int(limit)], make_team_name(team))


func check_player_limit(key: String) -> void:
	var limit := _num("score_limit", NO_LIMIT)
	if limit > NO_LIMIT and score.player_score(key) >= limit:
		finish("%s reaches %d points." % [key, int(limit)], key)


func make_team_name(team: int) -> String:
	return str(team_names.get(team, "Team %d" % (team + 1)))


# ------------------------------------------------------------------ carrying (flags, balls, items)

## Objects `player_id` carries.
func make_carried(player_id: int) -> Array:
	return objects.values().filter(func(o: ModeObject) -> bool:
		return o.state == ModeObject.CARRIED and o.carrier == player_id)


func pick_up(o: ModeObject, player: Dictionary) -> void:
	o.state = ModeObject.CARRIED
	o.carrier = int(player.id)
	o.timer = 0.0
	o.pos = player.pos


## Drops whatever `player` carries where he is; each starts its return timer (`return_s`; 0 = returns at once).
func drop_carried(player: Dictionary, return_s: float) -> Array:
	var out := []
	for o in make_carried(int(player.id)):
		out.append(o)
		if return_s <= 0.0:
			return_home(o)
			continue
		o.state = ModeObject.DROPPED
		o.carrier = ModeObject.NO_CARRIER
		o.pos = player.pos
		o.timer = return_s
	return out


func return_home(o: ModeObject) -> void:
	o.state = ModeObject.HOME
	o.carrier = ModeObject.NO_CARRIER
	o.pos = o.home
	o.timer = 0.0


## Counts down dropped objects of `kind`; returns those whose time ran out (already sent home).
func make_returned(kind: String, delta: float) -> Array:
	var out := []
	for o in objects.values():
		if o.kind == kind and o.state == ModeObject.DROPPED:
			o.timer -= delta
			if o.timer <= 0.0:
				return_home(o)
				out.append(o)
	return out


## Carried objects follow their carriers (host; peers place them from the carrier's body themselves).
func follow_carriers() -> void:
	for p in players.values():
		for o in make_carried(int(p.id)):
			o.pos = p.pos


## The name of the player in body `id` ("?" unknown).
func make_player_name(id: int) -> String:
	return str(names_by_id.get(id, "?"))


func objects_of(kind: String) -> Array:
	return objects.values().filter(func(o: ModeObject) -> bool: return o.kind == kind)


# ------------------------------------------------------------------ messages, state, HUD

## How a combatant is named in announcements: "Ace (Apocalypse)" (KillText; the key when unknown).
func make_label(key: String, player := {}) -> String:
	var p: Dictionary = player if not player.is_empty() else players.get(key, {})
	return str(p.get("label", key)) if str(p.get("label", "")) != "" else key


func announce(text: String) -> void:
	messages.append(text)


func take_messages() -> Array[String]:
	var out := messages.duplicate()
	messages.clear()
	return out


func take_requests() -> Array:
	var out := requests.duplicate()
	requests.clear()
	return out


func _changed() -> void:
	revision += 1


## Everything the peers need to draw the objects and the HUD.
func make_state() -> Dictionary:
	var objs := []
	for o in objects.values():
		objs.append(o.make_dict())
	return {"revision": revision, "elapsed": elapsed, "over": over, "result": result_text, "winner": winner,
		"score": score.make_dict(), "objects": objs, "team_names": team_names.duplicate(), "names": names_by_id.duplicate(), "extra": make_extra_state()}


func apply_state(d: Dictionary) -> void:
	revision = int(d.revision)
	elapsed = float(d.elapsed)
	over = bool(d.over)
	result_text = str(d.result)
	winner = str(d.winner)
	score.apply_dict(d.score)
	team_names = {}
	for k in d.get("team_names", {}):
		team_names[int(k)] = d.team_names[k]
	teams = team_names.keys()
	teams.sort()
	names_by_id = {}
	for k in d.get("names", {}):
		names_by_id[int(k)] = str(d.names[k])
	var seen := {}
	for od in d.objects:
		var id := int(od.id)
		seen[id] = true
		if objects.has(id):
			(objects[id] as ModeObject).apply_dict(od)
		else:
			objects[id] = ModeObject.from_dict(od)
	for id in objects.keys():
		if not seen.has(id):
			objects.erase(id)
	apply_extra_state(d.get("extra", {}))


## Mode-specific state (carried Hunters flags, Bounty targets ...).
func make_extra_state() -> Dictionary:
	return {}


func apply_extra_state(_d: Dictionary) -> void:
	pass


## The HUD panel's lines for `viewer` (the local player's make_player dict; {} when he has no body).
func make_hud_lines(_viewer: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray([GameModes.label_for(mode_id)])
	lines.append_array(make_score_lines())
	lines.append(make_time_line())
	return lines


func make_score_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if team_based:
		for t in teams:
			out.append("%s  %d" % [make_team_name(t), int(score.team_score(t))])
		return out
	var keys := score.players.keys()
	keys.sort_custom(func(a, b) -> bool: return score.player_score(a) > score.player_score(b))
	for k in keys.slice(0, 4):
		out.append("%s  %d" % [k, int(score.player_score(k))])
	return out


func make_time_line() -> String:
	var limit := _num("time_limit_s", NO_LIMIT)
	if limit <= NO_LIMIT:
		return ""
	var left := maxf(limit - elapsed, 0.0)
	return "Time %d:%02d" % [int(left) / 60, int(left) % 60]


func _num(key: String, default: float) -> float:
	return float(settings.get(key, default))
