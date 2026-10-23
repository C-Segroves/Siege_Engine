class_name Battle
extends Node3D
## A combat session: world + vehicles + rules. Works single player and over LAN.
##
## config:
##   mode       "skirmish" (vs AI), "coop" (players vs Cybrids), "vs" (deathmatch / team), "mission"
##   world      Earthsiege world index (terrain*6 + time*2), zone: terrain zone file
##   roster     {peer_id: {name, vehicle, team, loadout}}
##   ai         [{vehicle, team, skill, name}]
##   frag_limit, respawn (bool), teams (bool)
## The host simulates everything; clients render puppets from snapshots and send inputs.
##
## Parts (games/es1/battle/): BattleSetup (config, mission, world), BattleSpawner, BattleCameras,
## BattleOverlay (HUD, cockpit, scoreboard), BattleNetSync, BattleFx, BattleRules, BattleMusic,
## BattleExit (in-battle menu, abort / leave) and BattleSummary (the results screen's data); soldiers on foot
## and where players start: BattleInfantry; boarding and leaving vehicles: OccupancyDirector (engine/occupancy).
## Every match ends on the results screen (MatchResults), which leads back to the front end.
## Test flags: see BattleSetup, plus --screenshot=<png> [--overview].

## Mission result (success, code, vars, text, salvage), passed back to the campaign via Session.
signal match_finished(result: Dictionary)

const END_MESSAGE_SECONDS := 12.0
const RETURN_DELAY := 6.0           # seconds from the end message to the results screen
const MSEC_PER_SECOND := 1000.0
const SCREENSHOT_THROTTLE := 0.6
const SCREENSHOT_SETTLE := 0.5
const SCREENSHOT_DRIVE := 2.5
const OVERVIEW_FAR := 4000.0
const OVERVIEW_BACK := 40.0
const OVERVIEW_UP := 25.0
const OVERVIEW_LOOK_HEIGHT := 4.0

var config := {}
## The config the battle was started with (before setup filled it in): what a rematch replays.
var initial_config := {}
var world_info := {}
var palette_id := "es1:WORLD0"
var vehicles := {}            # net_id -> Herc
## Every vehicle and soldier as packed arrays, updated once per physics tick (the server's view for the network).
var entities := EntityTable.new()
## What the local player controls: his vehicle, or his soldier on foot (Infantry).
var player: Herc
var pilot: PlayerPilot
var infantry: BattleInfantry
var bot_sleep: BotSleep
var occupancy: OccupancyDirector
## The host's per-pilot match statistics (assists, vehicle kills, damage ...) behind the results and the credits award.
var stats := BattleStats.new(self)
## A client's far bots: nodes dropped while FAR, drawn as proxies (null on a host and in single player).
var far_units: BattleFarUnits
## The extraction raid (config mode "extraction"; null in other modes).
var extraction: ExtractionDirector
## The game mode's rules, objects and HUD (config "game_mode" played by GameModeDirector; null otherwise).
var game_mode: GameModeDirector
var hud: HUD
var mission: MissionRuntimeBase
var result := {}
var use_chase := false
var overlay: BattleOverlay
## The chat panel, the players' LAN chat and the campaign radio (child "Chat").
var chat: BattleChat
var cameras := BattleCameras.new()
var spawner: BattleSpawner
## Out of bounds and fallen out of the world (child "Bounds").
var bounds: BattleBounds
var _fx: BattleFx
var _rules: BattleRules
var _music := BattleMusic.new()
## A Battledrome Herc's cockpit warnings (text + voice) for the local pilot.
var _cockpit_messages: BdCockpitMessages
var _exit: BattleExit
var _over := false
var _finished := false
var _outcome := {}                 # {text, winner, aborted} for the results screen
var _started_msec := 0
var _ended_msec := 0
var _engine_loop: AudioStreamPlayer3D


static func default_config(vehicle := "es1:RAPTOR") -> Dictionary:
	return BattleSetup.make_default_config(vehicle)


