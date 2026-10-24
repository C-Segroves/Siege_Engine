class_name PartyRoster
extends RefCounted
## The party a pilot claims in his roster entry (Net roster key "party": {id, size}, sent by PartyFlow when a Go brings him to
## a server). A dedicated server uses it to keep a party together: one team in versus and co-op, one team and one transport in a
## raid. It is a convenience of friends on a trusted server, not a security feature: anybody can claim any party id.


## The party code of `entry`, "" for a pilot who came alone.
static func make_party_id(entry: Dictionary) -> String:
	var party: Variant = entry.get("party")
	return str((party as Dictionary).get("id", "")) if party is Dictionary else ""


## How many members the pilot's party joined with (1 without a party).
static func make_party_size(entry: Dictionary) -> int:
	var party: Variant = entry.get("party")
	return clampi(int((party as Dictionary).get("size", 1)), 1, Net.MAX_PLAYERS) if party is Dictionary else 1


## {party code: [peer, ...]} of the parties with at least two pilots in `roster`.
static func make_groups(roster: Dictionary) -> Dictionary:
	var by_party := {}
	for peer in roster:
		var id := make_party_id(roster[peer])
		if id != "":
			by_party[id] = by_party.get(id, []) + [peer]
	for id in by_party.keys():
		if (by_party[id] as Array).size() < 2:
			by_party.erase(id)
	return by_party
