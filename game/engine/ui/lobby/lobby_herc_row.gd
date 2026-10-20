class_name LobbyHercRow
extends VBoxContainer
## The campaign pilot's Herc in the lobby (docs/design/lobby_loadout_economy.md section 7.3): the host and a single
## player choose from their campaign's garage, a co-op client only from the copy of the host's garage in the lobby
## settings (MatchFlow.publish_campaign_offer) - never from his own save. A GaragePicker without the 3D hangar; the
## Hangar button of Game Options opens the Hangar screen. Rebuilt only when the choices change.
##   refresh(settings, select_garage)   entry_changed(entry: {vehicle, loadout, garage})

signal entry_changed(entry: Dictionary)

const WAITING_FOR_OFFER := "Waiting for the host's campaign ..."
const NO_CAMPAIGN := "No campaign is running."
const ISSUED_SOLDIER := "The mission issues your soldier."

var picker: GaragePicker
var _key := "-"


## What the choices depend on: the host's (or single player's) own garage, or a client's copy of the offer.
static func make_choice_key(settings: Dictionary) -> String:
	if Net.is_host():
		return "own|" + str(Session.has_campaign()) + "|" + MatchFlow.make_mission_heading()
	return "offer|" + JSON.stringify(settings.get(MatchFlow.CAMPAIGN_OFFER, {}))


func refresh(settings: Dictionary, select_garage := false) -> void:
	var key := make_choice_key(settings)
	if key == _key:
		return
	_key = key
	for c in get_children():
		remove_child(c)
		c.queue_free()
	picker = null
	if Net.is_host():
		_add_host_choice(select_garage)
	else:
		_add_offer_choice(settings.get(MatchFlow.CAMPAIGN_OFFER, {}))


func _add_host_choice(select_garage: bool) -> void:
	if not Session.has_campaign() or Session.garage() == null:
		add_child(Widgets.paragraph(ISSUED_SOLDIER if Session.has_campaign() else NO_CAMPAIGN, "DimLabel"))
		return
	_add_picker(GaragePicker.new(null, Session.garage(), Session.mission_herc(), Callable()))
	if select_garage:
		picker.select_garage()
	entry_changed.emit(picker.entry())


func _add_offer_choice(offer: Dictionary) -> void:
	if not offer.get("garage") is Dictionary or (offer.garage as Dictionary).is_empty():
		add_child(Widgets.paragraph(WAITING_FOR_OFFER, "DimLabel"))
		return
	add_child(Widgets.paragraph(str(offer.get("heading", "")), "DimLabel"))
	_add_picker(GaragePicker.new(null, Garage.from_dict(offer.garage), offer.get("mission_herc", {}), Callable()))
	entry_changed.emit(picker.entry())


func _add_picker(p: GaragePicker) -> void:
	picker = p
	picker.changed.connect(func(entry: Dictionary) -> void: entry_changed.emit(entry))
	add_child(picker)