func _ready() -> void:
	set_process(false)   # _process reads the overlay and the cameras: it starts only when the build below has finished
	name = "Battle"
	ShapeInstance.world_palettes.clear()   # set again by MapBuilder for Darkstar maps
	PersonalWaypoints.clear()
	TeamRelations.clear()                  # a mode sets its own (the extraction factions)
	spawner = BattleSpawner.new(self)
	_fx = BattleFx.new(self)
	_rules = BattleRules.new(self)
	add_child(BattleNetSync.new(self))
	occupancy = OccupancyDirector.new(self)
	add_child(occupancy)
	if not multiplayer.is_server():
		far_units = BattleFarUnits.new(self)
		add_child(far_units)
	_exit = BattleExit.new(self)
	add_child(_exit)
	if config.is_empty():
		config = BattleSetup.make_config_from_args(OS.get_cmdline_user_args())
	GameModes.apply_to_config(config)
	initial_config = config.duplicate(true)
	MapTeams.apply_battle(config)
	_started_msec = Time.get_ticks_msec()
	infantry = BattleInfantry.new(self)
	var mdef := BattleSetup.load_mission_def(config)
	if not mdef.is_empty():
		BattleSetup.apply_mission_to_config(config, mdef)
	var built := _build_world()
	LoadKeepAlive.pump()
	if not mdef.is_empty():
		_start_mission(mdef)
	_build_bounds(built, mdef)
	LoadKeepAlive.pump()
	spawner.build_spawn_points(built)
	LoadKeepAlive.pump()
	TribesBase.build_for(self, built)
	LoadKeepAlive.pump()
	add_child(TribesStations.new(self, built.get("stations", [])))
	CommandProviders.build_for(self)
	LoadKeepAlive.pump()
	_add_map_pickups()
	_build_ui()
	LoadKeepAlive.pump()
	_cockpit_messages = BdCockpitMessages.new(func(text: String) -> void:
		overlay.show_message(text, BdCockpitMessages.TEXT_SECONDS))
	if ExtractionRules.is_extraction(config):
		extraction = ExtractionDirector.new(self, built)
		add_child(extraction)
	if GameModes.uses_director(config):
		game_mode = GameModeDirector.new(self, built)
		add_child(game_mode)
	bot_sleep = BotSleep.new(self)
	LoadKeepAlive.pump()
	add_child(bot_sleep)
	if multiplayer.is_server():
		spawner.spawn_roster()
		LoadKeepAlive.pump()
		infantry.spawn_bots()
		LoadKeepAlive.pump()
		if extraction:
			extraction.start_host()
	_music.start(config, mdef)
	_start_screenshot_flag()
	set_process(true)


## The playable area and the world floor (BattleBounds); a Tribes mission's scripts own its mission area.
func _build_bounds(built: Dictionary, mdef: Dictionary) -> void:
	bounds = BattleBounds.new(self, MapBounds.make_for(self, built))
	bounds.area_rule = MissionKinds.make_area_rule(mdef)
	add_child(bounds)


## The weapons, ammunition and packs lying in a Tribes map (TribesPickups; a mission's own script places its items).
func _add_map_pickups() -> void:
	var pickups := TribesPickups.make_for(self, str(config.get("map", ""))) if mission == null else null
	if pickups:
		add_child(pickups)


func _build_world() -> Dictionary:
	var world := BattleSetup.build_world(self, config)
	world_info = world.world_info
	palette_id = world.built.palette
	FxLibrary.clear_world_palettes()
	FxLibrary.set_world_palette(palette_id)   # ES1/ES2 effects are drawn in the world's palette
	return world.built


func _start_mission(mdef: Dictionary) -> void:
	mission = BattleSetup.make_mission_runtime(mdef)
	mission.name = "Mission"
	add_child(mission)
	mission.setup(self, mdef, config.get("mission_vars", PackedInt32Array()))
	mission.mission_over.connect(func(ok, code, text):
		end_match(text, MissionOutcome.make_ended(ok, code, mission.mission_vars, text, is_player_killed())
			.merged(mission.make_result_extra()).merged(_rules.salvage.make_result_fields(vehicles))))


