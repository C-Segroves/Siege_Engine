extends LauncherScreen
## Join a LAN game: auto-discovered servers (one button each) or a typed address.

var _servers: VBoxContainer
var _address: LineEdit


func open(_args: Dictionary) -> void:
	set_page_title("join a LAN game")
	set_back("Back", _leave)
	set_primary("Join address", _join_typed_address)
	content.add_child(Widgets.section("LAN games (auto-discovered)"))
	_servers = VBoxContainer.new()
	content.add_child(_servers)
	_address = Widgets.line_edit("", "IP address")
	content.add_child(OptionRow.new("Address", _address))
	Net.servers_changed.connect(_refresh_servers)
	Net.start_discovery()
	_refresh_servers()


func _leave() -> void:
	Net.stop_discovery()
	router.back()


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
	return "%s   [%s]  %s   %d/%d%s" % [s.name, s.mode, s.get("map", ""), int(s.players), int(s.max),
		"   (in progress)" if s.get("in_game", false) else ""]


func _join_typed_address() -> void:
	if _address.text.strip_edges() != "":
		_join(_address.text.strip_edges())


func _join(ip: String) -> void:
	Net.stop_discovery()
	var err := Net.join(ip)
	set_status("Connecting to %s ..." % ip if err == OK else "Connect failed (%d)" % err)
