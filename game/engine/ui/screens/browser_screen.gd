extends LauncherScreen
## Join a game: LAN games (auto-discovered, ENet), the matches of a game server (its match list), or a typed address.
## Addresses: an IP/name (ENet, LAN), "ws://..." / "wss://..." (a WebSocket server), or "https://host" (the server's
## match list is shown and a match joins over wss). The browser build lists the matches of the server that served
## the page; it can only join over WebSocket.

const SERVER_HINT := "IP, ws://host:port or https://server"

var _servers: VBoxContainer
var _matches: VBoxContainer
var _address: LineEdit
var _password: LineEdit
var _list := MatchListClient.new()
var _list_origin := ""


func open(_args: Dictionary) -> void:
	set_page_title("join a game" if WebPlatform.is_active() else "join a LAN game")
	set_back("Back", _leave)
	set_primary("Join address", _join_typed_address)
	if not WebPlatform.is_active():
		content.add_child(Widgets.section("LAN games (auto-discovered)"))
		_servers = VBoxContainer.new()
		content.add_child(_servers)
	content.add_child(Widgets.section("Server matches"))
	_matches = VBoxContainer.new()
	content.add_child(_matches)
	_address = Widgets.line_edit("", SERVER_HINT)
	content.add_child(OptionRow.new("Address", _address))
	_password = Widgets.line_edit("", "if the server asks")
	content.add_child(OptionRow.new("Password", _password))
	add_child(_list)
	_list.received.connect(_show_matches)
	_list.failed.connect(func(reason: String) -> void: _show_note(reason))
	if not WebPlatform.is_active():
		Net.servers_changed.connect(_refresh_servers)
		Net.start_discovery()
		_refresh_servers()
	else:
		_load_matches(MatchListClient.make_page_origin())


func _leave() -> void:
	Net.stop_discovery()
	router.back()


func _load_matches(origin: String) -> void:
	_list_origin = origin
	_show_note("loading ...")
	_list.fetch(origin)


func _show_note(text: String) -> void:
	for c in _matches.get_children():
		c.queue_free()
	_matches.add_child(Widgets.label(text, "DimLabel"))


func _show_matches(matches: Array) -> void:
	for c in _matches.get_children():
		c.queue_free()
	if matches.is_empty():
		_show_note("no matches on this server")
	for m: Dictionary in matches:
		var url := Net.make_ws_url(_list_origin)
		var b := Widgets.button(_make_server_text(m), func() -> void: _join(url))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_matches.add_child(b)


func _refresh_servers() -> void:
	for c in _servers.get_children():
		c.queue_free()
	if Net.servers.is_empty():
		_servers.add_child(Widgets.label("searching ...", "DimLabel"))
	for k in Net.servers:
		var s: Dictionary = Net.servers[k]
		var b := Widgets.button(_make_server_text(s), func() -> void: _join(str(s.ip)))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_servers.add_child(b)


static func _make_server_text(s: Dictionary) -> String:
	return "%s   [%s]  %s   %d/%d%s%s" % [s.name, s.mode, s.get("map", ""), int(s.players), int(s.max),
		"   (in progress)" if s.get("in_game", false) else "", "   (password)" if s.get("password", false) else ""]


func _join_typed_address() -> void:
	var text := _address.text.strip_edges()
	if text.begins_with("http://") or text.begins_with("https://"):
		_load_matches(text)   # a server's page address: list its matches first
	elif text != "":
		_join(text)


func _join(address: String) -> void:
	Net.stop_discovery()
	Net.password = _password.text
	var err := Net.join(address)
	set_status("Connecting to %s ..." % address if err == OK else "Connect failed (%d)" % err)