## The local player's Herc was destroyed: Earthsiege counts its pilot as killed (GO.EXE 0x3bc94 ends the career).
func is_player_killed() -> bool:
	return player != null and is_instance_valid(player) and not player.alive


func _build_ui() -> void:
	cameras.build_chase_camera(self)
	overlay = BattleOverlay.new()
	add_child(overlay)
	hud = overlay.hud
	overlay.add_child(InfantryHud.new(occupancy))
	overlay.build_objectives_panel(self)
	BoundsVisual.build_for(self)   # the area wall and the outside tint (nothing on a dedicated server)
	chat = BattleChat.new(self)
	add_child(chat)
	var plates := Nameplates.new(self)
	plates.occupied_provider = chat.make_occupied_rects
	overlay.occupied_provider = func() -> Array: return chat.make_occupied_rects() + [chat.panel.make_collapsed_rect()]
	add_child(plates)
	overlay.show_intro(config)


# ------------------------------------------------------------------ spawning

## Host: spawns an AI unit (used by the mission runtime). Returns the authoritative Herc.
func spawn_ai(vehicle_id: String, team: int, xf: Transform3D, loadout: Array, pname: String, info: Dictionary) -> Herc:
	var spec := spawner.make_mission_ai_spec({"vehicle": vehicle_id, "team": team, "xf": xf, "loadout": loadout,
		"name": pname, "info": info})
	send_spawn(spec)
	return vehicles.get(spec.net_id)


## Host: creates a vehicle from a BattleSpawner spec on every peer (a player's vehicle may become a parked
## vehicle plus his soldier: BattleInfantry.rewrite_player_spawn).
func send_spawn(spec: Dictionary) -> void:
	for s in infantry.rewrite_player_spawn(spec):
		infantry.apply_start_place(s)
		_spawn.rpc(s)


## Host: a soldier for `peer` at `xf` on every peer (he leaves a vehicle he started in).
func spawn_soldier_for(peer: int, team: int, pname: String, xf: Transform3D) -> Infantry:
	var spec := infantry.make_soldier_spec(peer, team, pname, xf)
	_spawn.rpc(spec)
	return vehicles.get(spec.net_id) as Infantry


## The name `peer` plays under (the roster's).
func make_pilot_name(peer: int) -> String:
	return str(config.get("roster", {}).get(peer, {}).get("name", Net.player_name))


@rpc("authority", "reliable", "call_local")
func _spawn(spec: Dictionary) -> void:
	if far_units:
		far_units.note_spawn(spec)
	build_unit(spec)


## Builds the vehicle or soldier of a spawn spec on this peer and registers it (also when a client brings a far bot back).
func build_unit(spec: Dictionary) -> Herc:
	var h := infantry.build_soldier(spec) if spec.has("armor") else spawner.build_vehicle(spec)
	if spec.get("parked", false):
		BattleInfantry.apply_parked(h)
	occupancy.register(h, spec)
	h.destroyed.connect(_rules.on_destroyed)
	if multiplayer.is_server():
		stats.watch(h)
	if h is Infantry and multiplayer.is_server():
		h.destroyed.connect(func(s: Herc, _killer: Node) -> void: infantry.on_soldier_destroyed(s as Infantry))
	if spawner.is_local_player(h, spec):
		switch_control(h)   # a soldier made as the player leaves his vehicle: the vehicle's controls go
	elif multiplayer.is_server():
		spawner.attach_ai(h, spec)
	return h


## Gives the local player control of `h` (boarding or leaving a vehicle): the old controls and view go.
func switch_control(h: Herc) -> void:
	if h == player:
		return
	_release_player()
	_attach_player(h)


## Rebuilds the local player's controls and view on the same body (a soldier changed armour).
func refresh_player_view() -> void:
	var h := player
	_release_player()
	if is_instance_valid(h):
		_attach_player(h)


