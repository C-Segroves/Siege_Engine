class_name BattleExit
extends Node
## Leaving a battle before it ends, the same in every game and mode (child node "Exit" of Battle):
## the in-battle menu (BattleMenu, opened with menu_pause: Esc / pad Start) and what its choices do.
##
## - Single player: the menu pauses the game (SceneTree.paused; the menu's layer keeps processing).
##   LAN: nothing pauses; the player's vehicle stops taking input while the menu is open.
## - The mouse is released while the menu is open and captured again on Resume.
## - Abort mission (campaign or single mission): the mission counts as failed, with the campaign's
##   own consequences of a defeat, exactly as if the mission had been lost:
##     Earthsiege 1: the next slot plays its failure variant (Campaign: "index 1 after a failure");
##     Earthsiege 2: the campaign goes on to the next mission, and aborting a must-win mission loses
##       the war (CampaignES2, docs/formats/es2_campaign_flow.md);
##     Starsiege: the mission is replayed (the original has no failure branches).
##   The mission variables keep their values at the moment of the abort; nothing is salvaged. The
##   original shell's career and the launcher's debriefing receive an ordinary failed result.
## - Leave match, single player skirmish: the match ends without a winner (results screen).
## - Leave match, LAN client: disconnects; the host removes that pilot's vehicle and tells the rest.
## - Leave match, LAN host: disconnects, which ends the match for every client; their front end
##   shows "The host left the match."
## - Quit to main menu (asked first): a LAN session is closed, then the app's library opens; a running
##   campaign is kept where it was (the current mission is not counted).

const ABORT_TEXT := "Mission aborted."
const ABANDON_TEXT := "You left the match."
const HOST_LEFT_TEXT := "The host left the match."
const CLIENT_LEFT_TEXT := "%s left the match."
const LEFT_MESSAGE_SECONDS := 4.0
## Net's session_ended reason when the host's connection closes (engine/net.gd server_disconnected).
const HOST_CLOSED_REASON := "Host closed the session"
## Debrief code of an aborted mission (the mission runtimes use 0.. for their own endings).
const ABORT_CODE := MissionOutcome.ABORT_CODE

var battle: Battle
var menu: BattleMenu
var _leaving := false


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "Exit"


func _ready() -> void:
	Net.session_ended.connect(_on_session_ended)
	Net.player_left.connect(_on_player_left)


func _exit_tree() -> void:
	if get_tree().paused:
		get_tree().paused = false


func _unhandled_input(event: InputEvent) -> void:
	if UiActions.is_pressed(event, "menu_pause"):
		get_viewport().set_input_as_handled()
		toggle_menu()


func is_menu_open() -> bool:
	return is_instance_valid(menu)


func toggle_menu() -> void:
	if is_menu_open():
		resume()
	else:
		open_menu()


func open_menu() -> void:
	menu = BattleMenu.open_over(battle, make_menu_actions())
	if Net.is_online():
		_hold_player(true)
	else:
		get_tree().paused = true


func resume() -> void:
	_close_menu()
	_hold_player(false)
	if battle.player != null and battle.player.alive:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## The menu's texts and choices for this battle (single player / LAN host / LAN client, mission or match).
func make_menu_actions() -> Dictionary:
	var actions := {"on_resume": resume, "on_leave": leave, "on_quit": quit_to_main_menu,
		"page": "%s  -  menu" % _make_mode_name(), "note": _make_note()}
	actions.merge(_make_leave_texts())
	return actions


func leave() -> void:
	if Net.is_online():
		leave_lan_match()
	elif battle.mission != null:
		abort_mission()
	else:
		battle.abort_match(ABANDON_TEXT, {})


## The mission ends as failed (see the class comment for each game's consequences).
func abort_mission() -> void:
	var vars: PackedInt32Array = battle.mission.mission_vars if battle.mission != null else PackedInt32Array()
	battle.abort_match(ABORT_TEXT, MissionOutcome.make_aborted(vars, ABORT_TEXT))


func leave_lan_match() -> void:
	_leaving = true
	Net.leave()
	battle.leave_to_front_end(ABANDON_TEXT)


func quit_to_main_menu() -> void:
	if Net.is_online():
		_leaving = true
		Net.leave()
	battle.leave_to_main_menu()


func _close_menu() -> void:
	if is_menu_open():
		menu.close()
	menu = null
	if get_tree().paused:
		get_tree().paused = false


## LAN: the player's vehicle ignores the controls while the menu is open (throttle stays set).
func _hold_player(on: bool) -> void:
	PlayerHold.apply(battle, on)


func _make_mode_name() -> String:
	if battle.mission != null:
		return "mission"
	return str(BattleRules.MODE_NAMES.get(str(battle.config.get("mode", "")), "match")).to_lower()


func _make_note() -> String:
	if Net.is_online():
		return "LAN match: the battle goes on while this menu is open."
	return "The game is paused."


func _make_leave_texts() -> Dictionary:
	if Net.is_online() and Net.is_host():
		return {"leave_text": "Leave match", "leave_question": "Leave the LAN match? You are the host: the match ends for every pilot."}
	if Net.is_online():
		return {"leave_text": "Leave match", "leave_question": "Leave the LAN match? The other pilots play on without you."}
	if battle.mission != null:
		return {"leave_text": "Abort mission", "leave_question": "Abort the mission? It counts as a failed mission, with the campaign's usual consequences."}
	return {"leave_text": "Leave match", "leave_question": "Leave the match? It ends without a winner."}


## A client: the host closed the session (or kicked us) while the battle runs.
func _on_session_ended(reason: String) -> void:
	if _leaving or battle.is_queued_for_deletion():
		return
	_leaving = true
	battle.leave_to_front_end(HOST_LEFT_TEXT if reason == HOST_CLOSED_REASON else reason)


## Host: a client disconnected - its vehicle leaves the battle on every peer.
func _on_player_left(peer_id: int) -> void:
	if not multiplayer.is_server() or battle.is_over():
		return
	for id in battle.vehicles.keys():
		var h: Herc = battle.vehicles[id]
		if is_instance_valid(h) and h.owner_peer == peer_id and not h.has_meta("ai"):
			battle.fx("message", [CLIENT_LEFT_TEXT % h.display_name, LEFT_MESSAGE_SECONDS], true)
			battle.remove_vehicle(int(id))
