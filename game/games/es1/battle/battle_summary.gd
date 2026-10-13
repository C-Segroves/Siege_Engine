class_name BattleSummary
extends RefCounted
## What the results screen (MatchResults) shows after a match, built on the host and sent to every
## peer: the headline, the winner, the time, per-pilot kills / deaths / score, a mission's salvage
## and whether a rematch is offered.
##   {mode, headline, winner, text, seconds, pilots: [{name, vehicle, team, kills, deaths, score,
##    player}], salvage: [lines], losses: [names], campaign, aborted, rematch, rematch_config, battle_scene}
## Missions list only the pilots (the mission's own units are counted as "enemies destroyed").
## A campaign mission's salvage lists the tonnage ("Salvage: 42 t") and the recovered weapons; its
## losses are the garage Hercs (the player's, wingmen) destroyed.

## Score = kills minus deaths (net frags; destroying yourself costs a death like any other).
const SCORE_PER_KILL := 1
const SCORE_PER_DEATH := -1
## Modes that offer a rematch (the same config again; LAN: the host restarts the lobby's match).
const REMATCH_MODES := ["skirmish", "vs", "coop"]
const SALVAGE_TONS := "Salvage: %s"
const MISSION_HEADLINES := MissionOutcome.HEADLINES
const MATCH_ABANDONED := "MATCH ABANDONED"
const MATCH_OVER := "MATCH OVER"
## The battle scene a rematch starts when the battle was not instanced from a scene file.
const DEFAULT_BATTLE_SCENE := "res://games/es1/battle.tscn"


## The summary of `battle`'s finished match. `outcome`: {text, winner, aborted}.
static func make(battle: Battle, outcome: Dictionary) -> Dictionary:
	var mode := str(battle.config.get("mode", "skirmish"))
	var is_mission := mode == "mission"
	return {
		"mode": mode, "headline": make_headline(mode, battle.result, outcome),
		"winner": str(outcome.get("winner", "")), "text": str(outcome.get("text", "")),
		"seconds": battle.match_seconds(), "pilots": make_pilot_rows(battle.vehicles, is_mission),
		"enemies_destroyed": count_destroyed_enemies(battle.vehicles) if is_mission else 0,
		"salvage": make_salvage_names(battle.result), "losses": make_loss_names(battle.vehicles), "campaign": is_mission,
		"aborted": bool(outcome.get("aborted", false)),
		"rematch": REMATCH_MODES.has(mode),
		"rematch_config": battle.initial_config.duplicate(true) if REMATCH_MODES.has(mode) else {},
		"battle_scene": battle.scene_file_path if battle.scene_file_path != "" else DEFAULT_BATTLE_SCENE,
	}


static func make_headline(mode: String, result: Dictionary, outcome: Dictionary) -> String:
	var aborted := bool(outcome.get("aborted", false))
	if mode == "mission":
		return MissionOutcome.make_headline({"aborted": aborted, "success": result.get("success", false)})
	if aborted:
		return MATCH_ABANDONED
	var winner := str(outcome.get("winner", ""))
	return "%s WINS" % winner.to_upper() if winner != "" else MATCH_OVER


## One row per pilot, best score first. A mission lists the player-flown vehicles only.
static func make_pilot_rows(vehicles: Dictionary, players_only: bool) -> Array:
	var rows := []
	for id in vehicles:
		var h: Herc = vehicles[id]
		if not is_instance_valid(h):
			continue
		var is_player := not h.has_meta("ai")
		if players_only and not is_player:
			continue
		if is_player and not _is_pilot_row(h, vehicles):
			continue
		rows.append({"name": h.display_name, "vehicle": str(h.def.get("name", h.vehicle_id)), "team": h.team,
			"kills": h.kills, "deaths": h.deaths, "score": make_score(h.kills, h.deaths), "player": is_player})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	return rows


## A human-owned vehicle is listed only when its player has no soldier of his own: on foot modes the
## soldier's row carries the player (kills from a piloted vehicle are credited to him), and parked,
## empty vehicles are not pilots at all.
static func _is_pilot_row(h: Herc, vehicles: Dictionary) -> bool:
	if h is Infantry:
		return true
	var occupancy := h.get_node_or_null(VehicleOccupancy.NODE_NAME) as VehicleOccupancy
	if occupancy != null and not occupancy.has_pilot():
		return false
	for other in vehicles.values():
		if is_instance_valid(other) and other is Infantry and other.owner_peer == h.owner_peer:
			return false
	return true


static func make_score(kills: int, deaths: int) -> int:
	return kills * SCORE_PER_KILL + deaths * SCORE_PER_DEATH


static func count_destroyed_enemies(vehicles: Dictionary) -> int:
	var n := 0
	for id in vehicles:
		var h: Herc = vehicles[id]
		if is_instance_valid(h) and h.has_meta("ai") and h.team != BattleRules.PLAYER_TEAM and not h.alive:
			n += 1
	return n


## "Salvage: 42 t" (the wrecks' tonnage, kept whatever the outcome, as results.dat), then "Laser 200
## GW x4", one line per weapon type of a won mission's salvage (only a success keeps the weapons).
static func make_salvage_names(result: Dictionary) -> Array:
	var tonnage: Array = [SALVAGE_TONS % GarageEconomy.make_tons_text(int(result.salvage_kg))] if int(result.get("salvage_kg", 0)) > 0 else []
	if not bool(result.get("success", false)):
		return tonnage
	return tonnage + make_weapon_names(result)


static func make_weapon_names(result: Dictionary) -> Array:
	var counts := {}
	for wid in result.get("salvage", []):
		var w := Packs.weapon(str(wid))
		var weapon_name := str(w.get("display_name", w.get("name", wid)))
		counts[weapon_name] = int(counts.get(weapon_name, 0)) + 1
	var names := []
	for weapon_name in counts:
		names.append("%s x%d" % [weapon_name, counts[weapon_name]] if int(counts[weapon_name]) > 1 else weapon_name)
	return names


## Names of the campaign garage's Hercs destroyed in the battle (player and wingmen).
static func make_loss_names(vehicles: Dictionary) -> Array:
	var out: Array = []
	for id in vehicles:
		var h: Herc = vehicles[id]
		if is_instance_valid(h) and h.has_meta("garage") and not h.alive:
			out.append(h.display_name)
	return out