func _release_player() -> void:
	if is_instance_valid(pilot):
		pilot.queue_free()
	pilot = null
	if is_instance_valid(_engine_loop):
		_engine_loop.queue_free()
	_engine_loop = null
	if is_instance_valid(player):
		player.remove_meta("local_player")
		cameras.release_cockpit_camera(player)
	player = null


func _attach_player(h: Herc) -> void:
	player = h
	h.set_meta("local_player", true)
	if not (h is Infantry):
		_engine_loop = Sfx.attach_loop("engine", h)
	pilot = occupancy.make_pilot_for(h)
	add_child(pilot)
	use_chase = h.prefers_chase_view()
	cameras.build_cockpit_camera(h)
	overlay.build_cockpit(h, self)
	if overlay.cockpit:
		overlay.cockpit.set_camera(cameras.cockpit_cam)
	_apply_view()
	overlay.announce_player(h, str(config.get("herc_name", h.def.get("name", h.vehicle_id))))


# ------------------------------------------------------------------ frame loop / input

## The in-battle menu (also opened by menu_pause, see BattleExit).
func open_menu() -> void:
	_exit.open_menu()


func is_menu_open() -> bool:
	return _exit.is_menu_open()


## The open in-battle menu (null when closed).
func battle_menu() -> BattleMenu:
	return _exit.menu if _exit.is_menu_open() else null


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action("scoreboard") and not event.is_echo():
		overlay.set_scoreboard_visible(event.is_pressed(), vehicles)
	elif event.is_action_pressed("view_toggle") and player:
		use_chase = not use_chase
		_apply_view()


func _apply_view() -> void:
	var chase := use_chase or player == null or not player.alive
	var camera := cameras.apply_view(chase)
	overlay.apply_view(camera, camera == cameras.chase_cam)


func _process(delta: float) -> void:
	if player:
		_apply_view()
		if cameras.is_chasing():
			cameras.apply_follow(player, delta)
		else:
			cameras.apply_sight(player)
			cameras.apply_scope(player)
	if overlay.scoreboard.visible:
		overlay.update_scoreboard(vehicles)
	_music.update(player, delta)
	_cockpit_messages.update(player, delta, not _over)


func _physics_process(delta: float) -> void:
	if multiplayer.is_server():
		_rules.update(delta)
		infantry.update(delta)
		if not _over:
			stats.update(delta)


# ------------------------------------------------------------------ effects

## Visual/audio effect (see BattleFx): runs locally and, on the host, on every client.
func fx(kind: String, args: Array, reliable := false) -> void:
	_fx.play(kind, args)
	if not (Net.is_online() and multiplayer.is_server()):
		return
	if reliable:
		_fx_reliable.rpc(kind, args)
	else:
		_fx_unreliable.rpc(kind, args)


## A campaign radio line (wingman, commander, base; ChatChannels.RADIO) on every peer, shown in the chat when its
## voice clip (a Sfx sound name, "" = none) starts to play (RadioVoice).
func radio(speaker: String, text: String, voice := "") -> void:
	fx("radio", [speaker, text, voice], true)


@rpc("authority", "unreliable")
func _fx_unreliable(kind: String, args: Array) -> void:
	_fx.play(kind, args)


@rpc("authority", "reliable")
func _fx_reliable(kind: String, args: Array) -> void:
	_fx.play(kind, args)


# ------------------------------------------------------------------ end of the match

func is_over() -> bool:
	return _over


## Seconds from the start of the battle to the end of the match (or until now).
func match_seconds() -> float:
	var end_msec := _ended_msec if _over else Time.get_ticks_msec()
	return (end_msec - _started_msec) / MSEC_PER_SECOND


## Ends the match once: announces `text` (and the `winner`, if any), then shows everyone the results.
func end_match(text: String, p_result := {}, winner := "") -> void:
	if _over:
		return
	_mark_over(text, p_result, {"winner": winner})
	fx("message", [text, END_MESSAGE_SECONDS], true)
	if ArenaAnnouncer.is_arena(config):
		fx("arena_end", [winner], true)
	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = RETURN_DELAY
	timer.timeout.connect(finish_match)
	add_child(timer)
	timer.start()


