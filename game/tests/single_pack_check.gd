extends Node
## A player who owns only one game (tools/sandbox_iso_test.py runs this once per disc image, each with a fresh user
## store whose settings point the data folder at that game's freshly imported pack):
##   1 the library lists exactly that game; its cards, the versions page (the release is identified and tested),
##     Options and the shape viewer open; the map list offers nothing of a game that is not installed
##   2 its campaign (Earthsiege 1 / 2, Starsiege) starts and the first mission builds and runs
##   3 an arena / versus battle on one of its maps with a bot runs ARENA_SECONDS of game time; the command map
##     opens, the game mode runs, the cockpit is the game's own or a plain HUD
##   4 Tribes / Tribes 2: the soldier spawns on foot, boards the parked vehicle, a training mission loads
##   5 cross-pack features without the other games: hangar, weapon look-alikes from installed packs only, music,
##     no infantry (pilots stay aboard) and no extraction without a Tribes pack, game modes of its maps
## Every script error logged during the run fails the check.
##   godot --headless --audio-driver Dummy --path game res://tests/single_pack_check.tscn -- --test-store=<dir>
##       --expect-pack=<pack> [--report=<json>] [--shots=<dir> (needs a window)]

const LIBRARY := "res://library.tscn"
const LAUNCHER := "res://launcher.tscn"
const VIEWER := "res://tools/shape_viewer.tscn"
const BATTLE := "res://games/es1/battle.tscn"
const HANGAR := "res://engine/hangar/hangar_bay.tscn"
const TRIBES_PACKS := ["tribes", "tribes2"]
const ARENA_SECONDS := 20.0
const CAMPAIGN_SECONDS := 5.0
const TRAINING_SECONDS := 8.0
const TIME_SCALE := 4.0
const SETTLE_FRAMES := 30
const SHOT_DELAY_FRAMES := 20
const BOT_SKILL := 0.5
const ENEMY_TEAM := 1
const BD_ARENA := {"size": 3, "obstacles": "SEVERAL", "turrets": "FEW", "lighting": "BRIGHT"}
const BOARD_GAP := 1.5
## Longer than the Tribes 2 remount delay.
const TOUCH_SECONDS := 6.0


class ErrorCounter extends Logger:
	var messages: Array[String] = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool,
			error_type: int, _script_backtrace: Array[ScriptBacktrace]) -> void:
		if error_type == ERROR_TYPE_SCRIPT and messages.size() < 50:
			messages.append("%s (%s:%d %s) %s" % [rationale if rationale != "" else code, file, line, function, code])


var _pack := ""
var _checks: Array = []
var _errors := ErrorCounter.new()
var _shots := ""


func _ready() -> void:
	OS.add_logger(_errors)
	_pack = ScreenRouter.arg_value("expect-pack")
	_shots = ScreenRouter.arg_value("shots")
	if _pack == "":
		print("single_pack_check: needs --expect-pack=<pack> and --test-store=<dir> (tools/sandbox_iso_test.py), skipped")
		get_tree().quit(0)
		return
	await _run()
	_record("no script errors", _errors.messages.is_empty(), "; ".join(_errors.messages.slice(0, 10)))
	_write_report()
	var failed := _checks.filter(func(c: Dictionary) -> bool: return not c.ok).size()
	print("single_pack_check %s: %s (%d of %d checks failed)" % [_pack, "OK" if failed == 0 else "FAILED", failed, _checks.size()])
	get_tree().quit(1 if failed > 0 else 0)


func _run() -> void:
	await get_tree().process_frame   # the root is still adding its children during _ready
	_check_installed()
	if not Assets.has_pack(_pack):
		return
	await _check_library()
	await _check_shape_viewer()
	_check_map_entries()
	_check_game_modes()
	await _check_campaign()
	await _check_arena()
	await _check_tribes()
	await _check_hangar()
	_check_lookalikes()
	_check_music()
	await _check_extraction_menu()


# ------------------------------------------------------------------ 1 library

func _check_installed() -> void:
	var installed := Array(Assets.installed_packs())
	_record("data folder holds only this game", installed == [_pack], "data root %s: %s" % [Assets.data_root, installed])
	_record("Packs lists only this game", Packs.packs.keys() == [_pack], str(Packs.packs.keys()))


