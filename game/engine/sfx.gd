extends Node
## Sound playback. Maps logical sound names to converted WAV files in gamedata/<game>/sounds,
## plays positional one-shots from a small pool, looping attachments, UI clicks and music.
## The saved master / music volumes (AudioSettings) are applied at startup.

## Most positional one-shots playing at once.
const MAX_POSITIONAL_PLAYERS := 24
const ONE_SHOT_UNIT_SIZE := 40.0
const ONE_SHOT_MAX_DISTANCE := 1500.0
const LOOP_UNIT_SIZE := 30.0
## Music fades to this level before it changes or stops.
const MUSIC_FADE_DB := -40.0
## Searched in order; the last entry resolves stems that name their folder ("sim/impacts2", ES2 data).
const SOUND_DIRS := ["audio/sfx/sim", "audio/sfx/shell", "audio/voice", "audio/sfx"]
## Voice lines that can overlap (Battledrome's SoundManager plays every sound in one of 20 slots, 0x2828c).
const VOICE_PLAYERS := 4
## Every sound but a ducking voice plays on this bus (sent to Master).
const DUCKED_BUS := "Ducked"
const MASTER_BUS := "Master"
## Battledrome 0x2821c: while a message voice plays, every other sound (music included) is at half volume.
const DUCK_DB := -6.0206

## logical name -> file stem (unknown names are silently ignored).
## Weapon sounds are provisional until WEAPONS.DAT sound ids are wired in.
var aliases := {
	"LAS100": "laser1h", "LAS200": "laser1h", "LAS300": "laser3h", "PBEAM": "lazer",
	"ATC20": "autocan3", "ATC35": "autocan3", "ATC50": "gun1a3", "MISSL": "missle1",
	"ELF": "lazer", "EMP": "lazer", "GREN": "missle2",
	"explosion": "explo2", "big_explosion": "shipexpl", "hit_laser": "lsrhit2", "hit_bullet": "ricup",
	"footstep": "footf2", "engine": "herceng1", "target_select": "trgslct", "target_lock": "trglock", "target_unlock": "trgunloc",
	"warning": "wrnwoop1", "button": "button",
}
## Emitted when a non-looping music stream reaches its end (key = track key or file path).
signal music_finished(key: String)
## Emitted when a voice line starts (play_voice; name as asked for).
signal voice_started(name: String)

var music_player: AudioStreamPlayer
var ui_player: AudioStreamPlayer
## Non-positional voice lines (announcer, cockpit warnings); owned by this autoload so a line outlives the scene.
var _voice_players: Array[AudioStreamPlayer] = []
var _ducking := {}                   # voice player -> true while its ducking line plays
## Music level (dB) for the current settings (AudioSettings.apply_saved sets it).
var music_volume_db := -6.0
var _cache := {}
var _pool: Array[AudioStreamPlayer3D] = []
var _music_name := ""
var _music_track := {}               # {name, pack} of the playing named track
var _music_tween: Tween


func _ready() -> void:
	_make_ducked_bus()
	music_player = AudioStreamPlayer.new()
	music_player.bus = DUCKED_BUS
	add_child(music_player)
	music_player.finished.connect(_on_music_finished)
	ui_player = AudioStreamPlayer.new()
	ui_player.bus = DUCKED_BUS
	add_child(ui_player)
	for i in VOICE_PLAYERS:
		var v := AudioStreamPlayer.new()
		v.bus = DUCKED_BUS
		v.finished.connect(_end_duck.bind(v))
		add_child(v)
		_voice_players.append(v)
	AudioSettings.apply_saved()


## `name`: a logical name, a file stem of the default pack, or "pack:stem" (another pack's sound).
func stream(name: String) -> AudioStream:
	var stem: String = aliases.get(name, name)
	if _cache.has(stem):
		return _cache[stem]
	var pack := stem.get_slice(":", 0) if stem.contains(":") else ""
	var file := stem.get_slice(":", 1) if stem.contains(":") else stem
	var s: AudioStream = null
	for sub in SOUND_DIRS:
		var p := Assets.path("%s/%s.wav" % [sub, file], pack)
		if FileAccess.file_exists(p):
			s = AudioStreamWAV.load_from_file(p)
			break
	_cache[stem] = s
	return s


## Looping positional sound attached to a node (engine hum etc.).
func attach_loop(name: String, node: Node3D, volume_db := -8.0) -> AudioStreamPlayer3D:
	var s := stream(name)
	if s == null:
		return null
	var w := s as AudioStreamWAV
	if w:
		w = w.duplicate()
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = int(w.get_length() * w.mix_rate)
		s = w
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.bus = DUCKED_BUS
	p.volume_db = volume_db
	p.unit_size = LOOP_UNIT_SIZE
	node.add_child(p)
	p.play()
	return p


func play_at(name: String, pos: Vector3, volume_db := 0.0) -> void:
	play_at_range(name, pos, volume_db, Vector2(ONE_SHOT_UNIT_SIZE, ONE_SHOT_MAX_DISTANCE))


## A positional one-shot heard as the original's 3D sound profile: full volume within `distances.x` metres (its
## minDistance), falling off with distance beyond it (inverse distance, as OpenAL / Miles), silent beyond
## `distances.y` (maxDistance).
func play_at_range(name: String, pos: Vector3, volume_db: float, distances: Vector2) -> void:
	var s := stream(name)
	if s == null:
		return
	var p := _free_positional_player()
	if p == null:
		return
	p.stream = s
	p.volume_db = volume_db
	p.unit_size = distances.x
	p.max_distance = distances.y
	p.global_position = pos
	p.play()


