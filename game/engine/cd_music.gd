class_name CdMusic
extends RefCounted
## CD-audio music of Earthsiege 2, Starsiege and Tribes (from the user's ripped tracks) and the
## situation choices of every non-FM game, as their scripts / executables make them
## (tools/music_situations.py documents the evidence).  A playlist plays each track once and advances
## (Starsiege's cdAudioCycle); a single track loops unless the mission says otherwise.

const STARSIEGE := "starsiege"
const TRIBES := "tribes"
const TRIBES2 := "tribes2"
const ES2 := "es2"
const HARD_CUT := 0.0
const MENU_FADE := 1.0
const SHELL_CHOICE_KEY := "%s_shell_music"   # settings key per pack: the next shell song (prefs byte 5)

var _pack := ""
var _tracks: Array = []              # CD track numbers of a playlist
var _index := 0

static var _es2_launches := 0        # ES.EXE passes -R<n> = sim launches this session


## Plays one CD track of `pack`; false when the user has no rip of it.
static func play_track(pack: String, track: int, loop: bool, fade := HARD_CUT) -> bool:
	var path := Soundtracks.cd_track_file(pack, track)
	if path == "":
		return false
	Sfx.play_music_file(path, loop, fade, fade <= HARD_CUT)
	return true


## Starsiege mission music: the mission's cdAudioCycle list (tracks outside the disc's 2..13 are skipped,
## as CDAudio::cycle does), each track once, then the next, forever.
func play_starsiege(mission_id: String) -> bool:
	var s := MusicLibrary.situations(STARSIEGE)
	var valid: Array = s.get("valid_tracks", [2, 13])
	var raw: Array = s.get("missions", {}).get(mission_id.to_upper(), [])
	var tracks := raw.filter(func(t) -> bool: return int(t) >= int(valid[0]) and int(t) <= int(valid[1]))
	return start_playlist(STARSIEGE, tracks)


## Tribes mission music: $cdTrack, looped when $cdPlayMode is 1, else once (hard cut).
static func play_tribes(mission_id: String) -> bool:
	var m: Dictionary = MusicLibrary.situations(TRIBES).get("missions", {}).get(mission_id, {})
	if m.is_empty():
		return false
	return play_track(TRIBES, int(m.track), bool(m.get("loop", true)))


## Tribes 2 mission music: base/music/<musicTrack>.mp3, looped, hard cut.
static func play_tribes2(mission_id: String) -> bool:
	var name := String(MusicLibrary.situations(TRIBES2).get("missions", {}).get(mission_id, ""))
	if name == "":
		return false
	Sfx.play_music(name, HARD_CUT, TRIBES2, false)
	return true


## Earthsiege 2 sim music: CD track 2, 3, 4, 5, 6, 2 ... by sim launch, looped; training is silent.
static func play_es2(training: bool) -> bool:
	if training:
		return false
	var tracks: Array = MusicLibrary.situations(ES2).get("sim_tracks", [])
	if tracks.is_empty():
		return false
	var track := int(tracks[_es2_launches % tracks.size()])
	_es2_launches += 1
	return play_track(ES2, track, true)


## The shell / main-menu music of a non-FM game (Starsiege SHELL1.WAV, ES2 SHELL2.WAV / SHELL1.WAV, Tribes CD
## track 2); false when the game has none (Tribes 2's shell is silent) or it is not on disk.
static func play_menu(pack: String) -> bool:
	var s := MusicLibrary.situations(pack)
	if s.get("shell") is Dictionary:
		var alternates: Array = s.get("shell_alternates", [String(s.shell.file)])
		if _is_playing_one_of(pack, alternates):
			return true
		var file := String(alternates[shell_choice(pack, alternates.size())])
		if MusicLibrary.track_path(file, pack) == "":
			return false
		apply_shell_start(pack, alternates.size())
		Sfx.play_music(file, MENU_FADE, pack)
		return true
	if s.get("menu") is Dictionary:
		return play_track(pack, int(s.menu.track), bool(s.menu.get("loop", true)))
	return false


## Earthsiege 2 picks its shell song by prefs byte 5 (0 = SHELL2, the default) and every shell start toggles
## and saves it (VSHELL 0x42ed97, 0x42ee1b), so the two alternate per shell start; kept in the settings.
static func shell_choice(pack: String, count: int) -> int:
	return int(Assets.settings.get(SHELL_CHOICE_KEY % pack, 0)) % maxi(count, 1)


## A shell start: the saved song plays, and the saved choice moves on to the next one (a single song stays).
static func apply_shell_start(pack: String, count: int) -> void:
	if count < 2:
		return
	var now := shell_choice(pack, count)
	Assets.settings[SHELL_CHOICE_KEY % pack] = (now + 1) % maxi(count, 1)
	Assets.save_settings()


static func _is_playing_one_of(pack: String, names: Array) -> bool:
	return names.any(func(n) -> bool: return Sfx.music_key() == "%s:%s" % [pack, n])


func start_playlist(pack: String, tracks: Array) -> bool:
	stop_playlist()
	_pack = pack
	_tracks = tracks
	_index = 0
	if _tracks.is_empty():
		return false
	Sfx.music_finished.connect(_on_track_finished)
	_play_current()
	return true


func stop_playlist() -> void:
	if Sfx.music_finished.is_connected(_on_track_finished):
		Sfx.music_finished.disconnect(_on_track_finished)
	_tracks = []


func _play_current() -> void:
	play_track(_pack, int(_tracks[_index]), false)


func _on_track_finished(_key: String) -> void:
	_index = (_index + 1) % _tracks.size()
	_play_current()