func _check_library() -> void:
	var library: Library = load(LIBRARY).instantiate()
	get_tree().root.add_child(library)
	await _frames(SHOT_DELAY_FRAMES)
	var text := _all_text(library)
	var others := Packs.ERA_DEFAULTS.keys().filter(func(p: String) -> bool: return p != _pack and text.contains("(%s)" % p))
	_record("library card of this game only", text.contains("(%s)" % _pack) and others.is_empty(), "other cards: %s" % [others])
	_record("library has a playable Arena / versus", _enabled_button(library, "Arena / versus"), "")
	await _save_shot("library")
	library.go("options", {"home": "home"})
	await _frames(SHOT_DELAY_FRAMES)
	_record("Options opens", library.current_name == "options" and _find_button(library, "Tested game versions") != null, library.current_name)
	await _save_shot("options")
	library.go("versions")
	await _frames(SHOT_DELAY_FRAMES)
	var status := GameReleases.make_status(_pack)
	_record("release identified and tested", status == GameReleases.TESTED, "%s: %s" % [status, GameReleases.make_status_text(_pack)])
	_record("versions page opens", library.current_name == "versions" and _all_text(library).contains(Packs.pack_name(_pack)), "")
	await _save_shot("versions")
	library.queue_free()
	await _frames(2)


func _check_shape_viewer() -> void:
	var viewer: Node = load(VIEWER).instantiate()
	get_tree().root.add_child(viewer)
	await _frames(10)
	var names: Array = viewer.get("names")
	_record("shape viewer opens with shapes", not names.is_empty() and viewer.get("inst") != null, "%d shapes" % names.size())
	viewer.queue_free()
	await _frames(2)


## Every battlefield the map menus offer belongs to an installed game.
func _check_map_entries() -> void:
	var entries := MapPicker.make_entries()
	var foreign := entries.filter(func(e: Dictionary) -> bool: return not Assets.has_pack(str(e.index.get("pack", ""))))
	_record("map list offers only installed games", foreign.is_empty() and not entries.is_empty(),
		"%d entries, foreign: %s" % [entries.size(), foreign.map(func(e: Dictionary) -> String: return e.name).slice(0, 5)])


func _check_game_modes() -> void:
	var entry := _first_map_entry()
	var ids := GameModes.make_mode_ids_for_map(entry) if not entry.is_empty() else []
	_record("game modes of its first map", not ids.is_empty(), "%s" % [ids])


# ------------------------------------------------------------------ 2 campaign

func _check_campaign() -> void:
	var choices := MatchFlow.make_new_campaign_choices().filter(
		func(c: Dictionary) -> bool: return bool(c.playable) and not c.get("saga", false))
	var expected := Saga.PROVIDERS.has(_pack)
	_record("campaign offered as expected", (not choices.is_empty()) == expected and choices.all(
		func(c: Dictionary) -> bool: return str(c.pack) == _pack), "%s" % [choices.map(func(c: Dictionary) -> String: return c.text)])
	if choices.is_empty():
		return
	Session.start_new_campaign(choices[0], "Sandbox")
	var herc := Session.mission_herc()
	var vid := str(herc.get("vehicle", _first_vehicle()))
	var battle: Battle = _start_battle(MatchFlow.make_mission_config(vid, herc.get("loadout", [])))
	await _frames(SETTLE_FRAMES)
	_record("first campaign mission builds", battle.mission != null and is_instance_valid(battle.player),
		"%s in %s" % [MatchFlow.make_mission_heading(), vid])
	await _run_game_seconds(CAMPAIGN_SECONDS)
	_record("first campaign mission runs", is_instance_valid(battle) and battle.is_inside_tree(), "")
	await _save_shot("campaign")
	await _end_battle(battle)
	Session.clear_campaign()


# ------------------------------------------------------------------ 3 arena

func _check_arena() -> void:
	var vid := _first_vehicle()
	var entry := _first_map_entry()
	if vid == "" or entry.is_empty():
		_record("arena battle", false, "no vehicle (%s) or map" % vid)
		return
	var config := BattleSetup.make_default_config(vid)
	config.merge({"mode": "vs", "respawn": true, "teams": true, "frag_limit": 50, "ai": [_make_bot(vid)]}, true)
	config.erase("world")
	config.erase("zone")
	config.merge(entry.config, true)
	var battle := _start_battle(config)
	await _frames(SETTLE_FRAMES)
	var bots := battle.vehicles.values().filter(func(h: Node) -> bool: return is_instance_valid(h) and h.get("team") == ENEMY_TEAM)
	_record("arena battle builds with a bot", is_instance_valid(battle.player) and not bots.is_empty(),
		"%s on %s, %d bots" % [vid, entry.name, bots.size()])
	await _check_battle_features(battle, vid)
	await _run_game_seconds(ARENA_SECONDS)
	_record("arena battle runs %d s" % ARENA_SECONDS, is_instance_valid(battle) and is_instance_valid(battle.player), "")
	await _save_shot("battle")
	await _end_battle(battle)


