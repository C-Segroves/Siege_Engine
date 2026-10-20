class_name LauncherAutomation
## Command-line automation of the launcher for tests (user args after `--`):
##   --autohost=<players> [--mode=vs|team_vs|coop|campaign]   host a lobby, wait for the players to be ready, start
##   --autojoin=<ip>                                   join a host and mark ready
##   --page=<page> [--shot=<png>]                      open a page, screenshot + quit
##   [--map=<name part>] [--game_mode=<id part>] [--bots=<n>]   lobby pages: pick that map / game mode / bot count
## Pages: menu | options | lobby[:<vs|team_vs|coop|campaign|skirmish|extraction>] (a LAN lobby; skirmish and extraction
##        are offline) | host[:<kind>] (the same) | armory (the skirmish lobby) | extraction (the raid lobby) | browser |
##        saga | debrief | briefing:<es1|es2|starsiege|starsiege-cybrid> (that campaign's lobby) |
##        hangar:<same games> | training:<tribes|tribes2> | new_campaign | saves[:save|load] | killed:<same games as briefing>
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
		var shot := ScreenRouter.arg_value("shot")
		if shot != "":
			await launcher.save_shot_and_quit(shot)


static func _autohost(launcher: Launcher, players: int) -> void:
	Net.player_name = "Host"
	var mode := ScreenRouter.arg_value("mode")
	var known := mode in MatchFlow.MODES or mode == TEAM_VERSUS
	_open_lobby(launcher, mode if known else GameOptionsModel.KIND_VERSUS, true, AUTOHOST_AI)
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


## Opens a lobby of `kind` ("team_vs" = versus in the map's first team mode) and applies the automation arguments
## (--map, --game_mode, --bots) and `ai` opponents (-1 = the kind's default) the way the host's Game Options would.
## `lan` false makes a raid an offline one (a skirmish always is).
static func _open_lobby(launcher: Launcher, kind: String, lan := true, ai := -1) -> void:
	var team_vs := kind == TEAM_VERSUS
	var real_kind := GameOptionsModel.KIND_VERSUS if team_vs else kind
	var solo := real_kind == GameOptionsModel.KIND_SKIRMISH or (real_kind == GameOptionsModel.KIND_EXTRACTION and not lan)
	launcher.open_lobby(real_kind, solo)
	var s := Net.settings
	if ai >= 0:
		s = GameOptionsModel.make_with_value(s, "ai", ai)
	if ScreenRouter.arg_value("bots") != "":
		s = GameOptionsModel.make_with_value(s, InfantryBots.CONFIG_KEY, int(ScreenRouter.arg_value("bots")))
	s = _apply_map_arg(s)
	s = _apply_game_mode_arg(s, team_vs)
	Net.set_settings(s)


static func _apply_map_arg(s: Dictionary) -> Dictionary:
	var part := ScreenRouter.arg_value("map").to_lower()
	if part == "":
		return s
	var entries := MapPicker.make_entries()
	for i in entries.size():
		if str(entries[i].name).to_lower().contains(part):
			return GameOptionsModel.make_with_map(s, i)
	return s


static func _apply_game_mode_arg(s: Dictionary, team_vs: bool) -> Dictionary:
	var part := ScreenRouter.arg_value("game_mode").to_lower()
	for m in GameOptionsModel.make_game_modes(s):
		var matches := str(m.id).contains(part) or str(m.label).to_lower().contains(part) if part != "" else team_vs and bool(m.team_based)
		if matches:
			return GameOptionsModel.make_with_game_mode(s, str(m.id))
	return s


static func _open_page(launcher: Launcher, page: String) -> void:
	var parts := page.split(":")
	var detail := parts[1] if parts.size() > 1 else ""
	match parts[0]:
		"lobby", "host":
			_open_lobby(launcher, detail if detail != "" else GameOptionsModel.KIND_VERSUS)
		"armory":
			_open_lobby(launcher, GameOptionsModel.KIND_SKIRMISH, false)
		"extraction":
			_open_lobby(launcher, GameOptionsModel.KIND_EXTRACTION, false)
		"briefing":
			_start_campaign_of(detail)
			launcher.show_started_campaign()
		"hangar":
			_start_campaign_of(detail)
			launcher.open_hangar("lobby")
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
