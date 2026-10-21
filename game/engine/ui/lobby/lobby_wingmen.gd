class_name LobbyWingmen
extends RefCounted
## The campaign wingmen as lobby cards (docs/design/lobby_loadout_economy.md section 5; open question O9). A single
## player campaign takes up to Session.wingman_slots() wingmen from its garage: Earthsiege (the squad maximum) and
## Earthsiege 2 (the mission's group) let the pilot pick which garage Herc flies each slot and arm them in the
## Hangar; Starsiege missions bring their own squadmates (no slots: one locked card). A co-op campaign has no
## wingmen, and an on-foot campaign (Aerial Assault) has none.

const KIND := "wingman"
const STARSIEGE_PACK := "starsiege"
const FIXED_KEY := "wingman:fixed"
const EMPTY_TEXT := "(empty slot)"
const FIXED_TEXT := "Mission squadmates"
const FIXED_NOTE := "set by the mission"
const EDIT_NOTE := "Enter / right click / pad X: choose"


## True when the lobby of `settings` is a single player campaign with a garage to draw wingmen from.
static func is_available(settings: Dictionary) -> bool:
	return str(settings.get("mode", "")) == "campaign" and Session.has_campaign() and not Session.coop and Session.garage() != null


## Garage wingman slots of the next mission (0: fixed squadmates, a co-op campaign or none).
static func make_slot_count(settings: Dictionary) -> int:
	return Session.wingman_slots() if is_available(settings) else 0


## The cards of the wingmen: one per slot, or the locked card of a campaign whose missions bring their own squad.
static func make_cards(settings: Dictionary) -> Array:
	if not is_available(settings):
		return []
	var slots := make_slot_count(settings)
	if slots == 0:
		return [_make_fixed_card()] if _brings_own_squadmates() else []
	var g := Session.garage()
	var out := []
	var herc_indices := SquadRoster.make_slots(g, slots)
	for k in slots:
		out.append(_make_slot_card(g, k, int(herc_indices[k])))
	return out


## [{index, text}] a slot can take: "no wingman" (-1) then the eligible garage Hercs.
static func make_choices() -> Array:
	var g := Session.garage()
	var out := [{"index": -1, "text": EMPTY_TEXT}]
	for i in SquadRoster.make_slot_candidates(g):
		out.append({"index": i, "text": "%s  -  %s" % [SquadRoster.make_pilot_name(g, i, Net.player_name), GaragePicker.make_entry_label(g.vehicles[i])]})
	return out


## The garage Herc index flying wingman slot `slot` (-1 = none).
static func make_herc_index(slot: int) -> int:
	return int(SquadRoster.make_slots(Session.garage(), make_slot_count(Net.settings))[slot])


static func apply_slot(slot: int, herc_index: int) -> void:
	SquadRoster.apply_slot(Session.garage(), slot, make_slot_count(Net.settings), herc_index)
	Session.autosave()


static func _make_slot_card(g: Garage, slot: int, herc_index: int) -> Dictionary:
	var title := "Wingman %d" % (slot + 1)
	if herc_index < 0:
		return _make_card("wingman:%d" % slot, title, {"title": LobbyCards.VEHICLE_HEADER, "text": EMPTY_TEXT, "detail": ""}, EDIT_NOTE)
	var e: Dictionary = g.vehicles[herc_index]
	var armed := Garage.make_armed_count(e)
	return _make_card("wingman:%d" % slot, SquadRoster.make_pilot_name(g, herc_index, Net.player_name),
		{"title": LobbyCards.VEHICLE_HEADER, "text": GaragePicker.make_entry_name(e),
		"detail": "%d/%d armed" % [armed, (e.loadout as Array).size()]}, EDIT_NOTE, str(e.vehicle), CharacterSlot.make_strings(e.loadout))


static func _make_fixed_card() -> Dictionary:
	return _make_card(FIXED_KEY, FIXED_TEXT, {"title": LobbyCards.VEHICLE_HEADER, "text": FIXED_NOTE, "detail": ""}, "locked")


static func _make_card(key: String, name: String, vehicle: Dictionary, note: String, vehicle_id := "", loadout := []) -> Dictionary:
	var vehicle_model := {"vehicle": vehicle_id, "skin": "", "loadout": loadout} if vehicle_id != "" else {"label": EMPTY_TEXT.to_upper() if note != "locked" else FIXED_TEXT.to_upper()}
	return {"models": {"infantry": LobbyCards.make_default_infantry({}), "vehicle": vehicle_model}, "key": key, "kind": KIND, "peer": 0, "name": name, "you": false, "host": false, "ready": true, "team": 0,
		"team_visible": false, "team_color": Color.TRANSPARENT, "ping": "", "state": "locked" if note == "locked" else "",
		"infantry": {"title": LobbyCards.INFANTRY_HEADER, "text": "", "detail": ""}, "vehicle": vehicle,
		"note": "" if note == "locked" else note}


## Starsiege missions bring their own squadmates (the scripts' playerSquad); a mission of the garage's games with no slots
## simply flies solo, and an on-foot campaign has no Herc wingmen at all.
static func _brings_own_squadmates() -> bool:
	return Session.campaign_pack(Session.campaign) == STARSIEGE_PACK