func _check_battle_features(battle: Battle, vid: String) -> void:
	var input := battle.get_node_or_null(CommandMapInput.NODE_NAME) as CommandMapInput
	if input != null:
		input.apply_toggle()
		await _frames(4)
		var opened := CommandMap.find_open(battle) != null
		await _save_shot("command_map")
		input.apply_toggle()
		await _frames(2)
		_record("command map opens", opened, CommandProviders.make_game_pack(battle))
	else:
		_record("command map opens", false, "no CommandMapInput in the battle")
	var choice := CockpitFit.make_choice(Packs.vehicle(vid))
	_record("cockpit chosen", str(choice.get("rule", "")) != "", "%s: %s %s" % [vid, choice.get("rule"), choice.get("reason", "")])
	if not _has_infantry():
		_record("without Tribes the pilot stays aboard", not battle.occupancy.can_leave_vehicle(1), "")


func _make_bot(fallback: String) -> Dictionary:
	var vehicles := Packs.pilotable([_pack])
	var enemy := str(vehicles[1].id) if vehicles.size() > 1 else fallback
	return {"vehicle": enemy, "team": ENEMY_TEAM, "skill": BOT_SKILL, "name": "Sandbox bot"}


# ------------------------------------------------------------------ 4 Tribes

func _check_tribes() -> void:
	if not _pack in TRIBES_PACKS:
		return
	await _check_on_foot()
	await _check_training()


func _check_on_foot() -> void:
	var vid := _first_vehicle()
	var config := BattleSetup.make_default_config(vid)
	config.merge({"mode": "vs", "respawn": true, "ai": [], "start": BattleInfantry.START_ON_FOOT}, true)
	config.erase("world")
	config.erase("zone")
	config.merge(_first_map_entry().config, true)
	var battle := _start_battle(config)
	await _frames(SETTLE_FRAMES)
	var soldier := battle.player as Infantry
	_record("infantry spawns on foot", soldier != null, "player %s" % [battle.player])
	var parked := battle.vehicles.values().filter(func(h: Node) -> bool: return is_instance_valid(h) and not h is Infantry and h.get("team") == 0)
	if soldier != null and not parked.is_empty():
		var herc: Herc = parked[0]
		soldier.global_position = herc.global_position + herc.global_basis.x.normalized() * (BoardingRules.make_hull_radius(herc) + BOARD_GAP) + Vector3.UP * 0.3
		soldier.velocity = Vector3.ZERO
		await _frames(3)
		battle.occupancy.apply_enter_exit(1)
		await _frames(3)
		await _touch_board(battle, soldier, herc)
		_record("soldier boards the vehicle", battle.player == herc, "%s: %s" % [herc.get("vehicle_id"), battle.occupancy.make_local_hint()])
	else:
		_record("soldier boards the vehicle", false, "no parked vehicle")
	await _save_shot("on_foot")
	await _end_battle(battle)


## Tribes boarding is by touch (BoardingRules): walk into the hull, after the remount delay if there is one.
func _touch_board(battle: Battle, soldier: Infantry, herc: Herc) -> void:
	var tries := int(TOUCH_SECONDS * Engine.physics_ticks_per_second)
	while battle.player != herc and tries > 0:
		soldier.global_position = herc.global_position + Vector3(BoardingRules.make_hull_radius(herc) + 0.2, 0.3, 0)
		soldier.velocity = Vector3.ZERO
		await get_tree().physics_frame
		tries -= 1


func _check_training() -> void:
	var listed := TribesMissionRuntime.list_missions(_pack)
	if listed.is_empty():
		_record("training mission loads", false, "no training missions")
		return
	var battle := _start_battle({"mode": "mission", "mission_name": "%s:%s" % [_pack, listed[0].id], "respawn": false,
		"roster": {1: {"name": "Sandbox", "vehicle": "", "team": 0, "loadout": []}}})
	await _frames(SETTLE_FRAMES)
	var rt := battle.mission as TribesMissionRuntime
	await _run_game_seconds(TRAINING_SECONDS)
	var errors := []
	if rt != null:
		rt.flush_errors()
		errors = rt.error_log
	_record("training mission loads", rt != null and battle.player is Infantry and errors.is_empty(),
		"%s; script errors: %s" % [listed[0].id, errors.slice(0, 3)])
	await _save_shot("training")
	await _end_battle(battle)


# ------------------------------------------------------------------ 5 cross-pack features

func _check_hangar() -> void:
	var vid := _first_vehicle()
	if vid == "":
		_record("hangar shows its vehicle", true, "%s has no pilotable vehicle, skipped" % _pack)
		return
	var bay: HangarBay = load(HANGAR).instantiate()
	add_child(bay)
	await _frames(2)
	bay.show_herc(vid, Packs.default_loadout(Packs.vehicle(vid)))
	await _frames(4)
	_record("hangar shows its vehicle", bay.model != null and bay.herc_height > 1.0, "%s %.1f m" % [vid, bay.herc_height])
	bay.queue_free()
	await _frames(2)


