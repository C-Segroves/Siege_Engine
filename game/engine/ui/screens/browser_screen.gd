extends LauncherScreen
## Join a game. LAN games (auto-discovered by broadcast), Online games (listed by the master server of Options > Online),
## and Join by address: an IP, "IP:port" or a host name (ENet), "ws://..." / "wss://..." (a WebSocket server) or
## "https://host" (the server's match list is shown and a match joins over wss). Typing an address and pressing Enter (or Check)
## asks the server for its name, mode, map, players and the ping before joining; joined addresses are remembered.
## The browser build lists the matches of the server that served the page; it can only join over WebSocket.
## The Host LAN game / Host online game buttons are shown under the original shell's MULTIPLAYER entry.

const SERVER_HINT := "IP, IP:port, host name, ws://host:port or https://server"
const PING_REFRESH_MSEC := 10000
const NO_PING := "-- ms"

var _servers: VBoxContainer
var _online: VBoxContainer
var _matches: VBoxContainer
var _recent: HFlowContainer
var _address: LineEdit
var _password: LineEdit
var _info: Label
var _list := MatchListClient.new()
var _master := MasterClient.new()
var _probe := ServerProbe.new()
var _list_origin := ""
var _pings := {}   # list origin -> {ms, at}


func open(_args: Dictionary) -> void:
	set_page_title("join a game" if WebPlatform.is_active() else "join a LAN or online game")
	set_back("Back", _leave)
	set_primary("Join address", _join_typed_address)
	if launcher().multiplayer_only:
		content.add_child(Widgets.row([
			Widgets.button("Host LAN game", func() -> void: launcher().open_lobby(GameOptionsModel.KIND_VERSUS)),
			_make_host_online_button()]))
	add_child(_list)
	add_child(_master)
	add_child(_probe)
	_list.received.connect(_show_matches)
	_list.failed.connect(func(reason: String) -> void: _show_note(reason))
	_master.received.connect(_show_online)
	_master.failed.connect(func(reason: String) -> void: _show_online_note(reason))
	if not WebPlatform.is_active():
		content.add_child(Widgets.section("LAN games (auto-discovered)"))
		_servers = VBoxContainer.new()
		content.add_child(_servers)
		_add_online_section()
	content.add_child(Widgets.section("Server matches"))
	_matches = VBoxContainer.new()
	content.add_child(_matches)
	_add_address_section()
	if not WebPlatform.is_active():
		Net.servers_changed.connect(_refresh_servers)
		Net.start_discovery()
		_refresh_servers()
		if OnlineSettings.has_master():
			_refresh_online()
	else:
		_load_matches(MatchListClient.make_page_origin())


func _make_host_online_button() -> Button:
	var b := Widgets.button("Host online game", func() -> void: launcher().open_lobby(GameOptionsModel.KIND_VERSUS, false, true))
	b.disabled = not OnlineSettings.has_master()
	b.tooltip_text = "Lists your game on the master server." if OnlineSettings.has_master() else LibraryHome.NO_MASTER_TEXT
	return b


func _leave() -> void:
	Net.stop_discovery()
	router.back()


# ------------------------------------------------------------------ online games (master server)

func _add_online_section() -> void:
	content.add_child(Widgets.section("Online games (master server)"))
	var head := Widgets.label("Master: %s" % MasterClient.make_base_url(OnlineSettings.master()) if OnlineSettings.has_master()
		else "No master server set (Options & tools > Options > Online). LAN games need none.", "DimLabel")
	head.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var refresh := Widgets.small_button("Refresh", _refresh_online)
	refresh.disabled = not OnlineSettings.has_master()
	content.add_child(Widgets.row([head, refresh]))
	_online = VBoxContainer.new()
	content.add_child(_online)


func _refresh_online() -> void:
	_show_online_note("loading ...")
	_master.fetch(OnlineSettings.master())


func _show_online_note(text: String) -> void:
	_clear(_online)
	_online.add_child(Widgets.label(text, "DimLabel"))


func _show_online(servers: Array) -> void:
	_clear(_online)
	if servers.is_empty():
		_show_online_note("no online games listed")
		return
	for s: Dictionary in servers:
		_add_server_row(_online, s, str(s.address), str(s.get("list_origin", "")))


# ------------------------------------------------------------------ LAN games

func _refresh_servers() -> void:
	_clear(_servers)
	if Net.servers.is_empty():
		_servers.add_child(Widgets.label("searching ...", "DimLabel"))
	for k in Net.servers:
		var s: Dictionary = Net.servers[k]
		var port := int(s.get("port", Net.GAME_PORT))
		var origin := "http://%s:%d" % [s.ip, ServerAddress.DEFAULT_LIST_PORT]
		_add_server_row(_servers, s, "%s:%d" % [s.ip, port], origin, false)


