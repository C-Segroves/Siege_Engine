class_name ExtractionRules
extends RefCounted
## The extraction mode's design values (res://engine/extraction/extraction_rules.json; docs/design/extraction.md):
## timers, transports, map layout, carrying capacity, item kinds and prices, cache loot tables, faction rosters and
## relations. They are the remake's own numbers: items, prices and rosters are built from the user's installed packs
## at run time (ExtractionItems, ExtractionFactions).
## The test flag FAST_FLAG (or config "extraction_fast") swaps in the short timers and approach distance.

const FILE := "res://engine/extraction/extraction_rules.json"
const FAST_FLAG := "--extraction-fast"
const FAST_CONFIG_KEY := "extraction_fast"
const MODE := "extraction"

static var _data := {}


## The whole rules table.
static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("ExtractionRules: cannot read %s" % FILE)
			d = {}
		_data = d
	return _data


## True when a raid can be played: it is fought on foot, so a soldier pack (Tribes / Tribes 2) must be installed.
## Every place that offers the mode asks this (launcher menu, host screen, map game modes).
static func is_available() -> bool:
	return InfantryCatalog.make_default_pack() != ""


static func is_extraction(config: Dictionary) -> bool:
	return str(config.get("mode", "")) == MODE


## True when the short test timers apply (FAST_FLAG on the command line or config FAST_CONFIG_KEY).
static func is_fast(config: Dictionary) -> bool:
	return bool(config.get(FAST_CONFIG_KEY, false)) or OS.get_cmdline_user_args().has(FAST_FLAG)


## A timer in seconds (timers.<key>, or fast_timers.<key> in fast mode).
static func timer(config: Dictionary, key: String) -> float:
	var table: Dictionary = data().get("fast_timers" if is_fast(config) else "timers", {})
	return float(table.get(key, (data().get("timers", {}) as Dictionary).get(key, 0.0)))


static func transport() -> Dictionary:
	return data().get("transport", {})


## Metres from an exfil zone to where its transport appears.
static func approach_distance(config: Dictionary) -> float:
	return float(transport().get("fast_approach_m" if is_fast(config) else "approach_m", 500.0))


static func map_rules() -> Dictionary:
	return data().get("map", {})


## {slots, kg} a soldier of armour size `size` (light / medium / heavy) can carry.
static func capacity(size: String) -> Dictionary:
	var table: Dictionary = data().get("capacity", {})
	return table.get(size, table.get("light", {"slots": 10, "kg": 30.0}))


static func item_kind(kind: String) -> Dictionary:
	return (data().get("item_kinds", {}) as Dictionary).get(kind, {})


static func cache(kind: String) -> Dictionary:
	return (data().get("caches", {}) as Dictionary).get(kind, {})


static func factions() -> Array:
	return data().get("factions", [])


static func currency() -> String:
	return str(data().get("currency", "cr"))


## "1 250 cr".
static func make_money_text(amount: int) -> String:
	return "%s %s" % [str(amount), currency()]


## A random int in the inclusive range [lo, hi] given as a two-element array.
static func roll_range(rng: RandomNumberGenerator, pair: Array) -> int:
	if pair.size() < 2:
		return 0
	return rng.randi_range(int(pair[0]), int(pair[1]))


## Drops the cached table (tests).
static func reload() -> void:
	_data = {}
