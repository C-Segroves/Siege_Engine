class_name PartyFlow
extends Node
## The trip of a party's Go on one member's machine: connect to the server the leader chose, tell it who we are (the operator's
## build, the raid kit and the party code, so the server keeps the party together) and say Ready; the game server then starts
## the match or drops us into its running raid. Nobody sees the lobby: the party screen shows `status` until the battle
## replaces the launcher. It ends on the first of: the game starting, a refusal (wrong password, server full, game in
## progress), no answer, or Cancel.
##   start(destination, party code, size)
## `destination`: {address, name, mode, map, password} (PartyRegistry.make_clean_destination).

signal status_changed(text: String)
signal failed(reason: String)

const CONNECT_TIMEOUT_SECONDS := 15.0
const ENTER_TIMEOUT_SECONDS := 20.0

enum Phase { IDLE, CONNECTING, WAITING }

var party: PartySession
var phase := Phase.IDLE
var status_text := ""
var _party_code := ""
var _size := 1
var _destination := {}
var _timer := 0.0


func is_busy() -> bool:
	return phase != Phase.IDLE


## The address text of the destination as Net.join takes it (ServerAddress.parse), "" when it is not a valid address.
static func make_join_address(destination_info: Dictionary) -> Dictionary:
	return ServerAddress.parse(str(destination_info.get("address", "")))


func start(destination_info: Dictionary, party_code: String, size: int) -> void:
	cancel(false)
	_destination = destination_info
	_party_code = party_code
	_size = size
	var address := make_join_address(destination_info)
	if not bool(address.ok) or address.kind == ServerAddress.KIND_HTTP:
		_fail("The party's destination is not a game address.")
		return
	Net.password = str(destination_info.get("password", ""))
	_connect_signals()
	var err := Net.join(str(address.text)) if address.kind == ServerAddress.KIND_WS else Net.join(str(address.host), int(address.port))
	if err != OK:
		_fail("Could not connect to %s (error %d)." % [address.text, err])
		return
	OnlineSettings.remember(str(address.text))
	phase = Phase.CONNECTING
	_timer = CONNECT_TIMEOUT_SECONDS
	_say("Connecting to %s ..." % str(destination_info.get("name", address.text)))


## Leaves the server and returns to the party (`say_it`: tell the screen).
func cancel(say_it := true) -> void:
	if phase == Phase.IDLE:
		return
	_disconnect_signals()
	phase = Phase.IDLE
	if Net.is_online():
		Net.leave_quiet()
	if say_it:
		_say("Cancelled.")


func _process(delta: float) -> void:
	if phase == Phase.IDLE:
		return
	_timer -= delta
	if _timer <= 0.0:
		_fail("No answer from the server." if phase == Phase.CONNECTING else "The server did not start your game.")


# ------------------------------------------------------------------ signals

func _connect_signals() -> void:
	if not Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.connect(_on_roster_changed)
		Net.connection_failed.connect(_on_connection_failed)
		Net.session_ended.connect(_on_session_ended)
		Net.game_starting.connect(_on_game_starting)


func _disconnect_signals() -> void:
	if Net.roster_changed.is_connected(_on_roster_changed):
		Net.roster_changed.disconnect(_on_roster_changed)
		Net.connection_failed.disconnect(_on_connection_failed)
		Net.session_ended.disconnect(_on_session_ended)
		Net.game_starting.disconnect(_on_game_starting)


func _on_roster_changed() -> void:
	if phase != Phase.CONNECTING or not Net.roster.has(Net.my_id()):
		return
	phase = Phase.WAITING
	_timer = ENTER_TIMEOUT_SECONDS if str(Net.settings.get("mode", "")) == ExtractionRules.MODE else INF
	_announce()
	_say("Joined %s. Waiting for the game to start ..." % str(_destination.get("name", "the server")))


## Tells the server who we are: the operator's build (and kit in a raid), the party and Ready.
func _announce() -> void:
	var profile := OperatorProfile.load_for(Net.player_name)
	var fields := LobbyAnnouncer.make_fields(Net.settings, profile)
	fields["party"] = {"id": _party_code, "size": _size}
	fields["ready"] = true
	Net.set_my_infos(fields)


func _on_connection_failed() -> void:
	_fail("Could not connect to the server.")


func _on_session_ended(reason: String) -> void:
	_fail(reason)


func _on_game_starting(_config: Dictionary) -> void:
	_disconnect_signals()
	phase = Phase.IDLE


func _fail(reason: String) -> void:
	_disconnect_signals()
	phase = Phase.IDLE
	if Net.is_online():
		Net.leave_quiet()
	if party != null:
		party.on_trip = false
		party.client.return_to_party()
	_say(reason)
	failed.emit(reason)


func _say(text: String) -> void:
	status_text = text
	status_changed.emit(text)