## An idle pooled player, a new one while the pool has room, else null (sound dropped).
## The pool is owned by this autoload, so it survives scene changes (a pool parented under the
## current scene was freed with the first battle and broke every later one).
func _free_positional_player() -> AudioStreamPlayer3D:
	for q in _pool:
		if not q.playing:
			return q
	if _pool.size() >= MAX_POSITIONAL_PLAYERS:
		return null
	var p := AudioStreamPlayer3D.new()
	p.bus = DUCKED_BUS
	p.unit_size = ONE_SHOT_UNIT_SIZE
	p.max_distance = ONE_SHOT_MAX_DISTANCE
	add_child(p)
	_pool.append(p)
	return p


## The pooled positional players (read-only view for tests).
func positional_pool() -> Array[AudioStreamPlayer3D]:
	return _pool.duplicate()


## Plays an audio file by absolute path (jukebox). Loops when `p_loop`.
func play_file(path: String, p_loop := false) -> void:
	var s: AudioStream = null
	match path.get_extension().to_lower():
		"ogg":
			s = AudioStreamOggVorbis.load_from_file(path)
			(s as AudioStreamOggVorbis).loop = p_loop
		"mp3":
			s = AudioStreamMP3.load_from_file(path)
			(s as AudioStreamMP3).loop = p_loop
		"wav":
			s = AudioStreamWAV.load_from_file(path)
	if s == null:
		return
	if _music_tween:
		_music_tween.kill()
	_music_name = path
	music_player.stream = s
	music_player.volume_db = music_volume_db
	music_player.play()


## Music by track name (MusicLibrary: the chosen device's render, loop points from music.json).
## Fades the playing music out over `fade` / 2, then starts the new track -- faded in over the other half,
## or at full volume when `fade_in` is false (Earthsiege's battle switch).  `pack` "" = the current pack.
func play_music(name: String, fade := 1.5, pack := "", fade_in := true) -> void:
	var key := "%s:%s" % [pack, name]
	if key == _music_name:
		return
	var s := MusicLibrary.make_stream(name, pack)
	if s == null:
		return
	_music_track = {"name": name, "pack": pack}
	_switch_music(key, s, fade, fade_in)


## Music from an audio file (CD-track rips, streamed game music).  `p_loop` false = plays once, then
## music_finished is emitted (CD playlists advance on it).
func play_music_file(path: String, p_loop: bool, fade := 1.5, fade_in := true) -> void:
	if path == _music_name or path == "":
		return
	var s := MusicLibrary.make_file_stream(path, p_loop)
	if s == null:
		return
	_music_track = {}
	_switch_music(path, s, fade, fade_in)


## Restarts the playing named track from the same position with the current music device.
func reload_music() -> void:
	if _music_track.is_empty() or not music_player.playing:
		return
	var s := MusicLibrary.make_stream(_music_track.name, _music_track.pack)
	if s == null:
		return
	var at := music_player.get_playback_position()
	music_player.stream = s
	music_player.play(at)


## Key of the music asked for last ("<pack>:<track>" or a file path; "" = none).
func music_key() -> String:
	return _music_name


func stop_music(fade := 1.0) -> void:
	_music_name = ""
	_music_track = {}
	if _music_tween:
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(music_player, "volume_db", MUSIC_FADE_DB, fade)
	_music_tween.tween_callback(music_player.stop)


func _switch_music(key: String, s: AudioStream, fade: float, fade_in: bool) -> void:
	_music_name = key
	if _music_tween:
		_music_tween.kill()
	_music_tween = create_tween()
	if music_player.playing and fade > 0.0:
		_music_tween.tween_property(music_player, "volume_db", MUSIC_FADE_DB, fade * 0.5)
	_music_tween.tween_callback(func():
		music_player.stream = s
		music_player.volume_db = MUSIC_FADE_DB if fade_in and fade > 0.0 else music_volume_db
		music_player.play())
	if fade_in and fade > 0.0:
		_music_tween.tween_property(music_player, "volume_db", music_volume_db, fade * 0.5)


func _on_music_finished() -> void:
	var key := _music_name
	_music_name = ""   # the same track may be asked for again (a playlist of one)
	music_finished.emit(key)


func play_ui(name: String) -> void:
	var s := stream(name)
	if s:
		ui_player.stream = s
		ui_player.play()


## A voice line heard at the listener (not positional): `name` as for stream(). Lines may overlap.
## A `duck` line (Battledrome's cockpit messages) halves every other sound while it plays.
func play_voice(name: String, duck := false) -> void:
	var s := stream(name)
	if s == null:
		return
	var p := _free_voice_player()
	_end_duck(p)
	p.stream = s
	p.bus = MASTER_BUS if duck else DUCKED_BUS
	if duck:
		_ducking[p] = true
		_apply_duck()
	p.play()
	voice_started.emit(name)


## True while a ducking voice line plays.
func is_ducked() -> bool:
	return not _ducking.is_empty()


func _end_duck(p: AudioStreamPlayer) -> void:
	if _ducking.erase(p):
		_apply_duck()


func _apply_duck() -> void:
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(DUCKED_BUS), DUCK_DB if is_ducked() else 0.0)


func _make_ducked_bus() -> void:
	if AudioServer.get_bus_index(DUCKED_BUS) >= 0:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, DUCKED_BUS)
	AudioServer.set_bus_send(i, MASTER_BUS)


## An idle voice player, else the first one (its line is cut).
func _free_voice_player() -> AudioStreamPlayer:
	for v in _voice_players:
		if not v.playing:
			return v
	return _voice_players[0]


## play_voice after `seconds` (timed by the scene tree, so it survives scene changes).
func play_voice_after(name: String, seconds: float) -> void:
	if seconds <= 0.0:
		play_voice(name)
		return
	get_tree().create_timer(seconds).timeout.connect(play_voice.bind(name))
