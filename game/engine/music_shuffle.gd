class_name MusicShuffle
extends RefCounted
## Music for anything the originals never scored: modes, campaigns and maps the remake added (Varuna's Fall, the
## Aerial Assault and Vengeance packs, a game whose own music isn't installed). It plays the available music
## (Soundtracks: CD rips, soundtrack folders, each pack's rendered tracks) one random track after another, never
## the same track twice in a row. Tracks of the preferred pack come first when it has any.

## Jingles and stingers are skipped; 0 means the length is unknown, which is kept.
const MIN_SECONDS := 30.0
const FADE := 1.5

var _pool: Array = []
var _last := ""


## Starts shuffling; false when there is no music at all (the battle stays silent).
func start(prefer_pack := "") -> bool:
	_pool = make_pool(Soundtracks.all(), prefer_pack)
	if _pool.is_empty():
		return false
	if not Sfx.music_finished.is_connected(_on_finished):
		Sfx.music_finished.connect(_on_finished)
	_play_next()
	return true


func stop() -> void:
	if Sfx.music_finished.is_connected(_on_finished):
		Sfx.music_finished.disconnect(_on_finished)


## The playable track files: the preferred pack's if it has any, else every pack's.
static func make_pool(soundtracks: Dictionary, prefer_pack := "") -> Array:
	var own := _make_files(soundtracks.get(prefer_pack, {}))
	if not own.is_empty():
		return own
	var all: Array = []
	for pack in soundtracks:
		all.append_array(_make_files(soundtracks[pack]))
	return all


static func _make_files(entry: Dictionary) -> Array:
	var files: Array = []
	for t in entry.get("tracks", []):
		var seconds := float(t.get("seconds", 0.0))
		if seconds == 0.0 or seconds >= MIN_SECONDS:
			files.append(String(t.file))
	return files


## A random track from the pool other than `last` (the only track when there is just one).
static func make_next(pool: Array, last: String) -> String:
	var choices := pool.filter(func(f) -> bool: return f != last)
	if choices.is_empty():
		return last
	return String(choices[randi() % choices.size()])


func _play_next() -> void:
	_last = make_next(_pool, _last)
	Sfx.play_music_file(_last, _pool.size() == 1, FADE)   # a lone track loops instead of ending in silence


func _on_finished(_key: String) -> void:
	_play_next()