## A weapon without a model borrows one only from an installed game.
func _check_lookalikes() -> void:
	var borrowed := []
	var foreign := []
	for v: Dictionary in Packs.pilotable([_pack]):
		var loadout := Packs.default_loadout(v)
		for i in loadout.size():
			var choice: Dictionary = HercModel.mount_plan(v, i, Packs.weapon(str(loadout[i]))).get("lookalike", {})
			var src := str(choice.get("weapon", ""))
			if src == "":
				continue
			borrowed.append(src)
			if not Assets.has_pack(Assets.split_id(src)[0]):
				foreign.append("%s #%d <- %s" % [v.id, i, src])
	_record("weapon look-alikes from installed games only", foreign.is_empty(), "%d borrowed, foreign: %s" % [borrowed.size(), foreign.slice(0, 5)])


func _check_music() -> void:
	MenuMusic.play_for_pack(_pack)
	MenuMusic.play_app_hub()
	_record("music degrades without other games", true, "%d catalog entries" % MusicLibrary.catalog(_pack).size())


func _check_extraction_menu() -> void:
	var launcher: Launcher = load(LAUNCHER).instantiate()
	get_tree().root.add_child(launcher)
	await _frames(SHOT_DELAY_FRAMES)
	var offered := _find_button(launcher, "Extraction raid (solo)") != null
	_record("extraction offered only with a Tribes pack", offered == _has_infantry(), "offered %s" % offered)
	await _save_shot("launcher_menu")
	var lobby: RoutedScreen = launcher.open_lobby("vs")
	await _frames(4)
	var in_host := _option_items(lobby).any(func(t: String) -> bool: return t.begins_with("Extraction"))
	_record("the host lobby offers extraction only with a Tribes pack", in_host == _has_infantry(), "offered %s" % in_host)
	Net.leave()
	var modes := GameModes.make_mode_ids_for_map(_first_map_entry())
	_record("map modes offer extraction only with a Tribes pack", not modes.has(ExtractionRules.MODE) or _has_infantry(),
		"%s" % [modes])
	launcher.queue_free()
	await _frames(2)


# ------------------------------------------------------------------ helpers

func _has_infantry() -> bool:
	return InfantryCatalog.make_default_pack() != ""


func _first_vehicle() -> String:
	var vehicles := Packs.pilotable([_pack])
	return str(vehicles[0].id) if not vehicles.is_empty() else ""


## The first MapPicker entry of this game ({} when it has none); Battledrome: a medium arena.
func _first_map_entry() -> Dictionary:
	if _pack == "bd":
		return {"name": "Battledrome arena", "config": {"arena": BD_ARENA.duplicate(), "respawn": true}, "index": {"pack": "bd"}}
	for e: Dictionary in MapPicker.make_entries():
		if str(e.index.get("pack", "")) == _pack:
			return e
	return {}


func _start_battle(config: Dictionary) -> Battle:
	var battle: Battle = load(BATTLE).instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	return battle


func _end_battle(battle: Battle) -> void:
	Engine.time_scale = 1.0
	if is_instance_valid(battle):
		battle.queue_free()
	await _frames(3)


func _run_game_seconds(seconds: float) -> void:
	Engine.time_scale = TIME_SCALE
	await get_tree().create_timer(seconds, true, true).timeout
	Engine.time_scale = 1.0


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _save_shot(name: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shots.path_join("%s_%s.png" % [_pack, name]))


func _record(name: String, ok: bool, detail: String) -> void:
	_checks.append({"name": name, "ok": ok, "detail": detail})
	print("  %s %s  %s" % ["ok  " if ok else "FAIL", name, detail])


func _write_report() -> void:
	var path := ScreenRouter.arg_value("report")
	if path == "":
		return
	var failed := _checks.filter(func(c: Dictionary) -> bool: return not c.ok)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify({"pack": _pack, "ok": failed.is_empty(), "checks": _checks,
		"data_root": Assets.data_root, "store": UserStore.root()}, " "))


func _find_button(root: Node, text: String) -> Button:
	if root is Button and (root as Button).text == text:
		return root
	for c in root.get_children():
		var b := _find_button(c, text)
		if b != null:
			return b
	return null


## The item texts of every OptionButton under `root`.
func _option_items(root: Node) -> Array:
	var out := []
	if root is OptionButton:
		for i in (root as OptionButton).item_count:
			out.append((root as OptionButton).get_item_text(i))
	for c in root.get_children():
		out.append_array(_option_items(c))
	return out


func _enabled_button(root: Node, text: String) -> bool:
	var b := _find_button(root, text)
	return b != null and not b.disabled


func _all_text(root: Node) -> String:
	var parts := []
	if root is Label:
		parts.append((root as Label).text)
	elif root is Button:
		parts.append((root as Button).text)
	for c in root.get_children():
		parts.append(_all_text(c))
	return "\n".join(parts)
