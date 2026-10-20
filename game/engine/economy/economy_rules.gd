class_name EconomyRules
extends RefCounted
## The economy's design values (res://engine/economy/economy_rules.json; docs/design/lobby_loadout_economy.md
## section 2.5): start credits, unlock prices, the free set, earning per mode, goals, and the "options" block that
## holds the answers to the doc's open questions (section 13). They are the remake's own numbers.

const FILE := "res://engine/economy/economy_rules.json"
const FALLBACK_MODE_KEY := "vs"
const SOLO_MODE_KEY := "solo"
const EXTRACTION_KEY := "extraction"
const CAMPAIGN_COOP_KEY := "campaign.coop"
const KEY_SEPARATOR := "."

static var _data := {}
static var _warned := {}


static func data() -> Dictionary:
	if _data.is_empty():
		var d = JSON.parse_string(FileAccess.get_file_as_string(FILE))
		if not d is Dictionary:
			push_error("EconomyRules: cannot read %s" % FILE)
			d = {}
		_data = d
	return _data


## Drops the cached table (tests).
static func reload() -> void:
	_data = {}
	_warned = {}


static func currency() -> String:
	return str(data().get("currency", "cr"))


static func slot_count() -> int:
	return maxi(int(data().get("slot_count", 3)), 1)


static func start_credits() -> int:
	return int(data().get("start_credits", 0))


static func rebuy_price() -> int:
	return int(data().get("rebuy_price", 100))


static func min_price() -> int:
	return int(data().get("min_price", 1))


static func rebuy_kinds() -> Array:
	return data().get("rebuy_kinds", [])


static func make_multiplier(kind: String) -> float:
	return float((data().get("unlock_multiplier", {}) as Dictionary).get(kind, 1.0))


## The fixed base price of a kind that has one (skins, bodies); 0 = priced from the catalog.
static func make_flat_base(kind: String) -> int:
	return int((data().get("flat_base_price", {}) as Dictionary).get(kind, 0))


static func make_armor_base(size: String) -> int:
	var table: Dictionary = data().get("armor_base_by_size", {})
	return int(table.get(size, table.get("light", 0)))


static func vehicle_base_range() -> Array:
	return data().get("vehicle_base_range", [0, 0])


static func free_unlocks() -> Dictionary:
	return data().get("free_unlocks", {})


static func goals() -> Dictionary:
	return data().get("goals", {})


static func earn() -> Dictionary:
	return data().get("earn", {})


## An answer to an open question of the design doc (the "options" block).
static func option(key: String) -> Variant:
	return (data().get("options", {}) as Dictionary).get(key)


## "1,240 cr".
static func make_money_text(amount: int) -> String:
	var digits := str(absi(amount))
	var out := ""
	for i in digits.length():
		if i > 0 and (digits.length() - i) % 3 == 0:
			out += ","
		out += digits[i]
	return "%s%s %s" % ["-" if amount < 0 else "", out, currency()]


## The earn table key that applies to match `settings`: "<mode>.<game_mode>", else "<mode>", else "vs" (a warning
## once). An offline session earns as "solo" except extraction (loot pays there).
static func make_mode_key(settings: Dictionary) -> String:
	var mode := str(settings.get("mode", ""))
	if mode == ExtractionRules.MODE:
		return EXTRACTION_KEY
	if bool(settings.get("solo", false)):
		return SOLO_MODE_KEY
	if mode == "campaign":
		return CAMPAIGN_COOP_KEY if bool(settings.get("coop", false)) else SOLO_MODE_KEY
	var table: Dictionary = earn().get("modes", {})
	var game_mode := str(settings.get("game_mode", ""))
	var candidates := [mode]
	if game_mode != "":
		candidates.push_front(mode + KEY_SEPARATOR + game_mode)
	for key in candidates:
		if table.has(key):
			return key
	_warn_once("EconomyRules: no earn entry for mode '%s' (game mode '%s'), using '%s'" % [mode, game_mode, FALLBACK_MODE_KEY])
	return FALLBACK_MODE_KEY


## The earn row of `mode_key`; a key the table lacks falls back to its family ("vs.x" -> "vs", else "vs").
static func make_earn_row(mode_key: String) -> Dictionary:
	var table: Dictionary = earn().get("modes", {})
	for key in [mode_key, mode_key.get_slice(KEY_SEPARATOR, 0), FALLBACK_MODE_KEY]:
		if table.has(key):
			return table[key]
	return {}


static func _warn_once(text: String) -> void:
	if not _warned.has(text):
		_warned[text] = true
		push_warning(text)
