class_name LobbyText
## The LAN lobby's texts: what to do next (per mode and role) and one line per pilot.

const HOST_CAMPAIGN := "Co-op campaign - you host it. 1. Pick your Herc from the campaign garage (Hangar to refit). " \
	+ "2. Wait until every pilot shows READY. 3. Press Start mission. Pilots who join later wait for the next mission."
const CLIENT_CAMPAIGN := "Co-op campaign - the host runs the campaign. 1. Pick your Herc from the host's garage below. " \
	+ "2. Press Ready (bottom right). The host starts the mission when every pilot is ready."
const HOST_MATCH := "Set up your Herc and soldier, then press Start match once every pilot shows READY."
const CLIENT_MATCH := "Set up your Herc and soldier, then press Ready (bottom right). The host starts the match."
const HOST_TEAMS := " Pick a team for any pilot in the team list."
const CLIENT_TEAMS := " Pick your team in the team list."


## What the local pilot does next in a lobby with `settings`.
static func make_instructions(settings: Dictionary, is_host: bool) -> String:
	if settings.get("mode") == "campaign":
		return HOST_CAMPAIGN if is_host else CLIENT_CAMPAIGN
	var text := HOST_MATCH if is_host else CLIENT_MATCH
	if LobbySettings.is_team_match(settings):
		text += HOST_TEAMS if is_host else CLIENT_TEAMS
	return text


## "Client  -  Raptor  -  Team 2   READY" (the host is always ready; a team only in a team match).
static func make_pilot_text(id: int, e: Dictionary, settings: Dictionary) -> String:
	var is_host := id == MatchFlow.HOST_ID
	var v := Packs.vehicle(str(e.get("vehicle", "")))
	var ride := str(v.get("name", e.get("vehicle", "")))
	if ExtractionRules.is_extraction(settings) and e.get("kit") is Dictionary:
		ride = ExtractionScreenText.make_armor_name(str(e.kit.get("armor", "")))
	var team := ""
	if LobbySettings.is_team_match(settings):
		var t := int(e.get("team", TeamAssignment.UNASSIGNED))
		t = t if t >= 0 and t < LobbySettings.make_team_count(settings) else TeamAssignment.UNASSIGNED
		team = "  -  %s" % TeamList.make_team_name(t, LobbySettings.make_map_config(settings))
	var state := "HOST" if is_host else ("READY" if bool(e.get("ready", false)) else "not ready")
	return "%s  -  %s%s   %s" % [e.get("name", "?"), ride, team, state]
