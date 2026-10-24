extends Node
## Windowed screenshots of the online screens (needs a window; look at the pictures):
##   browser: the Join screen with a LAN game, the Online games of a master server (one with a ping) and Join by address
##   sheet:   the library's Options & tools tab with Run dedicated server..., and the sheet running a server with its log
##   godot --audio-driver Dummy --path game res://tests/online_shots.tscn -- --part=browser|sheet --shots=<dir>
## The player's settings are not touched (saved_campaign_guard). Uses ports 47712 (master), 47773 (game), 47702 (list).

const SavedGuard := preload("res://tests/saved_campaign_guard.gd")
const MASTER_PORT := 47712
const LIST_PORT := 47702
const GAME_PORT := 47773

var _part := "browser"
var _shots := ""
var _guard := SavedGuard.new()
var _fake_lan := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--part="):
			_part = a.substr(7)
		elif a.begins_with("--shots="):
			_shots = a.substr(8)
	_guard.back_up()
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(8)
	var path := _shots.path_join(name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("shot %s" % path)


func _process(_delta: float) -> void:
	for k in _fake_lan:   # keeps the pretend LAN game "seen" (the browser forgets games it hears nothing from)
		_fake_lan[k]["seen"] = Time.get_ticks_msec()


func _run() -> void:
	if _part == "browser":
		await _browser_shots()
	else:
		await _sheet_shots()
	_guard.restore()
	get_tree().quit()


func _browser_shots() -> void:
	var master := MasterServer.new()
	master.autostart = false
	master.cfg = MasterServer.DEFAULTS.duplicate()
	master.cfg.port = MASTER_PORT
	master.cfg.bind = "127.0.0.1"
	add_child(master)
	master.start()
	var list := MatchListServer.new()   # answers /matches for the first online game: it gets a ping
	add_child(list)
	list.start(LIST_PORT, "127.0.0.1")
	Net.server_name = "Varuna night run"
	Net.max_players = 16
	var now := MasterServer.now()
	master.registry.register("127.0.0.1", {"name": "Varuna night run", "game": "team_deathmatch", "mode": "vs", "map": "Tribes 2 map - Katabatic", "players": 0, "max": 16,
		"version": Net.PROTOCOL, "transport": "enet", "port": GAME_PORT, "list_port": LIST_PORT}, now)
	master.registry.register("127.0.0.1", {"name": "Capture the flag (password)", "game": "ctf", "mode": "vs", "map": "Tribes 2 map - Raindance", "players": 6, "max": 32,
		"password": true, "version": Net.PROTOCOL, "transport": "enet", "port": GAME_PORT + 1, "list_port": 0}, now)
	master.registry.register("127.0.0.1", {"name": "Co-op raid", "game": "coop_ai", "mode": "coop", "map": "Earthsiege map - Delta", "players": 2, "max": 8,
		"in_game": true, "version": Net.PROTOCOL, "transport": "enet", "port": GAME_PORT + 2, "list_port": 0}, now)
	OnlineSettings.apply_master("127.0.0.1:%d" % MASTER_PORT)
	OnlineSettings.remember("192.168.1.20")
	OnlineSettings.remember("192.168.1.31:47800")
	_fake_lan["192.0.2.30:47700"] = {"proto": Net.PROTOCOL, "name": "Ironside's game", "mode": "vs", "map": "Tribes 2 map - Katabatic", "players": 3, "max": 24,
		"port": 47700, "in_game": false, "ip": "192.0.2.30", "seen": Time.get_ticks_msec()}
	Net.servers = _fake_lan
	var launcher: Launcher = load("res://launcher.tscn").instantiate()
	launcher.set_meta("start_mode", "join")
	get_tree().root.add_child(launcher)
	await _frames(30)
	var address: LineEdit = launcher.find_children("*", "LineEdit", true, false).filter(func(e: LineEdit) -> bool: return e.placeholder_text.begins_with("IP, IP:port"))[0]
	address.text = "127.0.0.1:%d" % GAME_PORT
	address.text_submitted.emit(address.text)
	await get_tree().create_timer(1.5).timeout
	await _shot("online_browser")


func _sheet_shots() -> void:
	OnlineSettings.apply_master("192.168.1.5:47710")
	var library: Node = load("res://library.tscn").instantiate()
	get_tree().root.add_child(library)
	await _frames(30)
	await _shot("online_tools_tab")
	var button := _find_button(library, "Run dedicated server...")
	if button == null:
		print("no Run dedicated server button")
		return
	button.pressed.emit()
	await _frames(10)
	await _shot("online_server_sheet")
	var sheet := library.find_children("*", "ServerSheet", true, false)[0] as ServerSheet
	sheet._port.text = str(GAME_PORT)
	sheet._master.text = ""
	sheet._toggle()
	var t0 := Time.get_ticks_msec()
	while LocalServer.make_state() != "running" and Time.get_ticks_msec() - t0 < 90000:
		await get_tree().create_timer(0.5).timeout
	await _shot("online_server_running")
	LocalServer.stop()


func _find_button(root: Node, text: String) -> Button:
	for c in root.find_children("*", "Button", true, false):
		if str(c.text) == text and (c as Button).is_visible_in_tree():
			return c
	return null
