class_name LobbyModel
extends RefCounted
## What the lobby shows, as plain data made from the roster and the settings (docs/design/lobby_loadout_economy.md
## section 5.3): who is in the pilot's own squad (cards in the carousel), who is in the compact list, the rows of that
## list and the counts in the title. Pure functions; the widgets never read Net themselves.

## Cards a carousel holds; a bigger squad (a 24 player co-op) moves its surplus into the compact list.
const MAX_SQUAD_CARDS := 8
const NO_TEAM := TeamAssignment.UNASSIGNED
const COMPUTER_GROUP := "Computer-controlled"
const PILOT_GROUP := "Pilots"
const BOT_KIND := "bot"
const PILOT_KIND := "pilot"


## True when every pilot is on one side (co-op against the Cybrids, a co-op campaign).
static func is_cooperative(settings: Dictionary) -> bool:
	return str(settings.get("mode", "")) in ["coop", "campaign"]


## The peers of the squad of `my_id`, himself first: everybody in a co-op game, his team in a team match (or an
## extraction squad), only himself in a free for all. At most MAX_SQUAD_CARDS.
static func make_squad_peers(roster: Dictionary, settings: Dictionary, my_id: int) -> Array:
	var peers := roster.keys()
	peers.sort()
	var mine := int((roster.get(my_id, {}) as Dictionary).get("team", NO_TEAM))
	var squad := []
	if roster.has(my_id):
		squad.append(my_id)
	for peer in peers:
		if int(peer) != my_id and _is_squadmate(roster[peer], mine, settings):
			squad.append(int(peer))
	return squad.slice(0, MAX_SQUAD_CARDS)


static func _is_squadmate(entry: Dictionary, my_team: int, settings: Dictionary) -> bool:
	if is_cooperative(settings):
		return true
	return LobbySettings.is_team_match(settings) and my_team != NO_TEAM and int(entry.get("team", NO_TEAM)) == my_team


## The computer-controlled members that get a card of their own: all of them in a solo session (skirmish), those on
## the pilot's team in a team match, none elsewhere (they are in the list).
static func make_squad_bots(roster: Dictionary, settings: Dictionary, my_id: int, slots_left: int) -> Array:
	var out := []
	var team_match := LobbySettings.is_team_match(settings)
	var mine := int((roster.get(my_id, {}) as Dictionary).get("team", NO_TEAM))
	for member in LobbySettings.make_planned_members(settings):
		var wanted: bool = bool(settings.get("solo", false)) or (team_match and mine != NO_TEAM and int(member.team) == mine)
		if wanted and out.size() < slots_left:
			out.append(member)
	return out


## Everybody who is not on a card: [{key, kind, name, team, team_name, detail, ready, ping}], by team then name.
static func make_list_rows(roster: Dictionary, settings: Dictionary, my_id: int, card_peers: Array, card_bots: Array) -> Array:
	var rows := []
	var map_config := LobbySettings.make_map_config(settings)
	var teams := LobbySettings.is_team_match(settings)
	for peer in roster:
		if card_peers.has(int(peer)):
			continue
		var e: Dictionary = roster[peer]
		rows.append({"key": "peer:%d" % int(peer), "kind": PILOT_KIND, "name": str(e.get("name", "?")), "peer": int(peer),
			"team": int(e.get("team", NO_TEAM)), "team_name": _make_group_name(int(e.get("team", NO_TEAM)), teams, map_config, PILOT_GROUP),
			"detail": LobbyCards.make_class_text(e), "ready": int(peer) == MatchFlow.HOST_ID or bool(e.get("ready", false)),
			"ping": LobbyPing.make_text(int(peer), my_id)})
	var taken := card_bots.map(func(b: Dictionary) -> String: return str(b.key))
	for member in LobbySettings.make_planned_members(settings):
		if taken.has(str(member.key)):
			continue
		rows.append({"key": str(member.key), "kind": BOT_KIND, "name": str(member.name), "peer": 0, "team": int(member.team),
			"team_name": _make_group_name(int(member.team), teams, map_config, COMPUTER_GROUP), "detail": str(member.kind),
			"ready": true, "ping": ""})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return [int(a.team), str(a.name).to_lower()] < [int(b.team), str(b.name).to_lower()])
	return rows


static func _make_group_name(team: int, teams: bool, map_config: Dictionary, fallback: String) -> String:
	return TeamList.make_team_name(team, map_config) if teams else fallback


## "Capture the Flag  -  Raindance" for the title bar.
static func make_title(settings: Dictionary) -> String:
	if str(settings.get("mode", "")) == "vs":
		return "%s  -  %s" % [LobbySettings.make_game_mode_label(settings), str(settings.get("map", ""))]
	return "%s  -  %s" % [str(LobbySettings.MODE_TITLES.get(settings.get("mode"), "Lobby")), str(settings.get("map", ""))]


## "7 / 24 pilots".
static func make_count_text(roster: Dictionary) -> String:
	return "%d / %d pilots" % [roster.size(), Net.max_players]


## Who has not readied up: the pilots (not the host) with `ready` false.
static func make_unready_peers(roster: Dictionary) -> Array:
	return roster.keys().filter(func(id: Variant) -> bool: return int(id) != MatchFlow.HOST_ID and not bool(roster[id].get("ready", false)))


## The header over the carousel: "Squad: Red (3/4)", "Squad (2)" or "Pilot".
static func make_squad_header(roster: Dictionary, settings: Dictionary, my_id: int, squad_size: int) -> String:
	if LobbySettings.is_team_match(settings):
		var team := int((roster.get(my_id, {}) as Dictionary).get("team", NO_TEAM))
		var name := TeamList.make_team_name(team, LobbySettings.make_map_config(settings))
		return "Squad: %s (%d)" % [name, squad_size]
	if is_cooperative(settings):
		return "Squad (%d)" % squad_size
	return "Pilots (%d)" % squad_size


## A key that changes when what the list shows changes (the widget rebuilds only then).
static func make_rows_key(rows: Array) -> String:
	return JSON.stringify(rows)
