class_name MapTeams
extends RefCounted
## How many teams a map supports and how teams look: the team ids of the map's own spawns (engine map
## schema "spawns" with "team"; -1 = neutral and not counted). Tribes "Four Way Dance" / "Free For All" and the
## Starsiege DM maps place drop points for four teams, most maps for two. Versus and team modes offer more than
## MIN_TEAMS only where the map has the spawns for them (the host screen's team-count option, D12).
##
## Colours and names: the Starsiege multiplayer maps name their teams red, blue, yellow, purple (map.json
## "teams", from the mission's team records); that order is every map's default.

const MIN_TEAMS := 2
const MAX_TEAMS := 4
const NEUTRAL_TEAM := -1
## Spawn kinds that start a combatant (vehicles or soldiers).
const PLAYER_SPAWN_KINDS := ["herc", "infantry", "vehicle_pad"]
const COLOR_BY_NAME := {
	"red": Color(0.9, 0.2, 0.15), "blue": Color(0.2, 0.45, 0.95), "yellow": Color(0.95, 0.85, 0.2),
	"purple": Color(0.65, 0.3, 0.85), "green": Color(0.25, 0.8, 0.3), "orange": Color(0.95, 0.55, 0.15),
}
const DEFAULT_COLOR_NAMES := ["red", "blue", "yellow", "purple", "green", "orange"]
const OTHER_TEAM_COLOR := Color(0.7, 0.7, 0.7)

## True while a match of more than MIN_TEAMS teams runs: the friend-or-foe displays then tell the opposing teams
## apart by their team colours (TargetInfo.make_iff_color). Set by Battle when it starts.
static var shows_team_colors := false


## The current battle's team rule (`config` "team_count").
static func apply_battle(config: Dictionary) -> void:
	shows_team_colors = int(config.get("team_count", MIN_TEAMS)) > MIN_TEAMS


## Teams the map supports (MIN_TEAMS .. MAX_TEAMS). `map_config` is a loaded map.json, a MapBuilder.list_maps
## entry ({"id": "pack:map"}) or a battle config ({"map": "pack:map"}); anything without a map gives MIN_TEAMS.
static func make_team_count(map_config: Dictionary) -> int:
	return clampi(make_spawn_teams(load_map_data(map_config)).size(), MIN_TEAMS, MAX_TEAMS)


## The team ids (sorted, neutral excluded) that have their own spawns on map `m` (a loaded map.json).
static func make_spawn_teams(m: Dictionary) -> Array:
	var teams := {}
	for s in m.get("spawns", []):
		var team := int(s.get("team", NEUTRAL_TEAM)) if s.get("team") != null else NEUTRAL_TEAM
		if team != NEUTRAL_TEAM and String(s.get("kind", "herc")) in PLAYER_SPAWN_KINDS:
			teams[team] = true
	var out := teams.keys()
	out.sort()
	return out


## The map.json behind `map_config` ({} when it names no map).
static func load_map_data(map_config: Dictionary) -> Dictionary:
	if map_config.get("spawns") is Array:
		return map_config
	if map_config.get("spawn_points") is Array:   # a map index entry carrying its starts (Earthsiege worlds)
		return {"spawns": map_config.spawn_points}
	var id := str(map_config.get("map", map_config.get("id", "")))
	return MapBuilder.load_map(id) if id.contains(":") else {}


## Display colour of team `i` (0-based).
static func make_team_color(i: int) -> Color:
	if i < 0 or i >= DEFAULT_COLOR_NAMES.size():
		return OTHER_TEAM_COLOR
	return COLOR_BY_NAME[DEFAULT_COLOR_NAMES[i]]


## Display name of team `i`: always the colour name of make_team_color(i) ("Red" is red), so lobby, HUD,
## scoreboard and kill text agree. A map's own team names (map.json "teams") are not used: they follow the
## mission's team records, not the colours the engine paints. `map_config` is kept for callers' signature.
static func make_team_name(i: int, _map_config: Dictionary = {}) -> String:
	if i >= 0 and i < DEFAULT_COLOR_NAMES.size():
		return str(DEFAULT_COLOR_NAMES[i]).capitalize()
	return "Team %d" % (i + 1)
