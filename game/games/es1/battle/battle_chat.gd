class_name BattleChat
extends Node
## The battle's chat (child "Chat" of Battle, the same in every game and mode; docs/formats/cockpit.md 9.6):
## the ChatPanel on the battle overlay, the campaign radio (RadioVoice) and the players' chat over LAN.
##
## - Opening: chat_all (Enter) / chat_team (Y) type a line, chat_quick (K / pad Share) the quick-chat menu,
##   chat_history (U) the full history and edit mode. While open, ChatFocus.open is set, the player's controls
##   are held (PlayerHold: nothing pauses) and the mouse is free; closing captures it again if it was.
## - LAN, host-authoritative: a client asks the host to say a line; the host cleans and caps it
##   (ChatLog.make_clean), applies the flood guard (ChatRateLimiter), names the sender from the roster and sends
##   it to everybody (all) or to the sender's team only (team: the team of the peer's vehicle, else his roster
##   team); single player, the line goes straight to the local log.
## - Radio: Battle.radio() lines (BattleFx "radio") are spoken by RadioVoice, and each shows in the chat (and
##   the cockpit's message line) when its voice clip starts.

const RATE_LIMIT_TEXT := "You are sending messages too fast."
const HOST_PEER := 1
## Above the battle overlay (cockpit, HUD), below the station menus (StationMenu.LAYER) and the battle menu.
const CHAT_LAYER := 40

var battle: Battle
var panel: ChatPanel
var radio: RadioVoice
var limiter := ChatRateLimiter.new()
var _mouse_mode_before := Input.MOUSE_MODE_CAPTURED


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "Chat"


func _ready() -> void:
	panel = ChatPanel.new(battle.overlay.chat_log)
	panel.occupied_provider = make_occupied_rects
	panel.say_requested.connect(say)
	panel.opened.connect(_on_opened)
	panel.closed.connect(_on_closed)
	var layer := CanvasLayer.new()
	layer.name = "ChatLayer"
	layer.layer = CHAT_LAYER
	layer.add_child(panel)
	add_child(layer)
	radio = RadioVoice.new()
	radio.line_started.connect(battle.overlay.show_radio)
	add_child(radio)


func _exit_tree() -> void:
	ChatFocus.open = false


func _unhandled_input(event: InputEvent) -> void:
	if panel.is_open() or battle.is_menu_open():
		return
	if UiActions.is_pressed(event, "chat_all"):
		panel.open_typing(ChatChannels.ALL)
	elif UiActions.is_pressed(event, "chat_team"):
		panel.open_typing(ChatChannels.TEAM)
	elif UiActions.is_pressed(event, "chat_quick"):
		panel.open_quick()
	elif UiActions.is_pressed(event, "chat_history"):
		panel.open_history()
	else:
		return
	get_viewport().set_input_as_handled()


func _on_opened() -> void:
	ChatFocus.open = true
	_mouse_mode_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	PlayerHold.apply(battle, true)


func _on_closed() -> void:
	ChatFocus.open = false
	PlayerHold.apply(battle, false)
	if not battle.is_menu_open():
		Input.mouse_mode = _mouse_mode_before


# ------------------------------------------------------------------ where the panel may go

## The screen rects of the HUD in use (ChatPlacement): the cockpit's windows while it shows, else the plain
## HUD's meters and the soldier's bars.
func make_occupied_rects() -> Array:
	var screen: Vector2 = panel.get_viewport_rect().size
	var cockpit := battle.overlay.cockpit
	if is_instance_valid(cockpit) and cockpit.visible:
		return ChatPlacement.make_screen_rects(CockpitOccupancy.make_rects(cockpit), cockpit.canvas_size, screen)
	return HUD.make_occupied_rects(screen) + InfantryHud.make_occupied_rects(screen)


# ------------------------------------------------------------------ saying a line (LAN)

## The local player says `text` on `channel` (ChatChannels.ALL / TEAM).
func say(channel: String, text: String) -> void:
	if not ChatChannels.SPOKEN.has(channel):
		push_error("BattleChat.say: not a spoken channel '%s'" % channel)
		return
	if Net.is_online() and not multiplayer.is_server():
		_request_say.rpc_id(HOST_PEER, channel, text)
	else:
		route(multiplayer.get_unique_id() if Net.is_online() else HOST_PEER, channel, text)


@rpc("any_peer", "reliable")
func _request_say(channel: String, text: String) -> void:
	if multiplayer.is_server() and ChatChannels.SPOKEN.has(channel):
		route(multiplayer.get_remote_sender_id(), channel, text)


## Host: sends `sender`'s line to its recipients (cleaned, capped and rate-limited).
func route(sender: int, channel: String, text: String) -> void:
	var clean := ChatLog.make_clean(text)
	if clean == "":
		return
	if not limiter.try_take(sender, Time.get_ticks_msec() / 1000.0):
		_send_to(sender, {"channel": ChatChannels.SYSTEM, "sender": "", "text": RATE_LIMIT_TEXT, "team": -1})
		return
	var team := team_of(sender)
	var msg := {"channel": channel, "sender": battle.make_pilot_name(sender), "text": clean, "team": team}
	for peer in make_recipients(channel, team, make_peers()):
		_send_to(peer, msg)


## Every peer in the battle: the host and, online, each client.
func make_peers() -> Array:
	var peers := [HOST_PEER]
	if Net.is_online():
		peers.append_array(multiplayer.get_peers())
	return peers


## Those of `peers` that receive a line on `channel` from a sender of `team` (team: that team only).
func make_recipients(channel: String, team: int, peers: Array) -> Array:
	if channel != ChatChannels.TEAM:
		return peers
	return peers.filter(func(p: int) -> bool: return team_of(p) == team)


## The team `peer` plays on: his vehicle's (soldier's), else his roster entry's.
func team_of(peer: int) -> int:
	for h in battle.vehicles.values():
		if is_instance_valid(h) and h.owner_peer == peer and not h.has_meta("ai"):
			return int(h.team)
	return int(battle.config.get("roster", {}).get(peer, {}).get("team", 0))


func _send_to(peer: int, msg: Dictionary) -> void:
	if peer == HOST_PEER or not Net.is_online():
		_deliver(msg)
	else:
		_deliver.rpc_id(peer, msg)


@rpc("authority", "reliable")
func _deliver(msg: Dictionary) -> void:
	var channel := str(msg.get("channel", ""))
	if not ChatChannels.is_known(channel):
		push_error("BattleChat: unknown channel '%s'" % channel)
		return
	battle.overlay.chat_log.add(channel, str(msg.get("sender", "")), ChatLog.make_clean(str(msg.get("text", ""))),
		int(msg.get("team", -1)))
