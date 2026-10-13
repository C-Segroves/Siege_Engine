extends LauncherScreen
## LAN lobby: the match settings and what to do next, your name, your Herc and loadout in the hangar, your soldier
## (armour, body, skin: PilotPicker), the teams of a team match (TeamList) and the pilots with their ready state.
## The host's Start is disabled until every connected pilot is ready (the footer names who is not); clients press
## Ready.
## Co-op campaign: the host picks from its campaign's garage (GaragePicker, Hangar screen) and
## publishes what the campaign offers (MatchFlow.publish_campaign_offer); a client picks only from
## that offer - never from its own single-player campaign. The host starts the match; clients mark
## themselves ready. The settings reach a client after it opens the lobby, so the summary and the
## Herc choice follow them.

const WAITING_FOR_OFFER := "Waiting for the host's campaign ..."
const START_MATCH := "Start match"
const START_MISSION := "Start mission"

var _summary: Label
var _instructions: Label
var _herc_box: VBoxContainer
var _pilot_box: VBoxContainer
var _teams: TeamList
var _roster: VBoxContainer
var _choice_key := "-"
var _pilot_key := "-"
var _from_hangar := false
var _music_key := ""


func open(args: Dictionary) -> void:
	_from_hangar = args.get("from_hangar", false)
	set_page_title("lobby")
	set_back("Leave", _leave)
	if Net.is_host():
		set_primary(START_MATCH, _start)
	else:
		set_primary("Ready", _toggle_ready)
	_summary = Widgets.paragraph("", "DimLabel")
	content.add_child(_summary)
	_instructions = Widgets.paragraph("")
	content.add_child(_instructions)
	var name_row := NameRow.new()
	name_row.named.connect(func(n: String) -> void: Net.set_my_info("name", n))
	content.add_child(name_row)
	_herc_box = VBoxContainer.new()
	content.add_child(_herc_box)
	_pilot_box = VBoxContainer.new()
	content.add_child(_pilot_box)
	_teams = TeamList.new()
	_teams.team_chosen.connect(_on_team_chosen)
	_teams.assign_all_requested.connect(func() -> void:
		MatchFlow.apply_team_choices(TeamAssignment.make_assign_all(Net.roster, Net.settings)))
	_teams.shuffle_requested.connect(func() -> void:
		MatchFlow.apply_team_choices(TeamAssignment.make_shuffle(Net.roster, Net.settings, RandomNumberGenerator.new())))
	content.add_child(_teams)
	_roster = VBoxContainer.new()
	content.add_child(_roster)
	Net.roster_changed.connect(_on_roster_changed)
	MatchFlow.publish_campaign_offer()
	_on_roster_changed()


func _on_roster_changed() -> void:
	_summary.text = LobbySettings.make_summary(Net.settings)
	_instructions.text = LobbyText.make_instructions(Net.settings, Net.is_host())
	_play_lobby_music()
	var key := _make_choice_key()
	if key != _choice_key:
		_choice_key = key
		_rebuild_herc_choice()
	_rebuild_pilot_choice()
	_teams.visible = LobbySettings.is_team_match(Net.settings)
	if _teams.visible:
		_teams.refresh(Net.settings, Net.roster, Net.my_id(), Net.is_host())
	_refresh_roster()
	_refresh_primary()


## The soldier rows (not in a campaign or a raid: missions start in a Herc, a raid uses the stash's kit), for
## the match's infantry game.
func _rebuild_pilot_choice() -> void:
	var mode := str(Net.settings.get("mode", ""))
	var pack := "" if mode in ["campaign", ExtractionRules.MODE] else make_match_infantry_pack(Net.settings)
	if pack == _pilot_key:
		return
	_pilot_key = pack
	for c in _pilot_box.get_children():
		c.queue_free()
	if pack == "":
		return
	var picker := PilotPicker.new(pack)
	picker.changed.connect(_announce_pilot)
	picker.preview_requested.connect(_preview_body)
	_pilot_box.add_child(picker)
	_announce_pilot(picker.make_fields())


## The infantry game of a match with lobby settings `s` (the host's choice, else the map's, else the first).
static func make_match_infantry_pack(s: Dictionary) -> String:
	var cfg := LobbySettings.make_map_config(s).duplicate()
	cfg[LobbySettings.INFANTRY_PACK_KEY] = str(s.get(LobbySettings.INFANTRY_PACK_KEY, ""))
	return BattleInfantry.make_infantry_pack(cfg)


static func _announce_pilot(fields: Dictionary) -> void:
	for key in [PlayerProfile.ARMOR_KEY, PlayerProfile.BODY_KEY, PlayerProfile.SKIN_KEY]:
		Net.set_my_info(key, str(fields.get(key, "")))


## A soldier choice changed: the hangar shows that body (the Herc again on the next Herc change).
func _preview_body(shape_id: String, skin_id: String) -> void:
	if hangar == null or not _herc_box.is_inside_tree():
		return
	hangar.apply_skin(skin_id)
	hangar.show_herc(shape_id)


func _on_team_chosen(peer: int, team: int) -> void:
	if peer == Net.my_id():
		Net.set_my_info("team", team)
	else:
		Net.assign_team(peer, team)


## Host: Start is enabled once every pilot is ready, else the footer says who is missing. Client: Ready / Not ready.
func _refresh_primary() -> void:
	if not Net.is_host():
		primary_button.text = "Not ready" if _is_ready() else "Ready"
		return
	primary_button.text = START_MISSION if Net.settings.get("mode") == "campaign" else START_MATCH
	var reason := MatchFlow.make_start_block_reason()
	primary_button.disabled = reason != ""
	set_status(reason)


