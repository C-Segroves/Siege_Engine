extends Node
## Windowed screenshots of the party screen (needs a window; look at the pictures):
##   start:   no party yet (create, join by code, a LAN party in the list)
##   leader:  the leader's view of a party of three (ready states, summaries, chat, the server picker, the chosen destination)
##   member:  a member's view of another party (read-only destination, Ready)
##   godot --audio-driver Dummy --path game res://tests/party_shots.tscn -- --shots=<dir> [--size=1280x800|900x700]
## An in-process master serves the parties and the other members are played by direct calls; the player's settings are not touched
## (the scene runs in a test store). Uses port 47722 (master).

const MASTER_PORT := 47722
const FAKE_SERVER := "192.0.2.30:47700"

var _shots := ""
var _master: MasterServer
var _launcher: Launcher


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
		elif a.begins_with("--size="):
			var wh := a.substr(7).split("x")
			DisplayServer.window_set_size(Vector2i(int(wh[0]), int(wh[1])))
	_run.call_deferred()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(name: String) -> void:
	await _frames(10)
	var path := _shots.path_join(name + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("shot %s" % path)


func _process(_delta: float) -> void:
	for k in Net.servers:   # the pretend LAN games and parties stay "seen"
		Net.servers[k]["seen"] = Time.get_ticks_msec()
	for k in Net.parties:
		Net.parties[k]["seen"] = Time.get_ticks_msec()


func _call(path: String, body: Dictionary) -> Dictionary:
	return _master.parties.answer(path, body, "198.51.100.40", MasterServer.now())


func _run() -> void:
	Net.player_name = "Raven"
	_master = MasterServer.new()
	_master.autostart = false
	_master.cfg = MasterServer.DEFAULTS.duplicate()
	_master.cfg.merge({"port": MASTER_PORT, "bind": "127.0.0.1"}, true)
	add_child(_master)
	_master.start()
	OnlineSettings.apply_master("127.0.0.1:%d" % MASTER_PORT)
	_make_pretend_lan()
	_launcher = load("res://launcher.tscn").instantiate()
	_launcher.set_meta("start_mode", Launcher.PARTY_START_MODE)
	get_tree().root.add_child(_launcher)
	await _frames(40)
	await _shot("party_start")
	await _leader_view()
	await _member_view()
	get_tree().quit()


func _make_pretend_lan() -> void:
	Net.servers = {FAKE_SERVER: {"proto": Net.PROTOCOL, "name": "Katabatic raid", "mode": "extraction", "map": "Tribes 2 map - Katabatic", "players": 3, "max": 16,
		"port": 47700, "in_game": false, "ip": "192.0.2.30", "seen": Time.get_ticks_msec()}}
	Net.parties = {"192.0.2.31:47703": {"proto": PartyLanHost.PROTOCOL, "code": "H4RT2", "name": "Moth's party", "members": 2, "max": 8, "port": 47703,
		"ip": "192.0.2.31", "seen": Time.get_ticks_msec()}}
	_master.registry.register("192.0.2.30", {"name": "Varuna's Fall raid", "game": "", "mode": "extraction", "map": "Tribes 2 map - Varuna's Fall", "players": 5, "max": 16,
		"version": Net.PROTOCOL, "transport": "enet", "port": 47720, "list_port": 47722}, MasterServer.now())


func _find_button(text: String) -> Button:
	for c in _launcher.find_children("*", "Button", true, false):
		if str(c.text).begins_with(text) and (c as Button).is_visible_in_tree() and not (c as Button).disabled:
			return c
	return null


func _leader_view() -> void:
	_find_button("Create online party").pressed.emit()
	var session := PartySession.ensure(get_tree())
	while not session.client.is_in_party():
		await _frames(2)
	var code := session.client.code
	var moth: Dictionary = _call("/party/join", {"code": code, "name": "Moth", "summary": "Medium armour  -  9 kinds of item  -  4 100 cr"}).body
	var kid: Dictionary = _call("/party/join", {"code": code, "name": "Sparrow", "summary": "Light armour  -  6 kinds of item  -  900 cr"}).body
	_call("/party/ready", {"code": code, "key": moth.key, "ready": true})
	_call("/party/say", {"code": code, "key": moth.key, "text": "my kit is set, ready when you are"})
	_call("/party/say", {"code": code, "key": kid.key, "text": "one second, buying ammo"})
	session.client.say("we take the Katabatic raid")
	session.client.set_destination({"address": FAKE_SERVER, "name": "Katabatic raid", "mode": "extraction", "map": "Tribes 2 map - Katabatic", "password": ""})
	await get_tree().create_timer(2.5).timeout
	await _shot("party_leader_waiting")
	_call("/party/ready", {"code": code, "key": kid.key, "ready": true})
	await get_tree().create_timer(2.5).timeout
	await _shot("party_leader_ready")
	session.leave()
	await _frames(20)


func _member_view() -> void:
	var made: Dictionary = _call("/party/create", {"name": "Moth", "summary": "Medium armour  -  9 kinds of item  -  4 100 cr"}).body
	_call("/party/destination", {"code": made.code, "key": made.key, "destination": {"address": FAKE_SERVER, "name": "Katabatic raid",
		"mode": "extraction", "map": "Tribes 2 map - Katabatic", "password": ""}})
	_call("/party/say", {"code": made.code, "key": made.key, "text": "pick Ready when your kit is done"})
	var edit: LineEdit = _launcher.find_children("*", "LineEdit", true, false).filter(func(e: LineEdit) -> bool: return e.placeholder_text.begins_with("party code"))[0]
	edit.text = str(made.code)
	_find_button("Join online party").pressed.emit()
	var session := PartySession.ensure(get_tree())
	while not session.client.is_in_party():
		await _frames(2)
	await get_tree().create_timer(2.0).timeout
	await _shot("party_member")
	_find_button("Ready").pressed.emit()
	await get_tree().create_timer(2.0).timeout
	await _shot("party_member_ready")
	session.leave()
