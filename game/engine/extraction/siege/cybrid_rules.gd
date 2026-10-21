class_name CybridRules
extends RefCounted
## The numbers and texts of the Cybrid siege, Varuna's Fall easter egg: extraction_rules.json "cybrid_siege" (timings,
## waves, safe area, exfil closing, texts) and the map's own "cybrid_siege" (relay sites, fragment lines and spots).
## Everything the siege does is read from here; nothing is a code constant (docs/design/cybrid_siege.md).


static func data() -> Dictionary:
	return ExtractionRules.data().get("cybrid_siege", {})


static func section(key: String) -> Dictionary:
	var s = data().get(key, {})
	return s if s is Dictionary else {}


static func text(group: String, key: String) -> String:
	return str(section(group).get("texts", {}).get(key, ""))


## The map's siege layout (built map "cybrid_siege"); {} on every other map.
static func map_data(built: Dictionary) -> Dictionary:
	var m = built.get("map")
	var s = m.get("cybrid_siege", {}) if m is Dictionary else {}
	return s if s is Dictionary else {}


## True when the map carries the siege: three relays on sites it has.
static func is_available(built: Dictionary) -> bool:
	return (map_data(built).get("relays", []) as Array).size() >= 3 and not data().is_empty()


## The Cybrids' team (the rules' Cybrid faction slot after the factions with sites); -1 without such a faction.
static func make_cybrid_team() -> int:
	var wanted := str(data().get("cybrid_faction", "cybrid"))
	var ids: Array = ExtractionRules.factions().map(func(f: Dictionary) -> String: return str(f.id))
	return ExtractionFactions.make_team(ids.find(wanted)) if ids.has(wanted) else -1


## Seconds with `pair` = [first, last] of a rule that slides from the first to the last as `n` runs 0..1.
static func make_slide(pair: Array, fraction: float) -> float:
	return lerpf(float(pair[0]), float(pair[1]), clampf(fraction, 0.0, 1.0))
