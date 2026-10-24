class_name DedicatedServer
extends Node
## The dedicated server (`--server`): hosts a match over ENet (UDP, the default) or WebSocket (web clients) with no local pilot and runs it
## forever: lobby -> match -> results pause -> next match. The server is the authority for the whole simulation.
##   godot --headless --audio-driver Dummy --path game res://server/dedicated_server.tscn -- --server
##         [--config=<file.json>] [--port= --transport=ws|enet --mode=vs|coop --map= --bots= --password= --master=http://host:47710 ...]
## Settings: ServerConfig. Game data: the server loads the operator's own installed packs; it never serves them.
## Prints "SERVER ..." lines; quits with 1 when it cannot listen.

const BATTLE_SCENE := "res://games/es1/battle.tscn"
const START_DELAY := 2.0
const LOBBY := 0
const MATCH := 1

var cfg := {}
## False: a check sets `cfg` and calls start() itself.
var autostart := true
var _battle: Node
var _state := LOBBY
var _waited := 0.0
var _idle := 0.0
var _list: MatchListServer
var _presence: MasterPresence
## Mode "extraction": one persistent raid instead of lobby -> match -> results (null in the other modes).
var _raid: RaidServer


func _ready() -> void:
	if not autostart:
		return
	cfg = ServerConfig.load_from_args(OS.get_cmdline_user_args())
	if not ServerConfig.MODES.has(str(cfg.mode)):
		push_error("server: mode '%s' is not one of %s; playing vs" % [cfg.mode, ServerConfig.MODES])
		cfg.mode = "vs"
	start.call_deferred()


func start() -> void:
	ServerProfile.set_collision_only(true)   # before anything is built: a collision-only world (engine/server_profile.gd)
	if str(cfg.data_dir) != "":   # the operator's imported packs (the server reads them, it never serves them)
		Assets.settings["data_dir"] = str(cfg.data_dir)
		Assets.refresh()
		Packs.reload()
	print("SERVER data: %s packs: %s" % [Assets.data_root, ", ".join(Assets.installed_packs())])
	ServerClock.follows_profile = int(cfg.tick_hz) <= 0
	ServerClock.configure_dedicated(int(cfg.tick_hz) if int(cfg.tick_hz) > 0 else ServerClock.DEFAULT_HZ, int(cfg.max_catchup_steps))
	Net.server_name = str(cfg.name)
	Net.password = str(cfg.password)
	Net.player_name = str(cfg.name)
	Net.max_players = clampi(int(cfg.max_players), 1, Net.MAX_PLAYERS)
	var err := Net.host(int(cfg.port), str(cfg.transport), true, str(cfg.bind))
	if err != OK:
		print("SERVER FAILED: cannot listen on port %d (error %d)" % [int(cfg.port), err])
		get_tree().quit(1)
		return
	Net.set_settings(ServerConfig.make_settings(cfg))
	LobbyChatHub.ensure(get_tree())   # relays the lobby chat between the pilots
	Net.list_port = int(cfg.list_port)
	if str(cfg.mode) == ExtractionRules.MODE:
		_raid = RaidServer.new(cfg)
		add_child(_raid)
	_list = MatchListServer.new()
	add_child(_list)
	if int(cfg.list_port) > 0 and _list.start(int(cfg.list_port), str(cfg.bind)) != OK:
		push_warning("server: match list port %d busy" % int(cfg.list_port))
	if str(cfg.master) != "":   # listed on a master server (docs/SERVER_DEPLOY.md "Run a master server")
		_presence = MasterPresence.begin(self, str(cfg.master), str(cfg.master_token), int(cfg.list_port))
		print("SERVER listing on master %s" % _presence.master)
	Net.game_starting.connect(_on_game_starting)
	Net.game_ended.connect(_on_game_ended)
	print("SERVER READY %s port=%d transport=%s mode=%s" % [cfg.name, int(cfg.port), cfg.transport, cfg.mode])


func _process(delta: float) -> void:
	if _raid != null:
		_raid.update(delta)
	elif _state == LOBBY:
		_tick_lobby(delta)
	elif Net.roster.is_empty():
		_idle += delta
		if _idle >= float(cfg.idle_abort_seconds) and _battle is Battle:
			print("SERVER match abandoned")
			(_battle as Battle).abort_match("Everybody left", {})
			_idle = 0.0
	else:
		_idle = 0.0


## Starts the match when enough pilots are in and all are ready, or `lobby_seconds` after they were enough.
func _tick_lobby(delta: float) -> void:
	if Net.roster.size() < int(cfg.min_players):
		_waited = 0.0
		return
	_waited += delta
	var all_ready := Net.make_unready_names().is_empty()
	if (all_ready and _waited >= START_DELAY) or _waited >= float(cfg.lobby_seconds):
		start_match()


func start_match() -> void:
	_state = MATCH
	_waited = 0.0
	_idle = 0.0
	MatchFlow.apply_team_choices(TeamAssignment.make_assign_all(Net.roster, Net.settings))
	print("SERVER match start: %d pilots" % Net.roster.size())
	MatchFlow.start_hosted_match()


func _on_game_starting(config: Dictionary) -> void:
	if is_instance_valid(_battle):
		return
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.set("config", config)
	get_tree().root.add_child(_battle)
	_add_metrics(_battle as Battle)
	if _raid != null:
		_raid.attach_battle(_battle as Battle)


## Times the battle's ticks and prints "SERVER STATS ..." every `stats_seconds` (0 = never).
func _add_metrics(battle: Battle) -> void:
	var metrics := ServerMetrics.new(battle, float(cfg.stats_seconds))
	metrics.budget_ms = ServerClock.MILLISECONDS / float(ServerClock.dedicated_hz)
	battle.add_child(metrics)


## The battle freed itself (Battle._finish): the pilots see their results for a while, then the next match.
func _on_game_ended() -> void:
	if _raid != null:
		_battle = null   # the raid server decides when the next world opens
		return
	_state = LOBBY
	_battle = null
	_waited = -float(cfg.results_seconds) + float(cfg.lobby_seconds)   # the next match starts after results_seconds
	print("SERVER match ended")
