extends LauncherScreen
## Armory / skirmish: pick a Herc and its weapons in the hangar, your soldier (armour, body, skin; the parked Herc
## stays yours to board), a battlefield and how many infantry bots (Tribes soldiers, InfantryBots) join, then fight AI.
## The Herc and loadout are remembered in the launcher context for the LAN lobby.

var _map: MapPicker
var _bots: HSlider
var _pilot: PilotPicker


func open(_args: Dictionary) -> void:
	set_page_title("armory  -  skirmish")
	set_back("Back", router.back)
	set_primary("Start skirmish", _start)
	var selector := add_herc_selector()
	selector.vehicle_changed.connect(func(id: String) -> void: router.context.vehicle = id)
	selector.loadout_changed.connect(func(lo: Array) -> void: router.context.loadout = lo)
	selector.setup(router.context.vehicle, router.context.loadout, CampaignAvailability.make_open_context("skirmish"))
	_pilot = PilotPicker.new("", true)
	_pilot.preview_requested.connect(_preview_body)
	content.add_child(_pilot)
	_map = MapPicker.new("Map")
	content.add_child(_map)
	_bots = Widgets.slider(0, InfantryBots.MAX_BOTS, 0)
	content.add_child(OptionRow.new("Infantry bots", _bots).with_value_readout())
	if InfantryCatalog.make_default_pack() != "":
		content.add_child(Widgets.button("Extraction raid instead (stash, shop, loadout)", func() -> void: router.go("extraction")))


func _start() -> void:
	var cfg := MatchFlow.make_skirmish_config(herc_selector.vehicle_id(), herc_selector.loadout(), _map.selected_config())
	cfg[InfantryBots.CONFIG_KEY] = int(_bots.value)
	if _pilot.pack() != "":
		cfg[LobbySettings.INFANTRY_PACK_KEY] = _pilot.pack()
	cfg.roster[MatchFlow.HOST_ID].merge(_pilot.make_fields(herc_selector.vehicle_id()), true)
	launcher().start_battle(cfg)


## The soldier choice changed: the hangar shows that body until the Herc changes again.
func _preview_body(shape_id: String, skin_id: String) -> void:
	if hangar != null and is_inside_tree():
		hangar.apply_skin(skin_id)
		hangar.show_herc(shape_id)
