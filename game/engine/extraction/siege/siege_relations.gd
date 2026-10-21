class_name SiegeRelations
extends RefCounted
## The truce of the siege: the factions drop their feuds ("everyone against the Cybrids"). Human factions become allied
## to each other, the players become neutral to them (rules cybrid_siege.relations), the Bioderm horde and the Cybrids
## stay hostile to everyone, and the pairs of players are left as they were.


## Sets TeamRelations for `teams` ({team: faction id}; "" for a player team). Returns the pairs it changed.
static func apply_truce(teams: Dictionary) -> int:
	var rules := CybridRules.section("relations")
	var changed := 0
	for a in teams:
		for b in teams:
			if int(a) >= int(b):
				continue
			var stance := make_stance(str(teams[a]), str(teams[b]), rules)
			if stance != "" and TeamRelations.make_stance(int(a), int(b)) != stance:
				TeamRelations.apply_stance(int(a), int(b), stance)
				changed += 1
	return changed


## The stance of the truce between two factions ("" = leave it as it is).
static func make_stance(a: String, b: String, rules: Dictionary) -> String:
	var kind_a := ExtractionFactions.kind_of(a) if a != "" else ""
	var kind_b := ExtractionFactions.kind_of(b) if b != "" else ""
	if _is_foe(kind_a) or _is_foe(kind_b):
		return TeamRelations.HOSTILE
	if a == "" and b == "":
		return ""
	if a == "" or b == "":
		return str(rules.get("player_stance", TeamRelations.NEUTRAL))
	return str(rules.get("humans", TeamRelations.ALLIED))


static func _is_foe(kind: String) -> bool:
	return (ExtractionRules.data().get("relations", {}).get("always_hostile_kinds", []) as Array).has(kind)
