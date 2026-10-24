class_name PartySession
extends Node
## The party of this process: a node of the scene root, so it outlives the screens and keeps its membership through a raid.
## It owns the PartyClient (HTTP polling of the party service), the LAN party host when this PC is the leader of a LAN party,
## and the trip of a Go (PartyFlow). The party screen (PartyScreen) is only a view of it.
##   PartySession.ensure(tree).create_online() / create_lan() / join_online(code) / join_lan(host, port, code)
## `on_trip` is true from the leader's Go until the party screen is shown again after the raid.

signal trip_finished

const NODE_NAME := "PartySession"
## The session ensure() made, kept so a second call in the same frame (before the deferred add_child) finds it.
static var _made: PartySession
const NO_MASTER_TEXT := "Set the master server address first (Options & tools > Options > Online), or use a LAN party."
const NO_LAN_HOST_TEXT := "Could not host a LAN party: port %d is busy (a party is already hosted on this PC?)."

var client := PartyClient.new()
var flow := PartyFlow.new()
var lan_host: PartyLanHost
## True while the members are away on a trip (Go ... back on the party screen).
var on_trip := false


## The process's session, created under the scene tree's root on first use.
static func ensure(tree: SceneTree) -> PartySession:
	var found := tree.root.get_node_or_null(NODE_NAME) as PartySession
	if found != null:
		return found
	if is_instance_valid(_made) and not _made.is_queued_for_deletion():
		return _made
	var session := PartySession.new()
	session.name = NODE_NAME
	tree.root.add_child.call_deferred(session)
	_made = session
	return session


## True when a party session exists and the local pilot is in a party.
static func is_active(tree: SceneTree) -> bool:
	var found := tree.root.get_node_or_null(NODE_NAME) as PartySession
	return found != null and found.client.is_in_party()


## True when the party's members are away on a trip (Go) and this machine has not shown the party screen since.
static func is_on_trip(tree: SceneTree) -> bool:
	var found := tree.root.get_node_or_null(NODE_NAME) as PartySession
	return found != null and found.on_trip and found.client.is_in_party()


## True while the local pilot's client is connecting to the party's server (Launcher must not open the lobby).
static func is_joining(tree: SceneTree) -> bool:
	var found := tree.root.get_node_or_null(NODE_NAME) as PartySession
	return found != null and found.flow.is_busy()


func _ready() -> void:
	client.name = "Client"
	add_child(client)
	flow.name = "Flow"
	flow.party = self
	add_child(flow)
	client.go_received.connect(_on_go)
	client.ended.connect(_on_ended)


## The line other members see under the pilot's name: "Light armour  -  6 kinds of item  -  1 200 cr".
static func make_my_summary() -> String:
	var profile := ExtractionProfile.load_for(Net.player_name)
	return "%s  -  %d kinds of item  -  %s" % [ExtractionScreenText.make_armor_name(profile.kit_armor), profile.kit.stacks.size(),
		ExtractionRules.make_money_text(profile.money)]


# ------------------------------------------------------------------ creating and joining

## A party on the master server of Options > Online. Returns "" or why it cannot.
func create_online() -> String:
	if not OnlineSettings.has_master():
		return NO_MASTER_TEXT
	client.lan = false
	client.create(MasterClient.make_base_url(OnlineSettings.master()), Net.player_name, make_my_summary())
	return ""


func join_online(code: String) -> String:
	if not OnlineSettings.has_master():
		return NO_MASTER_TEXT
	client.lan = false
	client.join(MasterClient.make_base_url(OnlineSettings.master()), code, Net.player_name, make_my_summary())
	return ""


## A party hosted by this PC for the LAN (the other PCs find it by broadcast). Returns "" or why it cannot.
func create_lan(port := PartyLanHost.DEFAULT_PORT) -> String:
	stop_lan_host()
	lan_host = PartyLanHost.new()
	lan_host.name = "LanHost"
	add_child(lan_host)
	if lan_host.start(port) != OK:
		lan_host.queue_free()
		lan_host = null
		return NO_LAN_HOST_TEXT % port
	client.lan = true
	client.create(PartyClient.make_base_url("127.0.0.1", port), Net.player_name, make_my_summary())
	return ""


func join_lan(host: String, port: int, code: String) -> void:
	client.lan = true
	client.join(PartyClient.make_base_url(host, port), code, Net.player_name, make_my_summary())


func stop_lan_host() -> void:
	if lan_host != null:
		lan_host.stop()
		lan_host.queue_free()
	lan_host = null


## Leaves the party (the leader of a LAN party closes it).
func leave() -> void:
	client.leave()
	stop_lan_host()


func _on_ended(_reason: String) -> void:
	on_trip = false
	stop_lan_host()


# ------------------------------------------------------------------ the trip

func _on_go(destination_info: Dictionary, size: int) -> void:
	on_trip = true
	flow.start(destination_info, client.code, size)


## The party screen is shown again after a trip: the member is back in the party.
func apply_return() -> void:
	if not on_trip:
		return
	on_trip = false
	client.return_to_party()
	trip_finished.emit()