## Ends the match at once by the player's choice (abort mission / leave a skirmish): `p_result` is the
## mission's (failed) result, {} for a match.
## A match that has already ended just skips the rest of its end message.
func abort_match(text: String, p_result: Dictionary) -> void:
	if not _over:
		_mark_over(text, p_result, {"aborted": true})
	finish_match()


func _mark_over(text: String, p_result: Dictionary, outcome: Dictionary) -> void:
	_over = true
	_ended_msec = Time.get_ticks_msec()
	result = p_result
	_outcome = outcome
	_outcome.text = text
	match_finished.emit(result)


## Host / single player: hands every peer the result and the summary, which opens the results screen.
func finish_match() -> void:
	if _finished:
		return
	_finished = true
	var summary := BattleSummary.make(self, _outcome)
	if Net.is_online():
		_finish.rpc(result, summary)
	else:
		_finish(result, summary)


@rpc("authority", "reliable", "call_local")
func _finish(p_result: Dictionary, summary: Dictionary) -> void:
	result = p_result
	_leave_battle_state()
	if Net.dedicated:   # a dedicated server shows no results: the next match is its DedicatedServer's
		Net.end_game()
		queue_free()
		return
	if not result.is_empty():
		Session.last_result = result
		if not Net.is_online():
			MissionLaunch.on_battle_finished(result)
	Net.end_game()
	MatchResults.open_in_place_of(self, summary)


## Leaves without results (LAN: this pilot left, or the host closed the session): back to the front
## end, whose status line shows `status`.
func leave_to_front_end(status: String) -> void:
	_leave_battle_state()
	Session.front_end_status = status
	get_tree().change_scene_to_file(Session.front_end_scene())


## Leaves without results straight to the app's main menu (the library), whatever front end
## launched the battle. A campaign is left where it was: the current mission is not counted.
func leave_to_main_menu() -> void:
	_leave_battle_state()
	get_tree().change_scene_to_file(Session.MAIN_MENU_SCENE)


## Host: takes vehicle `net_id` out of the battle on every peer (its pilot left the LAN match).
func remove_vehicle(net_id: int) -> void:
	if Net.is_online():
		_remove_vehicle.rpc(net_id)
	else:
		_remove_vehicle(net_id)


@rpc("authority", "reliable", "call_local")
func _remove_vehicle(net_id: int) -> void:
	var h: Herc = vehicles.get(net_id)
	vehicles.erase(net_id)
	entities.unregister(net_id)
	if far_units:
		far_units.apply_removed(net_id)
	if is_instance_valid(h):
		h.queue_free()


func _leave_battle_state() -> void:
	Session.show_play_tab()
	get_tree().paused = false
	_music.stop()
	Sfx.stop_music(0.5)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# ------------------------------------------------------------------ test screenshots

func _start_screenshot_flag() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screenshot="):
			_shoot(a.substr(13))


## --screenshot=<png>: drives forward for a moment, saves the frame and quits.
## --overview: from a raised camera behind the Herc, without the 2D layers.
func _shoot(path: String) -> void:
	await get_tree().create_timer(SCREENSHOT_SETTLE).timeout
	if player:
		player.throttle = SCREENSHOT_THROTTLE
	await get_tree().create_timer(SCREENSHOT_DRIVE).timeout
	if player and "--overview" in OS.get_cmdline_user_args():
		_build_overview_camera()
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


func _build_overview_camera() -> void:
	var gh := MapBuilder.ground_height(self, player.global_position)
	print("overview: herc at ", player.global_position, " ground ", gh, " on_floor ", player.is_on_floor())
	var cam := Camera3D.new()
	cam.far = OVERVIEW_FAR
	add_child(cam)
	var back := player.global_transform.basis.z.normalized()
	cam.look_at_from_position(player.global_position + back * OVERVIEW_BACK + Vector3.UP * OVERVIEW_UP,
		player.global_position + Vector3.UP * OVERVIEW_LOOK_HEIGHT)
	cam.make_current()
	for c in get_children():
		if c is CanvasLayer:
			c.visible = false
