class_name ModeScore
extends RefCounted
## A match's scores: per team and per player (a player is keyed by the name he plays under, so his score follows
## him from soldier to vehicle and through respawns).

const NOBODY := ""
const NO_TEAM := -1
## Counted events (add_event): a pilot capturing or returning a flag; the match stats pay them as objectives.
const EVENT_FLAG_CAPTURE := "flag_capture"
const EVENT_FLAG_RETURN := "flag_return"

var teams := {}      # team id -> points
var players := {}    # player key -> points
var events := {}     # player key -> {event name -> count}, host only (the match stats read it; not synced)


func add_team(team: int, points: float) -> void:
	if team < 0:
		return
	teams[team] = team_score(team) + points


func add_player(key: String, points: float) -> void:
	if key == NOBODY:
		return
	players[key] = player_score(key) + points


func add_event(key: String, event: String) -> void:
	if key == NOBODY:
		return
	var counts: Dictionary = events.get(key, {})
	counts[event] = int(counts.get(event, 0)) + 1
	events[key] = counts


func event_count(key: String, event: String) -> int:
	return int((events.get(key, {}) as Dictionary).get(event, 0))


func team_score(team: int) -> float:
	return float(teams.get(team, 0.0))


func player_score(key: String) -> float:
	return float(players.get(key, 0.0))


## The team with the most points (NO_TEAM on a tie or with no scores).
func make_best_team() -> int:
	return _make_best(teams, NO_TEAM)


## The player with the most points (NOBODY on a tie).
func make_best_player() -> String:
	return str(_make_best(players, NOBODY))


static func _make_best(table: Dictionary, none: Variant) -> Variant:
	var best: Variant = none
	var best_points := -INF
	var tie := false
	for k in table:
		var v := float(table[k])
		if v > best_points:
			best = k
			best_points = v
			tie = false
		elif v == best_points:
			tie = true
	return none if tie else best


func make_dict() -> Dictionary:
	return {"teams": teams.duplicate(), "players": players.duplicate()}


func apply_dict(d: Dictionary) -> void:
	teams = {}
	for k in d.get("teams", {}):
		teams[int(k)] = float(d.teams[k])
	players = d.get("players", {}).duplicate()
