class_name LobbyCards
extends RefCounted
## The data an OperatorCard shows, made from a roster entry, a computer-controlled member or a campaign wingman:
## {key, kind, name, you, host, ready, team, team_color, ping, infantry: {title, detail}, vehicle: {title, detail},
## note}. Pure functions; the card draws what it is given.

const INFANTRY_HEADER := "INFANTRY"
const VEHICLE_HEADER := "VEHICLE"
const NO_ARMOUR := "no soldier"
const NO_VEHICLE := "no vehicle"
const MAX_WEAPON_NAMES := 3
const YOU_NOTE := "you"
const BOT_TEXT := "Infantry bot"
const AI_TEXT := "AI unit"
## Labels over a platform whose model stands in for something the member does not have in that mode.
const ON_FOOT_LABEL := "ON FOOT"
const AI_PICK_LABEL := "AI PICKS IN BATTLE"


## The card of pilot `peer` (roster `entry`) as seen by `my_id`.
static func make_pilot_card(peer: int, entry: Dictionary, settings: Dictionary, my_id: int) -> Dictionary:
	var team := int(entry.get("team", LobbyModel.NO_TEAM))
	var teams := LobbySettings.is_team_match(settings)
	return {"key": "peer:%d" % peer, "kind": LobbyModel.PILOT_KIND, "peer": peer, "name": str(entry.get("name", "?")),
		"you": peer == my_id, "host": peer == MatchFlow.HOST_ID, "ready": peer == MatchFlow.HOST_ID or bool(entry.get("ready", false)),
		"team": team, "team_visible": teams, "team_color": TeamList.make_team_color(team) if teams else Color.TRANSPARENT,
		"ping": LobbyPing.make_text(peer, my_id), "infantry": make_infantry(entry, settings), "vehicle": make_vehicle(entry, settings),
		"models": make_models(entry, settings), "note": YOU_NOTE if peer == my_id else ""}


## The card of a computer-controlled member {key, name, team, kind}.
static func make_bot_card(member: Dictionary, settings: Dictionary) -> Dictionary:
	var teams := LobbySettings.is_team_match(settings)
	var is_vehicle := str(member.kind) == "AI vehicle"
	var none := {"title": INFANTRY_HEADER, "text": "", "detail": ""}
	return {"key": str(member.key), "kind": LobbyModel.BOT_KIND, "peer": 0, "name": str(member.name), "you": false, "host": false,
		"ready": true, "team": int(member.team), "team_visible": teams,
		"team_color": TeamList.make_team_color(int(member.team)) if teams else Color.TRANSPARENT, "ping": "",
		"infantry": none if is_vehicle else {"title": INFANTRY_HEADER, "text": BOT_TEXT, "detail": ""},
		"vehicle": {"title": VEHICLE_HEADER, "text": AI_TEXT, "detail": ""} if is_vehicle else none, "note": "",
		"models": make_bot_models(is_vehicle, settings)}


## What the ring stands on a pilot's platform: {infantry: {shape, skin}, vehicle: {vehicle, skin}} from his roster entry.
## Every member stands in both modes: a pilot without a soldier shows the match's default armour, one without a vehicle
## shows his soldier labelled ON FOOT.
static func make_models(entry: Dictionary, settings := {}) -> Dictionary:
	var armor_id := _make_armor_id(entry)
	var snapshot: Dictionary = entry.get("slot", {}) if entry.get("slot") is Dictionary else {}
	var body := str(snapshot.get("b", entry.get("infantry_body", "")))
	var skin := str(snapshot.get("s", entry.get("infantry_skin", "")))
	var infantry := make_default_infantry(settings)
	if armor_id != "":
		infantry = {"shape": body if body != "" else PlayerProfile.make_default_body(armor_id), "skin": skin,
			"armor": armor_id, "weapon": LobbyArmament.make_held_weapon(entry, armor_id)}
	var vehicle_id := _make_vehicle_id(entry)
	var vehicle := {"vehicle": vehicle_id, "skin": str(snapshot.get("hs", entry.get("herc_skin", ""))), "loadout": _make_loadout(entry)} if vehicle_id != "" else make_on_foot(infantry)
	return {"infantry": infantry, "vehicle": vehicle}


## A computer-controlled member: an infantry bot is a soldier in the match's light armour (ON FOOT in the vehicle mode);
## an AI vehicle is flown by such a soldier and shows the default vehicle, labelled as picked in battle.
static func make_bot_models(is_vehicle: bool, settings: Dictionary) -> Dictionary:
	var infantry := make_default_infantry(settings)
	if is_vehicle:
		return {"infantry": infantry, "vehicle": {"vehicle": MatchFlow.DEFAULT_VEHICLE, "skin": "", "label": AI_PICK_LABEL}}
	return {"infantry": infantry, "vehicle": make_on_foot(infantry)}


