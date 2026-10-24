class_name ServerPicker
extends VBoxContainer
## Picks one game server: the LAN games found by broadcast, the online games of the master server (Options > Online), or an address
## typed in. The party leader uses it to choose where the party goes (PartyScreen); the lists are the ones of the Join browser.
## `picked({address, name, mode, map, password})` fires when a row is pressed or the typed address is used.

signal picked(server: Dictionary)

const SERVER_HINT := "IP, IP:port, host name or ws://host:port"

var _lan: VBoxContainer
var _lan_key := ""
var _online: VBoxContainer
var _address: LineEdit
var _password: LineEdit
var _note: Label
var _master := MasterClient.new()
var _probe := ServerProbe.new()


func _init() -> void:
	add_child(_master)
	add_child(_probe)
	_master.received.connect(_show_online)
	_master.failed.connect(_show_online_note)
	add_child(Widgets.section("LAN games"))
	_lan = VBoxContainer.new()
	add_child(_lan)
	add_child(Widgets.section("Online games"))
	_online = VBoxContainer.new()
	add_child(_online)
	add_child(Widgets.section("By address"))
	_address = Widgets.line_edit("", SERVER_HINT)
	_address.text_submitted.connect(func(_t: String) -> void: _use_typed_address())
	add_child(OptionRow.new("Address", _address))
	_password = Widgets.line_edit("", "if the server asks")
	_password.secret = true
	add_child(OptionRow.new("Password", _password))
	add_child(Widgets.row([Widgets.small_button("Use this address", _use_typed_address)]))
	_note = Widgets.paragraph("", "DimLabel")
	add_child(_note)


func _ready() -> void:
	Net.servers_changed.connect(_show_lan)
	Net.start_discovery()
	_show_lan()
	refresh_online()


func _exit_tree() -> void:
	if Net.servers_changed.is_connected(_show_lan):
		Net.servers_changed.disconnect(_show_lan)


## Asks the master server for its list again.
func refresh_online() -> void:
	if not OnlineSettings.has_master():
		_show_online_note("No master server set (Options & tools > Options > Online).")
		return
	_show_online_note("loading ...")
	_master.fetch(OnlineSettings.master())


## "Name   [mode]  map   3/24   (password)" - the row text of a server (also the Join browser's).
static func make_server_text(s: Dictionary) -> String:
	return "%s   [%s]  %s   %d/%d%s%s" % [s.name, s.get("game", "") if str(s.get("game", "")) != "" else s.get("mode", ""), s.get("map", ""), int(s.players), int(s.max),
		"   (in progress)" if s.get("in_game", false) else "", "   (password)" if s.get("password", false) else ""]


## {address, name, mode, map, password} of the server entry `s` (a Net.servers or master entry) joined at `address`.
static func make_destination(s: Dictionary, address: String, password := "") -> Dictionary:
	return {"address": address, "name": str(s.get("name", address)), "mode": str(s.get("mode", "")), "map": str(s.get("map", "")),
		"password": password}


func _show_lan() -> void:
	var key := JSON.stringify(Net.servers.keys().map(func(k: String) -> String: return "%s|%s" % [k, make_server_text(Net.servers[k])]))
	if key == _lan_key:
		return   # the broadcast arrives every second: rebuilding the rows would take the focus away
	_lan_key = key
	_clear(_lan)
	if Net.servers.is_empty():
		_lan.add_child(Widgets.label("searching ...", "DimLabel"))
	for k in Net.servers:
		var s: Dictionary = Net.servers[k]
		_add_row(_lan, s, "%s:%d" % [s.ip, int(s.get("port", Net.GAME_PORT))])


func _show_online(servers: Array) -> void:
	_clear(_online)
	if servers.is_empty():
		_show_online_note("no online games listed")
		return
	for s: Dictionary in servers:
		_add_row(_online, s, str(s.address))


func _show_online_note(text: String) -> void:
	_clear(_online)
	_online.add_child(Widgets.label(text, "DimLabel"))


func _add_row(box: VBoxContainer, s: Dictionary, address: String) -> void:
	var b := Widgets.button(make_server_text(s), func() -> void: picked.emit(make_destination(s, address, _password.text)))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(b)


func _use_typed_address() -> void:
	var parsed := ServerAddress.parse(_address.text)
	if not bool(parsed.ok) or parsed.kind == ServerAddress.KIND_HTTP:
		_note.text = str(parsed.get("error", "Type the address of a game server, not a web page."))
		return
	_note.text = "Asking %s ..." % parsed.host
	var origin := ServerAddress.make_list_origin(parsed)
	var chosen := {"name": str(parsed.text)}
	_probe.probe(origin, func(ok: bool, info: Dictionary, ping_ms: int) -> void:
		if ok:
			chosen = info
			_note.text = "%s   %d ms" % [make_server_text(info), ping_ms]
		else:
			_note.text = "No server info from %s; using the address as it is." % parsed.host
		picked.emit(make_destination(chosen, str(parsed.text), _password.text)))


static func _clear(box: Control) -> void:
	for c in box.get_children():
		c.queue_free()
