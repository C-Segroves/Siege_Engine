class_name CockpitFit
extends RefCounted
## Which cockpit / HUD a vehicle gets (docs/formats/cockpit.md section 9, "Cockpit per vehicle"). Most
## vehicles were never playable in their game, or their game had no cockpit for them: they get the best-fitting
## original UI, chosen by one fixed rule, first match wins:
##   1. native        the vehicle's own cockpit (`def.cockpit` names a layout in its pack: Earthsiege 1 / 2 Hercs
##                    and the Razor).
##   2. game UI       the UI the vehicle's game gives this kind of vehicle (`cockpit/fit.json` of its pack, written
##                    by tools/cockpit_hud_layouts.py): by vehicle, by kind + side, by side, by kind, then the pack's
##                    default (Battledrome HUD, Starsiege HUD, the Tribes vehicle HUDs). Reported as "native HUD"
##                    for the kinds the original let the player pilot (fit.json "native_kinds": Battledrome Hercs,
##                    Starsiege Hercs and tanks, the Tribes vehicles), else "game UI" (Starsiege flyers).
##   3. same-game     the cockpit of the same game's piloted vehicle closest in mass, flyers preferring a flyer's
##                    cockpit (Earthsiege 1 / 2 Cybrids and the Landskimmer: the Herc / Razor cockpits).
##   4. plain HUD     the remake's own HUD (hud.gd), when the game has no cockpit data installed.
## A flyer whose UI has no altimeter gets the remake's flight gauges on top (CockpitMeters).
## The choice: {rule, pack, layout, reason} (layout "" = plain HUD).

const RULE_NATIVE := "native"
## Rule 2 for a kind of vehicle the original let the player pilot (fit.json "native_kinds"): its own HUD.
const RULE_NATIVE_HUD := "native HUD"
const RULE_GAME_UI := "game UI"
const RULE_SAME_GAME := "same-game best fit"
const RULE_PLAIN := "plain HUD"
const RULE_ON_FOOT := "on foot"
const FIT_FILE := "cockpit/fit.json"
## Kind mismatch (walker vs flyer) outweighs any mass difference.
const KIND_MISMATCH_COST := 1.0e9


## The cockpit choice for vehicle definition `def` (Packs.vehicle()).
static func make_choice(def: Dictionary) -> Dictionary:
	var pack := str(def.get("pack", ""))
	if str(def.get("category", "")) == "infantry":
		return _make(RULE_ON_FOOT, pack, "", "a soldier: the infantry HUD")
	var own := str(def.get("cockpit", ""))
	if own != "" and has_layout(pack, own):
		return _make(RULE_NATIVE, pack, own, "its own cockpit")
	var from_game := _make_game_ui_choice(def, pack)
	if not from_game.is_empty():
		return from_game
	var nearest := _make_same_game_choice(def, pack)
	if not nearest.is_empty():
		return nearest
	return _make(RULE_PLAIN, pack, "", "no cockpit data for this game")


## True when vehicle `def` gets a cockpit or HUD layout (anything but the plain HUD / on foot).
static func has_cockpit(def: Dictionary) -> bool:
	return str(make_choice(def).layout) != ""


static func _make(rule: String, pack: String, layout: String, reason: String) -> Dictionary:
	return {"rule": rule, "pack": pack, "layout": layout, "reason": reason}


static func has_layout(pack: String, layout: String) -> bool:
	return FileAccess.file_exists(Assets.path("cockpit/layout/%s.json" % layout, pack))


## Rule 2: the pack's fit.json, most specific key first.
static func _make_game_ui_choice(def: Dictionary, pack: String) -> Dictionary:
	var fit = Assets.load_json(FIT_FILE, pack)
	if not (fit is Dictionary):
		return {}
	var kind := make_kind(def)
	var side := str(def.get("side", "herc"))
	var candidates := [
		[fit.get("by_vehicle", {}).get(make_vehicle_key(def), ""), "the game's UI for this vehicle"],
		[fit.get("by_kind_side", {}).get("%s/%s" % [kind, side], ""), "the game's %s UI for a %s" % [side, kind]],
		[fit.get("by_side", {}).get(side, ""), "the game's %s UI" % side],
		[fit.get("by_kind", {}).get(kind, ""), "the game's %s UI" % kind],
		[fit.get("default", ""), "the game's UI"],
	]
	var rule := RULE_NATIVE_HUD if kind in fit.get("native_kinds", []) else RULE_GAME_UI
	for c in candidates:
		if str(c[0]) != "" and has_layout(pack, str(c[0])):
			return _make(rule, pack, str(c[0]), str(c[1]))
	return {}


## Rule 3: the same game's piloted vehicle with a native cockpit closest in mass (a flyer prefers flyers).
static func _make_same_game_choice(def: Dictionary, pack: String) -> Dictionary:
	var best: Dictionary = {}
	var best_cost := INF
	for v in Packs.vehicles.values():
		var ck := str(v.get("cockpit", ""))
		if v.get("pack", "") != pack or ck == "" or not has_layout(pack, ck):
			continue
		var cost := _make_fit_cost(def, v)
		if cost < best_cost or (cost == best_cost and str(v.id) < str(best.get("id", ""))):
			best = v
			best_cost = cost
	if best.is_empty():
		return {}
	return _make(RULE_SAME_GAME, pack, str(best.cockpit),
		"closest %s of its game: %s" % ["flyer" if bool(best.get("flyer", false)) else "Herc", best.get("name", best.id)])


static func _make_fit_cost(def: Dictionary, candidate: Dictionary) -> float:
	var cost := absf(float(def.get("mass", 0.0)) - float(candidate.get("mass", 0.0)))
	if bool(def.get("flyer", false)) != bool(candidate.get("flyer", false)):
		cost += KIND_MISMATCH_COST
	return cost


## "herc" | "tank" | "flyer" (the Starsiege / Tribes `kind`; 3Space vehicles are Hercs or flyers).
static func make_kind(def: Dictionary) -> String:
	var k := str(def.get("kind", ""))
	if k != "":
		return k
	return "flyer" if bool(def.get("flyer", false)) else "herc"


## Vehicle id without its pack ("tribes2:SHRIKE" -> "SHRIKE").
static func make_vehicle_key(def: Dictionary) -> String:
	var id := str(def.get("id", ""))
	var i := id.find(":")
	return id.substr(i + 1) if i >= 0 else id