func _start() -> void:
	var reason := MatchFlow.try_start_hosted_match()
	if reason != "":
		set_status(reason)


func _is_ready() -> bool:
	return bool((Net.roster.get(Net.my_id(), {}) as Dictionary).get("ready", false))


## What the Herc choice depends on: the mode, and for a co-op campaign client the host's offer.
func _make_choice_key() -> String:
	var mode := str(Net.settings.get("mode", ""))
	if Net.is_host() or mode != "campaign":
		return mode
	return mode + JSON.stringify(Net.settings.get(MatchFlow.CAMPAIGN_OFFER, {}))


func _rebuild_herc_choice() -> void:
	for c in _herc_box.get_children():
		c.queue_free()
	herc_selector = null
	if ExtractionRules.is_extraction(Net.settings):
		_add_kit_choice()
	elif Net.settings.get("mode") != "campaign":
		_add_open_choice()
	elif Net.is_host():
		_add_host_garage_choice()
	else:
		_add_offer_choice(Net.settings.get(MatchFlow.CAMPAIGN_OFFER, {}))


## Extraction raid: the kit of your own profile (edited on the stash screen), announced to the host.
func _add_kit_choice() -> void:
	var profile := ExtractionProfile.load_for(Net.player_name)
	hide_hangar()
	_herc_box.add_child(Widgets.section("Your raid kit"))
	_herc_box.add_child(Widgets.paragraph(ExtractionScreenText.make_kit_summary(profile), "DimLabel"))
	_herc_box.add_child(Widgets.button("Stash, shop and loadout", func() -> void: router.go("extraction", {"return_to": "lobby"})))
	Net.set_my_info("kit", profile.make_kit_dict())


## Any Herc: what you already announced, else the armory's.
func _add_open_choice() -> void:
	var mine: Dictionary = Net.roster.get(Net.my_id(), {})
	herc_selector = HercSelector.new(show_hangar(), "Your Herc")
	_herc_box.add_child(herc_selector)
	herc_selector.vehicle_changed.connect(func(id: String) -> void: Net.set_my_info("vehicle", id))
	herc_selector.loadout_changed.connect(func(lo: Array) -> void: Net.set_my_info("loadout", lo))
	herc_selector.skin_changed.connect(func(skin_id: String) -> void: Net.set_my_info(PlayerProfile.HERC_SKIN_KEY, skin_id))
	herc_selector.setup(str(mine.get("vehicle", router.context.vehicle)), mine.get("loadout", []),
		CampaignAvailability.make_open_context(str(Net.settings.get("mode", ""))))
	Net.set_my_info("vehicle", herc_selector.vehicle_id())
	Net.set_my_info(PlayerProfile.HERC_SKIN_KEY, herc_selector.skin())


## Co-op campaign host: the campaign's garage, with the Hangar screen, like the briefing.
func _add_host_garage_choice() -> void:
	if not Session.has_campaign():
		_herc_box.add_child(Widgets.paragraph("No campaign is running.", "DimLabel"))
		return
	var picker := GaragePicker.new(show_hangar(), Session.garage(), Session.mission_herc(),
		func() -> void: launcher().open_hangar("lobby"))
	picker.changed.connect(_announce)
	_herc_box.add_child(picker)
	if _from_hangar:
		picker.select_garage()
	_announce(picker.entry())


## Co-op campaign client: the Hercs of the host's campaign (a copy of its garage, no Hangar button).
func _add_offer_choice(offer: Dictionary) -> void:
	if not offer.get("garage") is Dictionary or (offer.garage as Dictionary).is_empty():
		_herc_box.add_child(Widgets.paragraph(WAITING_FOR_OFFER, "DimLabel"))
		return
	_herc_box.add_child(Widgets.section(str(offer.get("heading", ""))))
	var picker := GaragePicker.new(show_hangar(), Garage.from_dict(offer.garage), offer.get("mission_herc", {}), Callable())
	picker.changed.connect(_announce)
	_herc_box.add_child(picker)
	_announce(picker.entry())


static func _announce(entry: Dictionary) -> void:
	Net.set_my_info("vehicle", str(entry.vehicle))
	Net.set_my_info("loadout", entry.loadout)


## The menu music of the game whose map the match is on (a co-op campaign: the host's campaign); chosen
## again only when the map changes.
func _play_lobby_music() -> void:
	var key := "%s/%s" % [Net.settings.get("mode", ""), Net.settings.get("world_idx", "")]
	if key == _music_key:
		return
	_music_key = key
	if Net.settings.get("mode") == "campaign":
		MenuMusic.play_for_campaign("lobby")
		return
	var entries := MapPicker.make_entries()
	var i := int(Net.settings.get("world_idx", -1))
	if i >= 0 and i < entries.size():
		MenuMusic.play_for_pack(MenuMusic.make_pack_of_map_config(entries[i].config))


func _leave() -> void:
	router.back()
	Net.leave()


func _toggle_ready() -> void:
	var ready := not _is_ready()
	Net.set_my_info("ready", ready)
	primary_button.text = "Not ready" if ready else "Ready"


func _refresh_roster() -> void:
	for c in _roster.get_children():
		c.queue_free()
	_roster.add_child(Widgets.section("Pilots (%d/%d)" % [Net.roster.size(), Net.MAX_PLAYERS]))
	for id in Net.roster:
		_roster.add_child(Widgets.label(LobbyText.make_pilot_text(int(id), Net.roster[id], Net.settings)))
