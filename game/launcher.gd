class_name Launcher
extends ScreenRouter
## Launcher (res://launcher.tscn): campaigns (debriefing, saga choice), the LAN browser, options. Every game
## about to start is set up in the standard lobby (LobbyScreen: skirmish, campaign, co-op, versus, extraction, solo
## through an offline session, hosted or joined over LAN; docs/design/lobby_loadout_economy.md section 5.6). The ES1
## shell opens it with `multiplayer_only = true` for its MULTIPLAYER entry; the library opens it with meta "start_mode"
## (LOBBY_START_KINDS: a lobby at once, "join": the LAN browser). Each page is one script in engine/ui/screens/.

const SCREENS_DIR := "res://engine/ui/screens/"
const SCREEN_FILES := {
	"browser": "browser_screen.gd", "lobby": "lobby_screen.gd",
	"debrief": "debrief_screen.gd", "end": "end_screen.gd", "saga_choice": "saga_choice_screen.gd",
	"options": "options_screen.gd", "hangar": "hangar_screen.gd", "training": "training_screen.gd",
	"new_campaign": "new_campaign_screen.gd", "saves": "saves_screen.gd", "killed": "killed_screen.gd",
	"versions": "versions_screen.gd",
}
## Library entries that open a campaign page directly (meta "start_mode").
const CAMPAIGN_START_MODES := ["continue", "new_campaign", "load"]
## Library entries that open a lobby at once (meta "start_mode"): the lobby kind (GameOptionsModel.KIND_*) and whether it
## is an offline session.
const LOBBY_START_KINDS := {
	"host": {"kind": GameOptionsModel.KIND_VERSUS, "solo": false},
}
## Library entry that opens the LAN browser (meta "start_mode").
const JOIN_START_MODE := "join"
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const SELF_SCENE := "res://launcher.tscn"
const MULTIPLAYER_TITLE := "MULTIPLAYER"
const ES1_SHELL_SCENE := "res://es1_shell.tscn"

## Only the LAN pages and the lobby (it opens on the LAN browser); "Back" returns to the original shell.
var multiplayer_only := false
var _leaving_to_front_end := false


func _ready() -> void:
	super()
	UiScale.apply(get_tree().root)
	_remember_home()
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


## The main menu: the front end that opened the launcher (the library home), or the LAN browser under the original
## shell's MULTIPLAYER entry. `text` is shown there.
func go_main_menu(text := "") -> void:
	if multiplayer_only:
		go_root("browser").set_status(text)
		return
	Session.front_end_status = text
	leave_to_front_end()


## Back with no screen remembered: the front end that opened the launcher.
func back_from_root() -> void:
	leave_to_front_end()


## The LAN session ended: a pilot still in the lobby goes back to where he came from (the host or browser page).
func _on_session_ended(reason: String) -> void:
	if _leaving_to_front_end:
		return
	if current_name == "lobby":
		back_with_status(reason)
	else:
		_show_status(reason)


func _show_status(text: String) -> void:
	if is_inside_tree() and current != null and get_tree().current_scene == self:
		current.set_status(text)


## The campaign's next page: the death prompt after a killed pilot's battle, the saga side choice, the
## campaign lobby (the briefing, the Herc, Start mission), or the main menu when no campaign runs.
func show_campaign() -> void:
	if Session.must_replay():
		go("killed")
	elif not Session.has_campaign():
		go_main_menu()
	elif Session.saga != null and Session.saga.needs_choice():
		go("saga_choice")
	elif Net.is_online() or _has_solo_campaign_session():
		go("lobby")
	else:
		go("lobby", {"kind": GameOptionsModel.KIND_CAMPAIGN, "solo": true})


## A campaign that was just started or loaded: its lobby, never an earlier offline session's.
func show_started_campaign() -> void:
	end_offline_session()
	show_campaign()


## Opens a new lobby of `kind` (GameOptionsModel.KIND_*) with the default settings: hosted over LAN, or with `solo` an
## offline session. An offline session that is still open from an earlier game is closed first.
func open_lobby(kind: String, solo := false) -> RoutedScreen:
	end_offline_session()
	return go("lobby", {"kind": kind, "solo": solo})


## Closes an offline session left open after a game (the lobby it returned to was not used again).
func end_offline_session() -> void:
	if not Net.is_online() and not Net.roster.is_empty():
		Net.leave()


func _has_solo_campaign_session() -> bool:
	return not Net.roster.is_empty() and MatchFlow.is_solo_campaign(Net.settings)


## The running campaign's Hangar screen (every change autosaved); leaving it goes back to the screen that opened
## it (`return_to` names it on the button) with {"from_hangar": true}.
func open_hangar(return_to: String) -> void:
	go("hangar", {"garage": Session.garage(), "availability": Session.availability_context,
		"wingman_slots": 0 if Session.coop else Session.wingman_slots(),
		"heading": MatchFlow.make_mission_heading() + ("  -  Classic" if Session.classic else ""), "done_text": "Back to %s" % return_to,
		"on_done": func() -> void: back({"from_hangar": true}),
		"on_changed": func() -> void: Session.autosave()})


## Starts a battle with `cfg` (the lobby's game, a rematch, a replayed mission).
func start_battle(cfg: Dictionary) -> void:
	Session.front_end = SELF_SCENE
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	battle.config = cfg
	replace_with(battle)


## Continues the newest save that can be continued (SaveGames); false when there is none.
func continue_newest() -> bool:
	var e := SaveGames.find_newest_continuable()
	if e.is_empty() or not Session.load_save(str(e.id)):
		return false
	show_started_campaign()
	return true


## Back to the front end this launcher was opened from (original shell or the library home, on its Play tab).
func leave_to_front_end() -> void:
	_leaving_to_front_end = true
	Session.show_play_tab()
	Net.stop_discovery()
	Session.front_end = Session.launcher_home
	get_tree().change_scene_to_file(Session.launcher_home)


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
	if has_meta("start_mode"):
		end_offline_session()
	_open_page_after_battle()


func _open_page_after_battle() -> void:
	var start_mode := str(get_meta("start_mode")) if has_meta("start_mode") else ""
	if not Session.last_result.is_empty() and Session.has_campaign():
		go("killed" if Session.must_replay() else "debrief")
	elif start_mode == "" and not Net.roster.is_empty():
		go("lobby")   # the session a game was played in (LAN or offline) goes on in its lobby
	elif start_mode in CAMPAIGN_START_MODES:
		_open_campaign_page(start_mode)
	elif start_mode == JOIN_START_MODE:
		go("browser")
	elif LOBBY_START_KINDS.has(start_mode):
		open_lobby(LOBBY_START_KINDS[start_mode].kind, LOBBY_START_KINDS[start_mode].solo)
	elif multiplayer_only:
		go("browser")
	elif not LauncherAutomation.is_pending():
		_leave_when_current.call_deferred()


## A match was left and no session is open: the front end's home (the library home), once this launcher is the app's
## scene (a launcher a test adds under another scene stays).
func _leave_when_current() -> void:
	if is_inside_tree() and get_tree().current_scene == self:
		leave_to_front_end()


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
