class_name TeamAssignment
## Who plays on which team in a team match (lobby settings `teams`): pilots start UNASSIGNED (team -1) until they
## pick a team or the host places them; "Assign all" fills the smallest team first, counting the infantry bots
## (which InfantryBots deals round the teams); "Shuffle teams" deals every pilot afresh. Pure functions: the lobby
## applies the result with Net.set_my_info / Net.assign_team.

const UNASSIGNED := -1


## {peer: team} for every unassigned pilot of `roster`, smallest team first (bots counted), in peer order.
static func make_assign_all(roster: Dictionary, settings: Dictionary) -> Dictionary:
	var sizes := make_team_sizes(roster, settings)
	var out := {}
	for peer in _sorted_peers(roster):
		if int(roster[peer].get("team", UNASSIGNED)) == UNASSIGNED:
			var team := sizes.find(sizes.min())
			out[peer] = team
			sizes[team] += 1
	return out


## {peer: team} dealing every pilot afresh in a random order (bots stay where they are).
static func make_shuffle(roster: Dictionary, settings: Dictionary, rng: RandomNumberGenerator) -> Dictionary:
	var cleared := {}
	for peer in roster:
		cleared[peer] = {"team": UNASSIGNED}
	var order := _sorted_peers(roster)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp
	var sizes := make_team_sizes(cleared, settings)
	var out := {}
	for peer in order:
		var team := sizes.find(sizes.min())
		out[peer] = team
		sizes[team] += 1
	return out


## Members per team (pilots of `roster` plus the planned infantry bots and AI units), one entry per team of `settings`.
static func make_team_sizes(roster: Dictionary, settings: Dictionary) -> Array:
	var sizes := []
	sizes.resize(LobbySettings.make_team_count(settings))
	sizes.fill(0)
	for peer in roster:
		_count(sizes, int(roster[peer].get("team", UNASSIGNED)))
	for member in LobbySettings.make_planned_members(settings):
		_count(sizes, int(member.team))
	return sizes


## Names of the pilots of `roster` without a team ("" list in a match without teams).
static func make_unassigned_names(roster: Dictionary, settings: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	if not LobbySettings.is_team_match(settings):
		return out
	for peer in _sorted_peers(roster):
		if int(roster[peer].get("team", UNASSIGNED)) == UNASSIGNED:
			out.append(str(roster[peer].get("name", "?")))
	return out


static func _count(sizes: Array, team: int) -> void:
	if team >= 0 and team < sizes.size():
		sizes[team] += 1


static func _sorted_peers(roster: Dictionary) -> Array:
	var peers := roster.keys()
	peers.sort()
	return peers
