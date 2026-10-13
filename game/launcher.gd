class_name Launcher
extends ScreenRouter
## Launcher (res://launcher.tscn): skirmish / armory, campaigns (briefing, debriefing, saga choice),
## LAN co-op / versus (host, browse, lobby), options. The ES1 shell opens it with
## `multiplayer_only = true` for its MULTIPLAYER entry; the library opens it with meta "start_mode"
## ("arena" / "coop" / "host": the host page, "join": the LAN browser). Each page is one script in engine/ui/screens/.

const SCREENS_DIR := "res://engine/ui/screens/"
const SCREEN_FILES := {
	"menu": "launcher_menu.gd", "armory": "armory_screen.gd", "host": "host_screen.gd",
	"browser": "browser_screen.gd", "lobby": "lobby_screen.gd", "briefing": "briefing_screen.gd",
	"debrief": "debrief_screen.gd", "end": "end_screen.gd", "saga_choice": "saga_choice_screen.gd",
	"options": "options_screen.gd", "hangar": "hangar_screen.gd", "training": "training_screen.gd",
	"new_campaign": "new_campaign_screen.gd", "saves": "saves_screen.gd", "killed": "killed_screen.gd",
	"extraction": "extraction_screen.gd", "versions": "versions_screen.gd",
}
## Library entries that open a campaign page directly (meta "start_mode").
const CAMPAIGN_START_MODES := ["continue", "new_campaign", "load"]
## Library entry that opens the LAN browser (meta "start_mode").
const JOIN_START_MODE := "join"
## Library entry that opens the launcher's own menu (skirmish, training, extraction).
const MENU_START_MODE := "menu"
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const SELF_SCENE := "res://launcher.tscn"
const MULTIPLAYER_TITLE := "MULTIPLAYER"
const ES1_SHELL_SCENE := "res://es1_shell.tscn"
const HOME_NAMES := {"res://es1_shell.tscn": "original shell", "res://library.tscn": "library"}

## Only the pilot / Herc pickers and the LAN pages; "Back" returns to the original shell.
var multiplayer_only := false


func _ready() -> void:
	super()
	_remember_home()
	context["vehicle"] = _first_vehicle()
	context["loadout"] = []
	Net.game_starting.connect(start_battle)
	Net.session_ended.connect(_on_session_ended)
	Net.connection_failed.connect(func() -> void: back_with_status("Could not connect."))
	Net.connected_to_server.connect(_on_joined)
	_open_first_screen()
	_show_front_end_status()
	LauncherAutomation.run(self)


func make_screen_paths() -> Dictionary:
	var out := {}
	for screen_name in SCREEN_FILES:
		out[screen_name] = SCREENS_DIR + SCREEN_FILES[screen_name]
	return out


func make_app_title() -> String:
	return MULTIPLAYER_TITLE if multiplayer_only else APP_TITLE


func go_with_status(screen_name: String, text: String) -> void:
	go(screen_name).set_status(text)


## Back (the navigation stack) and shows `text` on the screen it lands on.
func back_with_status(text: String) -> void:
	back()
	_show_status(text)


## The main menu: the front end that opened the launcher (the library), or the launcher's own menu under the
## original shell's MULTIPLAYER entry. `text` is shown there.
func go_main_menu(text := "") -> void:
	if Session.launcher_home == ES1_SHELL_SCENE:
		go_root("menu").set_status(text)
		return
	Session.front_end_status = text
	leave_to_front_end()


## Back with no screen remembered: the main menu (go_main_menu), or the front end from the launcher's own menu.
func back_from_root() -> void:
	if current_name != "menu" and Session.launcher_home == ES1_SHELL_SCENE:
		go_root("menu")
	else:
		leave_to_front_end()


## The LAN session ended: a pilot still in the lobby goes back to where he came from (the host or browser page).
func _on_session_ended(reason: String) -> void:
	if current_name == "lobby":
		back_with_status(reason)
	else:
		_show_status(reason)


func _show_status(text: String) -> void:
	if is_inside_tree() and current != null and get_tree().current_scene == self:
		current.set_status(text)


