extends Node
## Headless check of campaign saves and the launcher's campaign entries (QA #5, #6, #13, #17):
## - every game's campaign (Earthsiege, Earthsiege 2, Starsiege human / cybrid) saves and loads as
##   itself (provider recorded in the save); saves from before that are recognised by their fields;
## - opening the launcher menu does not load the autosave; Continue campaign loads the newest save explicitly and
##   an Earthsiege 2 save continues with its own briefing;
## - a co-op client sets its own campaign aside and picks only from the host's offer;
## - the Hangar's Build picker defaults to the campaign's own Herc;
## - the launcher's Back says where it goes; its Quit asks first.
##   godot --headless --audio-driver Dummy --path game res://tests/campaign_save_check.tscn
## The player's saves are backed up and restored (saved_campaign_guard).

const LAUNCHER_SCENE := "res://launcher.tscn"
const TEST_SLOT := "qa_campaign_check"
const AUTOSAVE := "autosave"
const STEP_FRAMES := 4

var _fails := 0
var _autosave_guard = preload("res://tests/saved_campaign_guard.gd").new(AUTOSAVE)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	_autosave_guard.back_up()
	_clear_store()
	_check_round_trips()
	_check_legacy_saves()
	await _check_explicit_continue()
	await _check_coop_client()
	await _check_build_defaults()
	await _check_launcher_footer()
	_clear_store()
	_autosave_guard.restore()
	print("campaign_save_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


## Only this test's saves in the store (the guard brings the player's back).
func _clear_store() -> void:
	for f in DirAccess.get_files_at(SaveGames.DIR):
		DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [SaveGames.DIR, f]))


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _frames(n := STEP_FRAMES) -> void:
	for i in n:
		await get_tree().process_frame


func _playable_entries() -> Array:
	return MatchFlow.make_campaign_entries().filter(func(e: Dictionary) -> bool: return e.playable)


# ------------------------------------------------------------------ checks

func _check_round_trips() -> void:
	var entries := _playable_entries()
	_expect(entries.size() >= 2, "campaign entries offered: %s" % [entries.map(func(e): return e.text)])
	for e in entries:
		Session.start_stage_campaign(str(e.pack), str(e.variant))
		var mission := str(Session.campaign.current_mission())
		var variant := str(Session.campaign.get("variant")) if Session.campaign.get("variant") != null else ""
		Session.save_campaign(TEST_SLOT)
		Session.clear_campaign()
		var loaded := Session.load_campaign(TEST_SLOT)
		_expect(loaded and Session.campaign.pack_id() == e.pack and str(Session.campaign.current_mission()) == mission
			and (variant == "" or str(Session.campaign.get("variant")) == variant),
			"%s saves and loads as itself (mission %s)" % [e.text, mission])
		_expect(not Session.briefing().is_empty(), "%s: the loaded campaign has its briefing" % e.text)


func _check_legacy_saves() -> void:
	for pack in ["es1", "es2", "starsiege"]:
		Session.start_stage_campaign(pack)
		var d := Session.make_save_dict()
		d.erase("pack")
		Session.apply_save_dict(d)
		_expect(Session.campaign.pack_id() == pack, "a save without its game recorded still loads as %s" % pack)


func _check_explicit_continue() -> void:
	Session.start_stage_campaign("es2")
	var mission := str(Session.campaign.current_mission())
	Session.autosave()
	Session.clear_campaign()
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	add_child(launcher)
	await _frames()
	_expect(Session.campaign == null, "opening the launcher menu does not load the autosave")
	var cont := _find_button(launcher, "Continue campaign")
	_expect(cont != null, "Continue campaign offered for the autosave")
	if cont:
		cont.pressed.emit()
		await _frames()
		_expect(Session.campaign is CampaignES2 and launcher.current_name == "briefing",
			"Continue campaign loads the Earthsiege 2 save into its briefing (%s)" % launcher.current_name)
		_expect(str(Session.campaign.current_mission()) == mission and not str(Session.briefing().get("briefing", "")).is_empty(),
			"the briefing is Earthsiege 2 mission %s with its text" % mission)
	Net.stop_discovery()
	launcher.queue_free()
	await _frames()


func _check_coop_client() -> void:
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	add_child(launcher)
	await _frames()
	Session.start_saga()
	launcher.call("_on_joined")
	await _frames()
	_expect(Session.campaign == null and Session.saga == null, "a joining co-op client sets its own campaign aside")
	Net.leave()
	launcher.queue_free()
	await _frames()
	Session.start_stage_campaign("es1")
	var offer := MatchFlow.make_campaign_offer()
	var host_hercs: Array = (offer.garage.vehicles as Array).map(func(v: Dictionary) -> String: return str(v.vehicle))
	Session.clear_campaign()
	var picker := GaragePicker.new(null, Garage.from_dict(offer.garage), offer.mission_herc, Callable())
	var ids := []
	for i in picker.choice_count():
		picker.select_choice(i)
		ids.append(str(picker.entry().vehicle))
	if not (offer.mission_herc as Dictionary).is_empty():
		host_hercs.append(str(offer.mission_herc.vehicle))
	_expect(ids == host_hercs, "the client's choices are exactly the host's campaign Hercs %s" % [ids])
	_expect(picker.find_children("*", "Button", true, false).filter(func(b): return b.text == GaragePicker.HANGAR_BUTTON).is_empty(),
		"the client gets no Hangar button for the host's garage")
	picker.free()


func _check_build_defaults() -> void:
	for e in _playable_entries():
		Session.start_stage_campaign(str(e.pack), str(e.variant))
		var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
		add_child(launcher)
		await _frames()
		launcher.open_hangar("briefing")
		await _frames()
		var picker: VehiclePicker = null
		for c in launcher.current.find_children("*", "VehiclePicker", true, false):
			picker = c
		var chosen := picker.selected_id() if picker else ""
		_expect(str(Packs.vehicle(chosen).get("pack", "")) == e.pack, "%s: Build defaults to its own Herc (%s)" % [e.text, chosen])
		launcher.queue_free()
		await _frames()


func _check_launcher_footer() -> void:
	Session.launcher_home = "res://library.tscn"
	var launcher: Launcher = load(LAUNCHER_SCENE).instantiate()
	add_child(launcher)
	await _frames()
	_expect(launcher.current.back_button.text == "Back to library", "launcher Back says it goes to the library ('%s')" % launcher.current.back_button.text)
	var quit := _find_button(launcher, "Quit")
	if quit:
		quit.pressed.emit()
		await _frames()
	_expect(launcher.find_children("*", "ConfirmDialog", true, false).size() == 1, "launcher Quit asks first")
	Net.stop_discovery()
	launcher.queue_free()
	await _frames()


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if (c as Button).text == text and (c as Button).is_visible_in_tree():
			return c
	return null
