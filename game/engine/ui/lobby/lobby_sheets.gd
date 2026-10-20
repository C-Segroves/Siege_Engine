class_name LobbySheets
extends RefCounted
## The sheets the lobby opens over itself (docs/design/lobby_loadout_economy.md section 5): the host's detailed options,
## Adjust teams, the campaign wingmen and Operator Setup. Holds the open ones so a roster change refreshes them.

var _screen: LobbyScreen
var _teams: TeamsSheet
var _options: GameOptionsSheet


func _init(screen: LobbyScreen) -> void:
	_screen = screen


## Redraws the open sheets from the session.
func refresh() -> void:
	if is_instance_valid(_teams) and _teams.is_open:
		_teams.refresh(Net.settings, Net.roster, Net.my_id(), Net.is_host())
	if is_instance_valid(_options) and _options.is_open:
		_options.apply_settings(Net.settings)


func open_options() -> void:
	_options = GameOptionsSheet.show_over(_screen, Net.settings)
	_options.settings_changed.connect(_screen.apply_settings)


func open_teams() -> void:
	_teams = TeamsSheet.show_over(_screen)
	_teams.team_chosen.connect(func(peer: int, team: int) -> void:
		if peer == Net.my_id():
			Net.set_my_info("team", team)
		else:
			Net.assign_team(peer, team))
	_teams.member_team_chosen.connect(func(key: String, team: int) -> void:
		_screen.apply_settings(LobbySettings.make_with_member_team(Net.settings, key, team)))
	_teams.assign_all_requested.connect(func() -> void: MatchFlow.apply_team_choices(TeamAssignment.make_assign_all(Net.roster, Net.settings)))
	_teams.shuffle_requested.connect(func() -> void: MatchFlow.apply_team_choices(TeamAssignment.make_shuffle(Net.roster, Net.settings, RandomNumberGenerator.new())))
	_teams.refresh(Net.settings, Net.roster, Net.my_id(), Net.is_host())


func open_wingmen() -> void:
	var sheet := WingmanSheet.show_over(_screen, func() -> void: _screen.launcher().open_hangar("lobby"))
	sheet.changed.connect(_screen.refresh_squad)


## Operator Setup over the lobby with the pilot's profile; the lobby reloads it when the screen closes.
func open_setup(profile: OperatorProfile) -> void:
	var setup := OperatorSetupLauncher.open(_screen, LobbyAnnouncer.make_context(Net.settings, profile), profile.active_slot)
	setup.closed.connect(_screen.on_setup_closed)
