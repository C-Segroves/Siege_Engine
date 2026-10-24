class_name ServerSheet
extends VBoxContainer
## "Run dedicated server...": a sheet that starts a headless dedicated server (LocalServer) on this PC from the installed app,
## shows its state and the tail of its log, and stops it. The fields start from ServerConfig's defaults, then the values used
## last time (never the password). Other pilots join with this PC's address and the port; a master server address lists it online.
##   ServerSheet.open(self)

const LOG_LINES := 10
const POLL_SECONDS := 0.25
const MIN_PLAYERS := 2
const MAX_BOTS_LIMIT := 200
const EXCLUDED_MODES := ["extraction"]
const MODES := ["vs", "coop", "extraction"]
const MODE_NAMES := ["versus", "co-op", "extraction raid (a persistent raid on the map)"]
## An extraction raid on this PC starts with some faction soldiers and vehicles (ServerConfig's own defaults are none).
const RAID_SOLDIERS := 16
const RAID_VEHICLES := 4
const DEFAULT_MAP := "(first map)"

var _sheet: ModalSheet
var _name: LineEdit
var _map: OptionButton
var _game_mode: OptionButton
var _mode: OptionButton
var _port: LineEdit
var _players: HSlider
var _password: LineEdit
var _bots: HSlider
var _master: LineEdit
var _state: Label
var _join_hint: Label
var _log: Label
var _fields: Array[Control] = []
var _maps: Array = []
var _modes: Array = []
var _wait := 0.0


static func open(host: Control) -> ServerSheet:
	var sheet := ModalSheet.open(host, "RUN DEDICATED SERVER")
	var body := ServerSheet.new()
	body._sheet = sheet
	sheet.body.add_child(body)
	return body


func _ready() -> void:
	var saved := OnlineSettings.server_sheet()
	_maps = MapPicker.make_entries()
	_modes = (GameModes.data().order as Array).filter(func(id: String) -> bool: return id not in EXCLUDED_MODES)
	_name = _add_field("Server name", Widgets.line_edit(str(saved.get("name", ServerConfig.DEFAULTS.name)), "name in the lists"))
	_map = _add_field("Map", Widgets.option_button([DEFAULT_MAP] + _maps.map(func(e: Dictionary) -> String: return str(e.name)), _find_map(str(saved.get("map", "")))))
	_game_mode = _add_field("Game mode", Widgets.option_button(_modes.map(func(id: String) -> String: return GameModes.label_for(id)),
		maxi(0, _modes.find(str(saved.get("game_mode", ServerConfig.DEFAULTS.game_mode))))))
	_mode = _add_field("Players", Widgets.option_button(MODE_NAMES, maxi(0, MODES.find(str(saved.get("mode", ServerConfig.DEFAULTS.mode))))))
	_port = _add_field("Port", Widgets.line_edit(str(saved.get("port", ServerConfig.DEFAULTS.port)), str(Net.GAME_PORT)))
	_players = _add_slider("Max players", MIN_PLAYERS, Net.MAX_PLAYERS, int(saved.get("max_players", ServerConfig.DEFAULTS.max_players)))
	_password = _add_field("Password", Widgets.line_edit("", "empty = open"))
	_password.secret = true
	_bots = _add_slider("Max bots (0 = no cap)", 0, MAX_BOTS_LIMIT, int(saved.get("max_bots", ServerConfig.DEFAULTS.max_bots)))
	_master = _add_field("Master server", Widgets.line_edit(str(saved.get("master", OnlineSettings.master())), "empty = not listed online"))
	_state = Widgets.label("", "StatusLabel")
	add_child(_state)
	_join_hint = Widgets.paragraph("", "DimLabel")
	add_child(_join_hint)
	_log = Widgets.paragraph("", "DimLabel")
	_log.custom_minimum_size = Vector2(0, Widgets.metric("row_height") * LOG_LINES / 2)
	add_child(_log)
	_sheet.set_back("Close")
	_sheet.set_primary("Start server", _toggle)
	_sheet.closed.connect(queue_free)
	_refresh()


func _process(delta: float) -> void:
	_wait += delta
	if _wait >= POLL_SECONDS:
		_wait = 0.0
		LocalServer.poll()
		_refresh()


func _add_field(label_text: String, control: Control) -> Variant:
	add_child(OptionRow.new(label_text, control))
	_fields.append(control)
	return control


func _add_slider(label_text: String, low: int, high: int, value: int) -> HSlider:
	var s := Widgets.slider(low, high, clampi(value, low, high))
	add_child(OptionRow.new(label_text, s).with_value_readout())
	_fields.append(s)
	return s


func _find_map(wanted: String) -> int:
	for i in _maps.size():
		if wanted != "" and (str(_maps[i].name) == wanted or str((_maps[i].config as Dictionary).get("map", "")) == wanted):
			return i + 1
	return 0


## The values on the sheet as ServerConfig keys (the password included).
func make_values() -> Dictionary:
	var map_entry: Dictionary = _maps[_map.selected - 1] if _map.selected > 0 else {}
	var map_id := str((map_entry.get("config", {}) as Dictionary).get("map", map_entry.get("name", "")))
	var values := {"name": _name.text.strip_edges(), "map": map_id, "game_mode": str(_modes[_game_mode.selected]), "mode": MODES[_mode.selected],
		"port": clampi(int(_port.text), 1, 65535), "max_players": int(_players.value), "password": _password.text,
		"max_bots": int(_bots.value), "master": _master.text.strip_edges()}
	if values.mode == ExtractionRules.MODE:
		values.merge({"bots": RAID_SOLDIERS, "ai": RAID_VEHICLES})
	return values


func _toggle() -> void:
	if LocalServer.is_running():
		LocalServer.stop()
		_refresh()
		return
	var values := make_values()
	var saved := values.duplicate()
	saved.erase("password")
	OnlineSettings.apply_server_sheet(saved)
	if values.name == "":
		values.name = str(ServerConfig.DEFAULTS.name)
	var err := LocalServer.start(values)
	if err != OK:
		_sheet.set_status("Could not start the server (error %d)." % err)
	_refresh()


func _refresh() -> void:
	var state := LocalServer.make_state()
	var running := state == "starting" or state == "running"
	for f in _fields:
		if f is LineEdit:
			(f as LineEdit).editable = not running
		elif f is OptionButton:
			(f as OptionButton).disabled = running
		elif f is Range:
			(f as Range).editable = not running
	_sheet.primary_button.text = "Stop server" if running else "Start server"
	_state.text = "Status: %s" % state
	_join_hint.text = make_join_hint(int(make_values().port)) if running else "Others join with this PC's address and the port above (Join by address)."
	_log.text = "\n".join(LocalServer.tail(LOG_LINES))


## "Join with: 192.168.1.20:47700  (this PC: 127.0.0.1:47700)" from this PC's addresses.
static func make_hint_text(addresses: PackedStringArray, port: int) -> String:
	var lan := Array(addresses).filter(func(a: String) -> bool: return a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."))
	var shown := ", ".join(lan.map(func(a: String) -> String: return "%s:%d" % [a, port]))
	return "Join with: %s  (this PC: 127.0.0.1:%d)" % [shown if shown != "" else "(no network address found)", port]


static func make_join_hint(port: int) -> String:
	return make_hint_text(IP.get_local_addresses(), port)