## The campaign's next page: the death prompt after a killed pilot's battle, the saga side choice, the
## briefing, or the menu when no campaign runs.
func show_campaign() -> void:
	if Session.must_replay():
		go("killed")
	elif not Session.has_campaign():
		go("menu")
	elif Session.saga != null and Session.saga.needs_choice():
		go("saga_choice")
	else:
		go("briefing")


## The running campaign's Hangar screen (every change autosaved); leaving it goes back to the screen that opened
## it (`return_to` names it on the button) with {"from_hangar": true}.
func open_hangar(return_to: String) -> void:
	go("hangar", {"garage": Session.garage(), "availability": Session.availability_context,
		"wingman_slots": 0 if Session.coop else Session.wingman_slots(),
		"heading": MatchFlow.make_mission_heading(), "done_text": "Back to %s" % return_to,
		"on_done": func() -> void: back({"from_hangar": true}),
		"on_changed": func() -> void: Session.autosave()})


## Starts a battle (single player when `cfg` has no roster: the armory's Herc).
func start_battle(cfg: Dictionary) -> void:
	if not cfg.has("roster"):
		cfg["roster"] = MatchFlow.make_solo_roster(context.vehicle, context.loadout)
	Session.front_end = SELF_SCENE
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	battle.config = cfg
	replace_with(battle)


## Continues the newest save that can be continued (SaveGames); false when there is none.
func continue_newest() -> bool:
	var e := SaveGames.find_newest_continuable()
	if e.is_empty() or not Session.load_save(str(e.id)):
		return false
	show_campaign()
	return true


## Back to the front end this launcher was opened from (original shell or library).
func leave_to_front_end() -> void:
	Net.stop_discovery()
	Session.front_end = Session.launcher_home
	get_tree().change_scene_to_file(Session.launcher_home)


## "Back to library" / "Back to original shell": the label of the button that calls leave_to_front_end.
func make_home_label() -> String:
	return "Back to %s" % HOME_NAMES.get(Session.launcher_home, "main menu")


func _remember_home() -> void:
	if multiplayer_only:
		Session.launcher_home = ES1_SHELL_SCENE
	elif Session.front_end != SELF_SCENE:
		Session.launcher_home = Session.front_end


## A co-op client plays the host's campaign: its own (single player) campaign is set aside.
func _on_joined() -> void:
	Session.clear_campaign()
	Session.last_result = {}
	go("lobby")


## The message a battle left for the front end ("The host left the match.").
func _show_front_end_status() -> void:
	if Session.front_end_status != "" and current != null:
		current.set_status(Session.front_end_status)
	Session.front_end_status = ""


func _open_first_screen() -> void:
	var page := Session.launcher_page
	Session.launcher_page = ""
	_open_page_after_battle(page)


func _open_page_after_battle(page: String) -> void:
	if not Session.last_result.is_empty() and Session.has_campaign():
		go("killed" if Session.must_replay() else "debrief")
	elif Net.is_online():
		go("lobby")
	elif page != "" and make_screen_paths().has(page):
		go(page)
	elif has_meta("start_mode") and str(get_meta("start_mode")) in CAMPAIGN_START_MODES:
		_open_campaign_page(str(get_meta("start_mode")))
	elif has_meta("start_mode") and get_meta("start_mode") == JOIN_START_MODE:
		go("browser")
	elif has_meta("start_mode") and get_meta("start_mode") == MENU_START_MODE:
		go("menu")
	elif has_meta("start_mode"):
		go("host", {"mode": "coop" if get_meta("start_mode") == "coop" else "vs"})
	else:
		go("menu")


## The library's Continue / New campaign / Load game.
func _open_campaign_page(mode: String) -> void:
	match mode:
		"continue":
			if not continue_newest():
				go_main_menu("There is no campaign to continue.")
		"new_campaign":
			go("new_campaign")
		_:
			go("saves", {"mode": "load"})


func _first_vehicle() -> String:
	if not Packs.vehicle(MatchFlow.DEFAULT_VEHICLE).is_empty():
		return MatchFlow.DEFAULT_VEHICLE
	var all := Packs.pilotable()
	return str(all[0].id) if not all.is_empty() else MatchFlow.DEFAULT_VEHICLE
