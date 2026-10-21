extends Node
## MusicShuffle: music for modes, campaigns and maps the originals never scored, and BattleMusic falling back to it.
##   godot --headless --audio-driver Dummy --path game res://tests/music_shuffle_check.tscn

const WATCHDOG_SECONDS := 60.0
const SOUNDTRACKS := {
	"tribes": {"tracks": [{"file": "t1_a.ogg", "seconds": 180.0}, {"file": "t1_jingle.ogg", "seconds": 4.0}]},
	"starsiege": {"tracks": [{"file": "ss_a.ogg", "seconds": 0.0}, {"file": "ss_b.ogg", "seconds": 240.0}]},
}

var _fails := 0


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	_check_pool()
	_check_next()
	_check_battle_fallback()
	_check_menu_fallback()
	print("music_shuffle_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _check_pool() -> void:
	var own := MusicShuffle.make_pool(SOUNDTRACKS, "starsiege")
	_expect(own == ["ss_a.ogg", "ss_b.ogg"], "the preferred pack's tracks come first (unknown length kept)")
	var all := MusicShuffle.make_pool(SOUNDTRACKS, "tribes_v")
	_expect(all.size() == 3 and all.has("t1_a.ogg") and all.has("ss_b.ogg"), "an unscored pack draws on every pack's music")
	_expect(not all.has("t1_jingle.ogg"), "jingles under %d s are skipped" % int(MusicShuffle.MIN_SECONDS))
	_expect(MusicShuffle.make_pool({}, "").is_empty(), "no music installed: an empty pool")


func _check_next() -> void:
	var pool := ["a", "b", "c"]
	var repeats := 0
	var last := "a"
	for i in 200:
		var next := MusicShuffle.make_next(pool, last)
		if next == last:
			repeats += 1
		last = next
	_expect(repeats == 0, "never the same track twice in a row")
	_expect(MusicShuffle.make_next(["solo"], "solo") == "solo", "a lone track is picked again")


## A map from a pack the originals never scored goes to the shuffle (or stays silent with no music at all);
## it never falls through to Earthsiege's themes without them installed.
func _check_battle_fallback() -> void:
	var music := BattleMusic.new()
	music.start({"map": "tribes_v:Captured"}, {})
	_expect(music.get("_mode") == "", "a Vengeance map uses the shuffle, not a game's own scoring")
	music.stop()
	var has_music := not MusicShuffle.make_pool(Soundtracks.all(), "tribes_v").is_empty()
	print("     installed music for the shuffle: %s" % has_music)
	if has_music:
		music.start({"map": "extraction:varuna"}, {})
		_expect(music.get("_mode") == "" and String(Sfx.get("_music_name")) != "",
			"Varuna's Fall plays shuffled music from the installed games")
		music.stop()
		Sfx.stop_music(0.0)


## The lobby on a map whose game has no menu music (an extraction raid, Tribes 2's silent shell) keeps music
## playing instead of cutting to silence; picking another such map carries on the same track.
func _check_menu_fallback() -> void:
	if MusicShuffle.make_pool(Soundtracks.all(), "").is_empty():
		print("     no music installed: the menu fallback is not exercised")
		return
	Sfx.stop_music(0.0)
	MenuMusic.play_app_hub()
	var hub_track := Sfx.music_key()
	_expect(hub_track != "", "the library hub plays music instead of silence")
	MenuMusic.play_for_pack("extraction")
	_expect(Sfx.music_key() == hub_track, "picking an extraction raid in the lobby keeps the music going")
	MenuMusic.play_for_pack("tribes2")
	_expect(Sfx.music_key() != "", "a game with a silent shell gets music in the lobby")
	Sfx.stop_music(0.0)
