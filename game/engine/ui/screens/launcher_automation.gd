class_name LauncherAutomation
## Command-line automation of the launcher for tests (user args after `--`):
##   --autohost=<players> [--mode=vs|team_vs|coop|campaign]   host, wait for the players to be ready, start
##   --autojoin=<ip>                                   join a host and mark ready
##   --page=<page> [--herc=<id>] [--shot=<png>]        open a page, optionally pick a Herc, screenshot + quit
##   [--map=<name part>] [--game_mode=<id part>] [--bots=<n>]   host page: pick that map / game mode / bot count
## Pages: menu | armory | options | host[:<mode>] | browser | lobby:<coop|vs|campaign> | saga |
##        debrief | briefing:<es1|es2|starsiege|starsiege-cybrid> | hangar:<same games> | training:<tribes|tribes2> |
##        new_campaign | saves[:save|load] | killed:<same games as briefing>
## Only the first launcher of a process runs them (run()).

const AUTOHOST_AI := 2
const TEAM_VERSUS := "team_vs"
const PLAYER_POLL := 0.25        # seconds between roster checks
const START_DELAY := 0.5
const SAGA_STAGES_TO_STARSIEGE := 2
const STARSIEGE_PROVIDER := "res://games/starsiege/campaign_provider.gd"


## The automation arguments are acted on once per process: a launcher reopened after a battle
## must not start another campaign or host again.
static var _consumed := false


## Acts on the automation arguments on the first launcher of the process; later launchers are left alone.
static func run(launcher: Launcher) -> void:
	if _consumed:
		return
	_consumed = true
	var host := ScreenRouter.arg_value("autohost")
	var join := ScreenRouter.arg_value("autojoin")
	var page := ScreenRouter.arg_value("page")
	if host != "":
		await _autohost(launcher, int(host))
	elif join != "":
		Net.player_name = "Client"
		Net.connected_to_server.connect(_mark_ready_soon.bind(launcher), CONNECT_ONE_SHOT)
		Net.join(join)
	elif page != "":
		_open_page(launcher, page)
		_apply_herc_arg(launcher)
		var shot := ScreenRouter.arg_value("shot")
		if shot != "":
			await launcher.save_shot_and_quit(shot)


static func _autohost(launcher: Launcher, players: int) -> void:
	Net.player_name = "Host"
	launcher.context.vehicle = str(Packs.pilotable()[0].id) if not Packs.pilotable().is_empty() else MatchFlow.DEFAULT_VEHICLE
	var mode := ScreenRouter.arg_value("mode")
	var known := mode in MatchFlow.MODES or mode == TEAM_VERSUS
	launcher.go("host", {"mode": mode if known else "vs", "ai": AUTOHOST_AI}).call("create_lobby")
	var tree := launcher.get_tree()
	while Net.roster.size() < players or MatchFlow.make_start_block_reason() != "":
		MatchFlow.apply_team_choices(TeamAssignment.make_assign_all(Net.roster, Net.settings))
		await tree.create_timer(PLAYER_POLL).timeout
	await tree.create_timer(START_DELAY).timeout
	print("autohost: starting %s match with %d pilots" % [Net.settings.mode, Net.roster.size()])
	MatchFlow.start_hosted_match()


## A joined client marks itself ready once the lobby has its roster entry.
static func _mark_ready_soon(launcher: Launcher) -> void:
	var tree := launcher.get_tree()
	while not Net.roster.has(Net.my_id()):
		await tree.create_timer(PLAYER_POLL).timeout
	Net.set_my_info("ready", true)


static func _open_page(launcher: Launcher, page: String) -> void:
	var parts := page.split(":")
	var detail := parts[1] if parts.size() > 1 else ""
	match parts[0]:
		"lobby":
			launcher.go("host", {"mode": detail if detail != "" else "vs"}).call("create_lobby")
		"host":
			var host_args := {"mode": detail if detail != "" else "vs"}
			if ScreenRouter.arg_value("bots") != "":
				host_args[InfantryBots.CONFIG_KEY] = int(ScreenRouter.arg_value("bots"))
			var host := launcher.go("host", host_args)
			if ScreenRouter.arg_value("map") != "":
				host.call("select_map", ScreenRouter.arg_value("map"))
			if ScreenRouter.arg_value("game_mode") != "":
				host.call("select_game_mode", ScreenRouter.arg_value("game_mode"))
		"briefing":
			_start_campaign_of(detail)
			launcher.show_campaign()
		"hangar":
			_start_campaign_of(detail)
			launcher.open_hangar("briefing")
		"saga":
			_start_saga_at_starsiege()
			launcher.show_campaign()
		"debrief":
			Session.start_campaign(0, false)
			Session.last_result = {"success": true, "text": "Automation: all objectives complete."}
			launcher.go("debrief")
		"options":
			launcher.go("options", {"home": "menu"})
		"training":
			launcher.go("training", {"pack": detail if detail != "" else "tribes"})
		"killed":
			_start_campaign_of(detail)
			Session.last_result = {"success": false, "pilot_killed": true}
			launcher.go("killed")
		"saves":
			launcher.go("saves", {"mode": detail if detail != "" else "load"})
		_:
			launcher.go(parts[0])


static func _start_campaign_of(game: String) -> void:
	Session.saga = null
	match game:
		"es2":
			Session.campaign = CampaignES2.start(1)
		"starsiege", "starsiege-cybrid":
			Session.campaign = load(STARSIEGE_PROVIDER).start("cybrid" if game.ends_with("cybrid") else "human")
		_:
			Session.start_campaign(0, false)


static func _start_saga_at_starsiege() -> void:
	Session.start_saga()
	for i in SAGA_STAGES_TO_STARSIEGE:
		Session.saga.advance()
	Session.campaign = Session.saga.campaign


static func _apply_herc_arg(launcher: Launcher) -> void:
	var herc := ScreenRouter.arg_value("herc")
	if herc != "" and launcher.current != null and launcher.current.herc_selector != null:
		launcher.current.herc_selector.select_vehicle(Assets.qualify(herc))