## One joinable server: a button with its details and ping. `origin` is where its match list answers ("" = unknown).
## `show_missing_ping`: write "-- ms" while no answer is known (online rows, which should have a list port).
func _add_server_row(box: VBoxContainer, s: Dictionary, address: String, origin: String, show_missing_ping := true) -> void:
	var base := _make_server_text(s)
	var cached: Dictionary = _pings.get(origin, {})
	var text := base + "   " + (NO_PING if show_missing_ping else "")
	if cached.has("ms") and int(cached.ms) >= 0:
		text = "%s   %d ms" % [base, int(cached.ms)]
	var b := Widgets.button(text, func() -> void: _join(address))
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	box.add_child(b)
	var now := Time.get_ticks_msec()
	if origin == "" or (cached.has("at") and now - int(cached.at) < PING_REFRESH_MSEC):
		return
	_pings[origin] = {"ms": int(cached.get("ms", -1)), "at": now}   # the LAN list is rebuilt every second: ask once in a while
	_probe.probe(origin, func(ok: bool, _info_found: Dictionary, ping_ms: int) -> void:
		_pings[origin] = {"ms": ping_ms if ok else -1, "at": Time.get_ticks_msec()}
		if is_instance_valid(b) and ok:
			b.text = "%s   %d ms" % [base, ping_ms])


static func _make_server_text(s: Dictionary) -> String:
	return "%s   [%s]  %s   %d/%d%s%s" % [s.name, s.get("game", "") if str(s.get("game", "")) != "" else s.get("mode", ""), s.get("map", ""), int(s.players), int(s.max),
		"   (in progress)" if s.get("in_game", false) else "", "   (password)" if s.get("password", false) else ""]


# ------------------------------------------------------------------ server matches (a server's page)

func _load_matches(origin: String) -> void:
	_list_origin = origin
	_show_note("loading ...")
	_list.fetch(origin)


func _show_note(text: String) -> void:
	_clear(_matches)
	_matches.add_child(Widgets.label(text, "DimLabel"))


func _show_matches(matches: Array) -> void:
	_clear(_matches)
	if matches.is_empty():
		_show_note("no matches on this server")
	for m: Dictionary in matches:
		var url := Net.make_ws_url(_list_origin)
		var b := Widgets.button(_make_server_text(m), func() -> void: _join(url))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_matches.add_child(b)


# ------------------------------------------------------------------ join by address

func _add_address_section() -> void:
	content.add_child(Widgets.section("Join by address"))
	_address = Widgets.line_edit("", SERVER_HINT)
	_address.text_submitted.connect(func(_t: String) -> void: _check_address())
	var check := Widgets.small_button("Check", _check_address)
	var row := OptionRow.new("Address", _address)
	row.add_child(check)
	content.add_child(row)
	_info = Widgets.paragraph("Press Enter or Check to see the server's name, players and ping before joining.", "DimLabel")
	content.add_child(_info)
	_password = Widgets.line_edit("", "if the server asks")
	_password.secret = true
	content.add_child(OptionRow.new("Password", _password))
	_recent = HFlowContainer.new()
	content.add_child(_recent)
	_show_recent()


func _show_recent() -> void:
	_clear(_recent)
	var recent := OnlineSettings.recent()
	if recent.is_empty():
		return
	_recent.add_child(Widgets.label("Recent:", "DimLabel"))
	for a: String in recent:
		_recent.add_child(Widgets.small_button(a, func() -> void:
			_address.text = a
			_check_address()))


## Asks the typed server for its info and the ping (its match list, port 47702 unless the address is an http:// one).
func _check_address() -> void:
	var address := ServerAddress.parse(_address.text)
	if not address.ok:
		_info.text = str(address.error)
		return
	var origin := ServerAddress.make_list_origin(address)
	if origin == "":
		_info.text = "%s: a WebSocket server; no info to check, press Join address." % address.text
		return
	_info.text = "Asking %s ..." % address.host
	_probe.probe(origin, func(ok: bool, info: Dictionary, ping_ms: int) -> void:
		if not is_instance_valid(_info):
			return
		_info.text = "%s   %d ms" % [_make_server_text(info), ping_ms] if ok \
			else "No server info from %s (no match list there). You can still try Join address." % address.host)


func _join_typed_address() -> void:
	var address := ServerAddress.parse(_address.text)
	if not address.ok:
		if _address.text.strip_edges() != "":
			set_status(str(address.error))
		return
	if address.kind == ServerAddress.KIND_HTTP:
		_load_matches(str(address.text))   # a server's page address: list its matches first
		return
	_join(str(address.text))


func _join(address_text: String) -> void:
	var address := ServerAddress.parse(address_text)
	if not address.ok:
		set_status(str(address.error))
		return
	Net.stop_discovery()
	Net.password = _password.text if _password != null else ""
	var err := Net.join(str(address.text)) if address.kind == ServerAddress.KIND_WS else Net.join(str(address.host), int(address.port))
	if err == OK:
		OnlineSettings.remember(str(address.text))
	set_status("Connecting to %s ..." % address.text if err == OK else "Connect failed (%d)" % err)


static func _clear(box: Control) -> void:
	for c in box.get_children():
		c.queue_free()