## The light armour soldier of the match's infantry game (or the first installed one): {shape, skin}, {} without infantry.
static func make_default_infantry(settings: Dictionary) -> Dictionary:
	var pack := str(settings.get(LobbySettings.INFANTRY_PACK_KEY, ""))
	var armor_id := InfantryCatalog.light_armor_id(pack if pack != "" else InfantryCatalog.make_default_pack())
	return {"shape": PlayerProfile.make_default_body(armor_id), "skin": "", "armor": armor_id,
		"weapon": LobbyArmament.make_held_weapon({}, armor_id)} if armor_id != "" else {}


## The vehicle-mode stand-in for a member on foot: his soldier, labelled.
static func make_on_foot(infantry: Dictionary) -> Dictionary:
	return infantry.merged({"label": ON_FOOT_LABEL}, true) if not infantry.is_empty() else {"label": ON_FOOT_LABEL}


## {title, text, detail} of the soldier: armour name and the first weapons.
static func make_infantry(entry: Dictionary, settings: Dictionary) -> Dictionary:
	if str(settings.get("mode", "")) == "campaign" and not entry.get("kit") is Dictionary and str(entry.get("infantry_armor", "")) == "":
		return {"title": INFANTRY_HEADER, "text": "", "detail": ""}   # a campaign mission flies a Herc
	var armor_id := _make_armor_id(entry)
	if armor_id == "":
		return {"title": INFANTRY_HEADER, "text": NO_ARMOUR, "detail": ""}
	var detail := ""
	if ExtractionRules.is_extraction(settings) and entry.get("kit") is Dictionary:
		detail = "%d kinds of item" % (entry.kit.get("items", []) as Array).size()
	elif entry.get("slot") is Dictionary:
		detail = make_weapon_text((entry.slot.get("w", []) as Array))
	return {"title": INFANTRY_HEADER, "text": make_armor_text(armor_id), "detail": detail}


## {title, text, detail} of the vehicle: its name and how many weapons it carries; in a raid the one called in.
static func make_vehicle(entry: Dictionary, settings: Dictionary) -> Dictionary:
	var id := _make_vehicle_id(entry)
	var v := Packs.vehicle(id)
	if v.is_empty():
		return {"title": VEHICLE_HEADER, "text": NO_VEHICLE, "detail": ""}
	var armed: int = (entry.get("loadout", []) as Array).filter(func(w: Variant) -> bool: return str(w) != "").size()
	var text := str(v.get("name", id))
	return {"title": VEHICLE_HEADER, "text": ("Call-in: " + text) if ExtractionRules.is_extraction(settings) else text,
		"detail": "%d weapon%s" % [armed, "" if armed == 1 else "s"] if armed > 0 else ""}


## "Medium armour" for the compact list, the vehicle's name when the entry has no soldier.
static func make_class_text(entry: Dictionary) -> String:
	var armor_id := _make_armor_id(entry)
	if armor_id != "":
		return str(InfantryCatalog.armor(armor_id).get("name", armor_id))
	return str(Packs.vehicle(_make_vehicle_id(entry)).get("name", ""))


static func make_armor_text(armor_id: String) -> String:
	var a := InfantryCatalog.armor(armor_id)
	return str(a.get("name", armor_id)) if not a.is_empty() else armor_id


## "Disc Launcher, Chaingun" (the first MAX_WEAPON_NAMES of weapon ids).
static func make_weapon_text(weapon_ids: Array) -> String:
	var names: PackedStringArray = []
	for id in weapon_ids.slice(0, MAX_WEAPON_NAMES):
		var w := Packs.weapon(str(id))
		names.append(str(w.get("display_name", w.get("name", id))))
	return ", ".join(names)


## The weapon ids on the hardpoints: the slot's loadout, else the roster's.
static func _make_loadout(entry: Dictionary) -> Array:
	if entry.get("slot") is Dictionary and not (entry.slot.get("hl", []) as Array).is_empty():
		return CharacterSlot.make_strings(entry.slot.hl)
	return CharacterSlot.make_strings(entry.get("loadout", []))


static func _make_armor_id(entry: Dictionary) -> String:
	if entry.get("kit") is Dictionary and str(entry.kit.get("armor", "")) != "":
		return str(entry.kit.armor)
	return str(entry.get("infantry_armor", ""))


static func _make_vehicle_id(entry: Dictionary) -> String:
	if entry.get("slot") is Dictionary and str(entry.slot.get("v", "")) != "":
		return str(entry.slot.v)
	return str(entry.get("vehicle", ""))
