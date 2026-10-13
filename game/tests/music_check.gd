extends Node
## Headless check of game music selection (MusicLibrary, Sfx, BattleMusic, CdMusic, MenuMusic): the music device
## setting picks the Sound Blaster / AdLib render, looping renders wrap to their loop pass, each
## situation asks for the original's track (battles, the Battledrome music set, the Earthsiege calm / combat
## rule, the app's menu music per game, the Earthsiege career endings).  Needs rendered / imported music; packs
## that are missing are skipped.  The user's music settings are restored afterwards.  Run silent:
##   godot --headless --audio-driver Dummy --path game res://tests/music_check.tscn

const SAVED_KEYS := [MusicLibrary.DEVICE_KEY, MusicLibrary.ARENA_SET_KEY, "es2_shell_music"]
const TEST_HERC := "es1:RAPTOR"

var _failures := 0
var _saved_settings := {}


func _ready() -> void:
	for k in SAVED_KEYS:
		if Assets.settings.has(k):
			_saved_settings[k] = Assets.settings[k]
	_check_device_switch()
	_check_loop_points()
	_check_es1_situations()
	_check_battle_es1()
	_check_es1_calm_rule()
	_check_battle_arena()
	_check_arena_music_set()
	_check_cd_games()
	_check_menu_music()
	_check_es1_career_endings()
	_restore_settings()
	Sfx.stop_music(0.0)
	print("music_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _has_music(pack: String) -> bool:
	if MusicLibrary.catalog(pack).is_empty() and MusicLibrary.situations(pack).is_empty():
		print("  skip %s: no music imported" % pack)
		return false
	return true


func _check_device_switch() -> void:
	if not _has_music("es1"):
		return
	MusicLibrary.set_device("adlib")
	_expect(MusicLibrary.track_path("menu", "es1").contains("/adlib/"), "AdLib device -> adlib render")
	MusicLibrary.set_device("sb")
	_expect(MusicLibrary.track_path("menu", "es1").contains("/sb/"), "Sound Blaster device -> sb render")
	Sfx.play_music("menu", 0.0, "es1")
	MusicLibrary.set_device("adlib")
	Sfx.reload_music()
	_expect(Sfx.music_key() == "es1:menu", "switching the device keeps the playing track")
	MusicLibrary.set_device("bogus")
	_expect(MusicLibrary.device() == MusicLibrary.DEFAULT_DEVICE, "unknown device falls back to Sound Blaster")


func _check_loop_points() -> void:
	if not _has_music("es1"):
		return
	var info: Dictionary = MusicLibrary.catalog("es1").tracks.menu
	var s := MusicLibrary.make_stream("menu", "es1") as AudioStreamOggVorbis
	_expect(s != null and s.loop and is_equal_approx(s.loop_offset, float(info.loop_start)),
		"menu loops from its loop pass (%.2f s)" % float(info.loop_start))
	var once := MusicLibrary.make_stream("soundset", "es1") as AudioStreamOggVorbis
	_expect(once != null and not once.loop, "the sound-test song plays once")


func _check_es1_situations() -> void:
	if not _has_music("es1"):
		return
	var s := MusicLibrary.situations("es1")
	_expect(s.region_music["1000"] == "menu", "main menu region plays menu")
	_expect(s.region_music["4000"] == "shellb", "hangar region plays shellb (GO table 0x817d0 id 4)")
	_expect(s.region_music["3000"] == "shella", "war room plays shella")
	_expect(s.general_transmission_by_campaign[0] == "rubble" and s.general_transmission_by_campaign[7] == "volcano",
		"general's transmission plays the campaign's world theme")
	_expect(s.campaign_won == "intro2" and s.campaign_lost == "losing", "campaign endings")


func _check_battle_es1() -> void:
	if not _has_music("es1"):
		return
	var m := BattleMusic.new()
	m.start({}, {})
	var key := Sfx.music_key()
	_expect(key.begins_with("es1:battle") and key.ends_with("a"), "Earthsiege battle starts on a calm A theme (%s)" % key)
	m.stop()


## DBSIM 0x585dc: combat when an enemy is near; back to calm only when every live Herc is close.
func _check_es1_calm_rule() -> void:
	_expect(is_equal_approx(BattleMusic.HOLD_SECONDS, 5.0), "switch hold-off: 300 clock units at 60 Hz = 5 s")
	if Packs.vehicle(TEST_HERC).is_empty():
		print("  skip calm rule: no %s" % TEST_HERC)
		return
	var world := Node3D.new()
	add_child(world)
	var engage_m := BattleMusic.ENGAGE_UNITS * BattleMusic.ES1_METRES_PER_UNIT
	var calm_m := BattleMusic.CALM_UNITS * BattleMusic.ES1_METRES_PER_UNIT
	var player := _spawn_herc(world, 0, Vector3.ZERO)
	var enemy := _spawn_herc(world, 1, Vector3(engage_m * 0.5, 0, 0))
	_expect(BattleMusic.make_engaged_state(player, false), "a near enemy starts the combat theme")
	enemy.global_position = Vector3(engage_m * 2.0, 0, 0)
	_expect(not BattleMusic.make_engaged_state(player, false), "a far enemy leaves the calm theme on")
	_expect(BattleMusic.make_engaged_state(player, true), "a live enemy beyond 18928 units keeps the combat theme")
	enemy.alive = false
	_expect(not BattleMusic.make_engaged_state(player, true), "every enemy down -> calm theme")
	var wingman := _spawn_herc(world, 0, Vector3(0, 0, calm_m * 2.0))
	_expect(BattleMusic.make_engaged_state(player, true), "a far live wingman keeps the combat theme (any side counts)")
	wingman.global_position = Vector3(0, 0, calm_m * 0.5)
	_expect(not BattleMusic.make_engaged_state(player, true), "... until it is within 18928 units")
	world.queue_free()


func _spawn_herc(parent: Node3D, team: int, at: Vector3) -> Herc:
	var h := Herc.new()
	h.vehicle_id = TEST_HERC
	h.team = team
	parent.add_child(h)
	h.global_position = at
	return h


func _check_battle_arena() -> void:
	if not _has_music("bd"):
		return
	var variety: Array = MusicLibrary.situations("bd").arena_sets.variety
	Assets.settings.erase(MusicLibrary.ARENA_SET_KEY)
	var m := BattleMusic.new()
	m.start({"arena": "ARENA1"}, {})
	var first := Sfx.music_key()
	_expect(first.trim_prefix("bd:") in variety, "Battledrome arenas default to the VARIETY set (%s)" % first)
	Sfx.music_finished.emit(first)
	_expect(Sfx.music_key() != first and Sfx.music_key().trim_prefix("bd:") in variety,
		"next arena track differs (%s)" % Sfx.music_key())
	m.stop()


## Options' Battledrome music set (the original's Preferences MUSIC TYPE) picks the arena tracks.
func _check_arena_music_set() -> void:
	if not _has_music("bd"):
		return
	_expect(MusicLibrary.DEFAULT_ARENA_SET == "variety", "the original default music type is VARIETY")
	MusicLibrary.set_arena_set("techno")
	var m := BattleMusic.new()
	m.start({"arena": "ARENA1"}, {})
	_expect(Sfx.music_key() in ["bd:techno1", "bd:techno2", "bd:techno3"], "TECHNO set plays techno (%s)" % Sfx.music_key())
	m.stop()
	MusicLibrary.set_arena_set("none")
	m = BattleMusic.new()
	m.start({"arena": "ARENA1"}, {})
	_expect(Sfx.music_key() == "", "music type NONE is silent")
	m.stop()
	MusicLibrary.set_arena_set("bogus")
	_expect(MusicLibrary.arena_set() == MusicLibrary.DEFAULT_ARENA_SET, "unknown set falls back to VARIETY")


func _check_cd_games() -> void:
	if _has_music("tribes"):
		var t := BattleMusic.new()
		t.start({"map": "tribes:Raindance"}, {})
		var want := Soundtracks.cd_track_file("tribes", 4)
		_expect(want == "" or Sfx.music_key() == want, "Tribes Raindance plays CD track 4")
		t.stop()
	if _has_music("tribes2"):
		var t2 := BattleMusic.new()
		t2.start({"map": "tribes2:Abominable"}, {})
		_expect(Sfx.music_key() == "tribes2:ice", "Tribes 2 Abominable plays ice.mp3 (%s)" % Sfx.music_key())
		t2.stop()
	if _has_music("starsiege"):
		var cd := CdMusic.new()
		var want8 := Soundtracks.cd_track_file("starsiege", 8)
		cd.play_starsiege("HA0")
		_expect(want8 == "" or Sfx.music_key() == want8, "Starsiege HA0 cycle starts on CD track 8")
		Sfx.music_finished.emit(Sfx.music_key())
		var want13 := Soundtracks.cd_track_file("starsiege", 13)
		_expect(want13 == "" or Sfx.music_key() == want13, "... then track 13")
		cd.stop_playlist()
		var tracks: Array = MusicLibrary.situations("starsiege").missions.get("HA4", [])
		_expect(tracks.map(func(x): return int(x)).has(14), "HA4 lists SS1 as track 14 (the script's number)")
	if _has_music("es2"):
		var a := Soundtracks.cd_track_file("es2", 2)
		CdMusic.play_es2(false)
		var first := Sfx.music_key()
		CdMusic.play_es2(false)
		_expect(a == "" or (first != Sfx.music_key()), "Earthsiege 2 rotates its CD track per sim launch")
		_expect(not CdMusic.play_es2(true), "Earthsiege 2 training is silent")


## The app's screens play the menu music of the game the player is in; the hubs are silent.
func _check_menu_music() -> void:
	if _has_music("es2"):
		_check_es2_shell_alternation()
	if _has_music("starsiege"):
		MenuMusic.play_for_pack(MenuMusic.STARSIEGE)
		_expect(Sfx.music_key() == "starsiege:shell1", "Starsiege menu: SHELL1")
	if _has_music("tribes"):
		var menu_track := Soundtracks.cd_track_file("tribes", 2)
		MenuMusic.play_for_pack("tribes")
		_expect(menu_track == "" or Sfx.music_key() == menu_track, "Tribes menu: CD track 2")
	if _has_music("tribes2"):
		MenuMusic.play_for_pack("tribes2")
		_expect(Sfx.music_key() == "", "Tribes 2 menu is silent, as its shell was")
	if _has_music("es1"):
		Session.start_stage_campaign("es1")
		MenuMusic.play_for_campaign("briefing")
		_expect(Sfx.music_key() == "es1:shella", "Earthsiege campaign briefing: the briefing-map region song")
		MenuMusic.play_campaign_end("es1", true)
		_expect(Sfx.music_key() == "es1:intro2", "Earthsiege campaign won: intro2")
		MenuMusic.play_campaign_end("es1", false)
		_expect(Sfx.music_key() == "es1:losing", "Earthsiege campaign lost: losing")
		Session.clear_campaign()
	MenuMusic.play_app_hub()
	_expect(Sfx.music_key() == "", "library home / launcher menu are silent")
	_expect(MenuMusic.make_pack_of_map_config({"map": "tribes:Raindance"}) == "tribes"
		and MenuMusic.make_pack_of_map_config({"arena": "ARENA1"}) == "bd", "a lobby map names its game")


## VSHELL plays SHELL2 while prefs byte 5 is 0 (the default) and toggles it at every shell start.
func _check_es2_shell_alternation() -> void:
	Assets.settings.erase("es2_shell_music")
	Sfx.stop_music(0.0)
	MenuMusic.play_for_pack("es2")
	_expect(Sfx.music_key() == "es2:shell2", "Earthsiege 2 menu: SHELL2 by default (%s)" % Sfx.music_key())
	MenuMusic.play_for_pack("es2", "debrief")
	_expect(Sfx.music_key() == "es2:shell2", "... keeps playing between its screens")
	Sfx.stop_music(0.0)
	MenuMusic.play_for_pack("es2")
	_expect(Sfx.music_key() == "es2:shell1", "the next shell start plays SHELL1 (prefs byte 5 toggles)")
	Sfx.stop_music(0.0)
	MenuMusic.play_for_pack("es2")
	_expect(Sfx.music_key() == "es2:shell2", "... then SHELL2 again")


## GO.EXE 0x3ba93: a career ends by the campaign's end (won / lost), each with its song and scenes; a killed
## pilot plays death + ENDFA but no longer ends the career (the mission is replayed from its restore point).
func _check_es1_career_endings() -> void:
	if not _has_music("es1"):
		return
	var s := MusicLibrary.situations("es1")
	_expect(ShellMissions.make_career_ending({"over": true, "victory": true}) == "campaign_won", "campaign won")
	_expect(ShellMissions.make_career_ending({"over": true}) == "campaign_lost", "campaign lost")
	_expect(ShellMissions.make_career_ending({}) == "", "a career that is not over goes on (a killed pilot replays)")
	_expect(s.get("pilot_killed") == "death", "pilot killed plays death")
	Sfx.stop_music(0.0)
	MenuMusic.play_pilot_killed("es1")
	_expect(Sfx.music_key() == "es1:death", "the app's killed-in-action prompt plays Earthsiege's death song (%s)" % Sfx.music_key())
	for ending in ShellSequences.CAREER_ENDINGS:
		_expect(MusicLibrary.track_path(String(s.get(ending, "")), "es1") != "", "%s song is rendered" % ending)
		for scene in ShellSequences.CAREER_ENDINGS[ending]:
			_expect(not ShellData.ttm(scene).is_empty(), "%s scene %s exists" % [ending, scene])


func _restore_settings() -> void:
	for k in SAVED_KEYS:
		if _saved_settings.has(k):
			Assets.settings[k] = _saved_settings[k]
		else:
			Assets.settings.erase(k)
	Assets.save_settings()
