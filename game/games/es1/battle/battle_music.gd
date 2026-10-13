class_name BattleMusic
extends RefCounted
## In-battle music, chosen like the game the battle comes from:
##   * Earthsiege (DBSIM 0x585dc): a random theme 1-3, calm "A" variant.  The scan runs every frame, except
##     for 300 sim-clock units (5 s) after the mission start and after every switch (0x96d10).  Calm -> combat
##     "B" when an enemy is targeted / in view or closer than 25000 units; combat -> calm once no enemy is
##     engaged and every Herc still alive, either side, is within 18928 units of the player (0x5888f: one
##     farther away keeps the combat theme).  A switch fades the song out (-15 volume per frame) and starts
##     the other variant at full volume from its beginning.
##   * Battledrome arenas (SIM.EXE 0x28486): a random track of the music set chosen in Options (the
##     original's Preferences MUSIC TYPE; "none" is silent), never the one just played, each played once.
##   * Earthsiege 2, Starsiege, Tribes, Tribes 2: CdMusic (mission tracks from the scripts / executable).

const THEME_COUNT := 3
## 0x585dc: no scan for 300 sim-clock units after the start and each switch.  The clock (0x981c4) counts every
## second tick of the 120 Hz timer callback 0x63e3c (PIT divisor 0x26d3, 0x5a9f7), i.e. 60 per second.
const SIM_CLOCK_HZ := 60.0
const HOLD_CLOCK_UNITS := 300.0
const HOLD_SECONDS := HOLD_CLOCK_UNITS / SIM_CLOCK_HZ
## 0x5880b: an enemy closer than 25000 units engages (units: Earthsiege 1/256 m world scale).
const ENGAGE_UNITS := 25000.0
## 0x588ef: back to calm only while every live Herc is at most 18928 units away.
const CALM_UNITS := 18928.0
const ES1_METRES_PER_UNIT := 1.0 / 256.0
## The original fades the old song by 15 of 100 volume per frame (~7 frames); half of this is the fade out.
const SWITCH_FADE := 0.6
const MENU_FADE_OUT := 1.0
const ARENA_PACK := "bd"
const ES1_PACK := "es1"

var _mode := ""
var _theme := 0
var _engaged := false
var _hold_t := 0.0
var _arena_tracks: Array = []
var _last_arena_track := ""
var _cd := CdMusic.new()


## Starts the music for a battle (config / mission definition as BattleSetup resolved them).
## The menu music fades out first (Earthsiege 2's shell fades at sim start); a battle without music is silent.
func start(config := {}, mdef := {}) -> void:
	Sfx.stop_music(MENU_FADE_OUT)
	var map_pack := String(config.get("map", "")).get_slice(":", 0)
	var map_id := String(config.get("map", "")).get_slice(":", 1)
	if config.has("arena") and not config.has("map"):
		_start_arena()
	elif mdef.get("pack") == CdMusic.ES2:
		_mode = CdMusic.ES2
		CdMusic.play_es2(String(config.get("mission_name", "")).to_upper().contains("TRAIN"))
	elif StarsiegeMissionRuntime.is_starsiege(mdef) or map_pack == CdMusic.STARSIEGE:
		_mode = CdMusic.STARSIEGE
		_cd.play_starsiege(map_id if map_id != "" else String(mdef.get("name", "")))
	elif map_pack == CdMusic.TRIBES:
		_mode = CdMusic.TRIBES
		CdMusic.play_tribes(map_id)
	elif map_pack == CdMusic.TRIBES2:
		_mode = CdMusic.TRIBES2
		CdMusic.play_tribes2(map_id)
	else:
		_start_earthsiege()


func stop() -> void:
	_cd.stop_playlist()
	if Sfx.music_finished.is_connected(_on_arena_track_finished):
		Sfx.music_finished.disconnect(_on_arena_track_finished)


func update(player: Herc, delta: float) -> void:
	if _mode != ES1_PACK or player == null or not is_instance_valid(player):
		return
	_hold_t -= delta
	if _hold_t > 0.0:
		return
	var engaged := make_engaged_state(player, _engaged)
	if engaged != _engaged:
		_engaged = engaged
		_hold_t = HOLD_SECONDS
		Sfx.play_music(_theme_track(), SWITCH_FADE, ES1_PACK, false)


## The theme the scan of 0x585dc picks: combat while an enemy is engaged; from combat, calm only when
## every live Herc is close (is_all_close), else combat stays.
static func make_engaged_state(player: Herc, engaged_now: bool) -> bool:
	if is_engaged(player):
		return true
	return engaged_now and not is_all_close(player)


## An enemy targets the player or is within ENGAGE_UNITS.
static func is_engaged(player: Herc) -> bool:
	var reach := ENGAGE_UNITS * ES1_METRES_PER_UNIT
	for v in player.get_tree().get_nodes_in_group("vehicles"):
		if v.team == player.team or not v.alive:
			continue
		if v.get("target") == player or v.global_position.distance_to(player.global_position) < reach:
			return true
	return false


## Every live vehicle (either side, the player's wingmen included) is within CALM_UNITS of the player.
static func is_all_close(player: Herc) -> bool:
	var reach := CALM_UNITS * ES1_METRES_PER_UNIT
	for v in player.get_tree().get_nodes_in_group("vehicles"):
		if v.alive and v.global_position.distance_to(player.global_position) > reach:
			return false
	return true


func _start_earthsiege() -> void:
	_mode = ES1_PACK
	_theme = randi() % THEME_COUNT
	_engaged = false
	_hold_t = HOLD_SECONDS
	Sfx.play_music(_theme_track(), SWITCH_FADE, ES1_PACK)


func _theme_track() -> String:
	var themes: Array = MusicLibrary.situations(ES1_PACK).get("battle_themes", [])
	if _theme < themes.size():
		return String(themes[_theme][1 if _engaged else 0])
	return "battle%d%s" % [_theme + 1, "b" if _engaged else "a"]


func _start_arena() -> void:
	_mode = ARENA_PACK
	var music_set := MusicLibrary.arena_set()
	if music_set == MusicLibrary.NO_ARENA_MUSIC:
		return
	_arena_tracks = MusicLibrary.situations(ARENA_PACK).get("arena_sets", {}).get(music_set, [])
	if _arena_tracks.is_empty():
		_start_earthsiege()
		return
	Sfx.music_finished.connect(_on_arena_track_finished)
	_play_next_arena_track()


func _play_next_arena_track() -> void:
	var choices := _arena_tracks.filter(func(t) -> bool: return t != _last_arena_track)
	_last_arena_track = String(choices[randi() % choices.size()]) if not choices.is_empty() else _last_arena_track
	Sfx.play_music(_last_arena_track, CdMusic.HARD_CUT, ARENA_PACK, false)


func _on_arena_track_finished(_key: String) -> void:
	_play_next_arena_track()
