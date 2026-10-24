class_name RaidTeams
extends RefCounted
## Which team each group of pilots plays on in a persistent raid (a dedicated extraction server): a party is one group, a
## pilot who came alone is a group of his own. Teams are the rules' player teams (player_team_base, then the next free slot);
## a slot comes back when its group has nobody left, so a server that runs for weeks never runs into the factions' teams
## (faction_team_base). Teammates are allies of each other (TeamRelations), which is what lets them revive each other.
##   allocate("p:K7QWM") -> 10    allocate("s:42") -> 11    release_unused(["p:K7QWM"]) frees "s:42"'s slot

var _slots := {}   # group key -> slot


## The group key of a pilot: his party's, else his own.
static func make_group_key(peer: int, entry: Dictionary) -> String:
	var party_id := PartyRoster.make_party_id(entry)
	return "p:%s" % party_id if party_id != "" else "s:%d" % peer


static func make_first_team() -> int:
	return int(ExtractionRules.data().get("player_team_base", 10))


static func make_slot_count() -> int:
	return int(ExtractionRules.data().get("faction_team_base", 300)) - make_first_team()


## The team of `group`, taking the lowest free slot the first time.
func allocate(group: String) -> int:
	if not _slots.has(group):
		_slots[group] = _find_free_slot()
	return make_first_team() + int(_slots[group])


func team_of(group: String) -> int:
	return make_first_team() + int(_slots[group]) if _slots.has(group) else -1


## Frees the slots of every group not in `live`.
func release_unused(live: Array) -> void:
	for group in _slots.keys():
		if not live.has(group):
			_slots.erase(group)


func size() -> int:
	return _slots.size()


func _find_free_slot() -> int:
	var used := _slots.values()
	for slot in make_slot_count():
		if not used.has(slot):
			return slot
	push_error("RaidTeams: all %d player teams are taken" % make_slot_count())
	return make_slot_count() - 1
