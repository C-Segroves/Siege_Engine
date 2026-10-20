class_name LobbyChatHub
extends Node
## The lobby's chat line between pilots (docs/design/lobby_loadout_economy.md section 5), independent of any screen: it
## rides on the multiplayer peer's raw packets (SceneMultiplayer.send_bytes), so it needs no node path on the other
## peers and a dedicated server can relay it. Host-authoritative like BattleChat: a client sends its line to the host,
## the host cleans and caps it (ChatLog.make_clean), applies the flood guard (ChatRateLimiter), names the sender from the
## roster and sends it to everybody (all) or to the sender's team (team). One hub per process (ensure).
##   LobbyChatHub.ensure(tree).say(ChatChannels.ALL, "gg")      line_received(channel, sender, text)

signal line_received(channel: String, sender: String, text: String)

const NODE_NAME := "LobbyChatHub"
const PACKET_TAG := 0x4C
const TRANSFER_CHANNEL := 7
const HISTORY_LIMIT := 60
const RATE_LIMIT_TEXT := "You are sending messages too fast."

var history: Array = []     # [{channel, sender, text}] newest last
var limiter := ChatRateLimiter.new()


## The process's hub, created under the scene tree's root on first use.
static func ensure(tree: SceneTree) -> LobbyChatHub:
	var found := tree.root.get_node_or_null(NODE_NAME) as LobbyChatHub
	if found != null:
		return found
	var hub := LobbyChatHub.new()
	hub.name = NODE_NAME
	tree.root.add_child.call_deferred(hub)
	return hub


func _ready() -> void:
	var api := multiplayer as SceneMultiplayer
	if api != null:
		api.peer_packet.connect(_on_packet)


## The local pilot says `text` on `channel` (ChatChannels.ALL or TEAM).
func say(channel: String, text: String) -> void:
	var clean := ChatLog.make_clean(text)
	if clean == "" or not ChatChannels.SPOKEN.has(channel):
		return
	if Net.is_host() or not Net.is_online():
		_relay(Net.my_id(), channel, clean)
	else:
		_send(MatchFlow.HOST_ID, {"c": channel, "t": clean})


func _relay(sender: int, channel: String, text: String) -> void:
	var sender_name := str(Net.roster.get(sender, {}).get("name", Net.player_name))
	if sender != Net.my_id() and not limiter.try_take(sender, Time.get_ticks_msec() / 1000.0):
		_send(sender, {"c": ChatChannels.SYSTEM, "s": "", "t": RATE_LIMIT_TEXT})
		return
	var line := {"c": channel, "s": sender_name, "t": text}
	for peer in Net.roster:
		if int(peer) == Net.my_id() or (channel == ChatChannels.TEAM and not _is_teammate(sender, int(peer))):
			continue
		_send(int(peer), line)
	if channel == ChatChannels.ALL or _is_teammate(sender, Net.my_id()) or not Net.roster.has(Net.my_id()):
		_add_line(channel, sender_name, text)


func _is_teammate(a: int, b: int) -> bool:
	return Net.roster.has(a) and Net.roster.has(b) and int(Net.roster[a].get("team", -1)) == int(Net.roster[b].get("team", -2))


func _send(peer: int, line: Dictionary) -> void:
	var api := multiplayer as SceneMultiplayer
	if api == null or not Net.is_online():
		return
	var bytes := PackedByteArray([PACKET_TAG])
	bytes.append_array(JSON.stringify(line).to_utf8_buffer())
	api.send_bytes(bytes, peer, MultiplayerPeer.TRANSFER_MODE_RELIABLE, TRANSFER_CHANNEL)


func _on_packet(from: int, packet: PackedByteArray) -> void:
	if packet.size() < 2 or packet[0] != PACKET_TAG:
		return
	var line = JSON.parse_string(packet.slice(1).get_string_from_utf8())
	if not line is Dictionary:
		return
	if Net.is_host():
		_receive_at_host(from, line)
	elif from == MatchFlow.HOST_ID:
		_add_line(str(line.get("c", ChatChannels.SYSTEM)), str(line.get("s", "")), ChatLog.make_clean(str(line.get("t", ""))))


func _receive_at_host(from: int, line: Dictionary) -> void:
	var channel := str(line.get("c", ""))
	var text := ChatLog.make_clean(str(line.get("t", "")))
	if text != "" and Net.roster.has(from) and ChatChannels.SPOKEN.has(channel):
		_relay(from, channel, text)


func _add_line(channel: String, sender: String, text: String) -> void:
	if text == "":
		return
	history.append({"channel": channel, "sender": sender, "text": text})
	if history.size() > HISTORY_LIMIT:
		history.pop_front()
	line_received.emit(channel, sender, text)
