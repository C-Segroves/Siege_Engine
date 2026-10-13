class_name MusicLibrary
extends RefCounted
## Game music on disk and when it plays.
##   * Earthsiege / Battledrome: FM renders in <pack>/audio/music/<device>/<track>.ogg with music.json
##     (tools/render_music.py): loop points, and "situations" (which track plays where, decoded from the exe).
##   * Starsiege / Tribes / Tribes 2 / Earthsiege 2: <pack>/audio/music_situations.json
##     (tools/music_situations.py); CD tracks come from the user's rips (Soundtracks.cd_track_file), streamed
##     music from <pack>/audio/music/.
## The music device (Options) picks the render: Sound Blaster (FM + digital drums) or AdLib (FM only).
## Both games drove the FM chip through HMI's OPL2 driver even on OPL3 cards (docs/formats/audio_video.md §3).

const DEVICE_KEY := "music_device"
const DEVICES := ["sb", "adlib"]
const DEVICE_LABELS := {"sb": "Sound Blaster (FM + digital drums)", "adlib": "AdLib (FM only)"}
const DEFAULT_DEVICE := "sb"
## Battledrome Preferences MUSIC TYPE (SIM.EXE strings 0x7dcad, sets 0x78af4; "none" = 4 switches the music
## off, 0x5e5).  The original default is VARIETY: SoundManager's constructor sets 3 (0x27deb), and the shipped
## STORAGE.DAT reads sound 1, voices 1, volume 100, music type 3 at file offsets 9-18 (sim +0xe54..0xe5a) [M].
const ARENA_SET_KEY := "bd_music_type"
const ARENA_SETS := ["rock", "techno", "soundtrack", "variety", "none"]
const ARENA_SET_LABELS := {"rock": "Rock 'n roll", "techno": "Techno", "soundtrack": "Soundtrack",
	"variety": "Variety", "none": "None"}
const DEFAULT_ARENA_SET := "variety"
const NO_ARENA_MUSIC := "none"
const CATALOG_FILE := "audio/music/music.json"
const SITUATIONS_FILE := "audio/music_situations.json"
const MUSIC_DIR := "audio/music"
const STREAM_EXTENSIONS := ["ogg", "mp3"]

static var _json_cache := {}


## The chosen music device ("sb" or "adlib").
static func device() -> String:
	var d := String(Assets.settings.get(DEVICE_KEY, DEFAULT_DEVICE))
	return d if d in DEVICES else DEFAULT_DEVICE


static func set_device(id: String) -> void:
	Assets.settings[DEVICE_KEY] = id if id in DEVICES else DEFAULT_DEVICE
	Assets.save_settings()


## The Battledrome arena music set (ARENA_SETS).
static func arena_set() -> String:
	var s := String(Assets.settings.get(ARENA_SET_KEY, DEFAULT_ARENA_SET))
	return s if s in ARENA_SETS else DEFAULT_ARENA_SET


static func set_arena_set(id: String) -> void:
	Assets.settings[ARENA_SET_KEY] = id if id in ARENA_SETS else DEFAULT_ARENA_SET
	Assets.save_settings()


## music.json of a pack ({} when the pack has no rendered music).
static func catalog(pack := "") -> Dictionary:
	return _load_json(Assets.path(CATALOG_FILE, pack))


## Situation table: music.json "situations" (FM games) or music_situations.json (CD / streamed games).
static func situations(pack := "") -> Dictionary:
	var s: Dictionary = catalog(pack).get("situations", {})
	return s if not s.is_empty() else _load_json(Assets.path(SITUATIONS_FILE, pack))


## Absolute path of a track for the current device ("" if none): the device's render, the other
## device's, then a plain <pack>/audio/music/<name>.ogg|mp3 (streamed music, older renders).
static func track_path(name: String, pack := "") -> String:
	var files: Dictionary = catalog(pack).get("tracks", {}).get(name, {}).get("files", {})
	var order := [device()] + DEVICES.filter(func(d: String) -> bool: return d != device())
	for d in order:
		if files.has(d):
			var p := Assets.path("%s/%s" % [MUSIC_DIR, files[d]], pack)
			if FileAccess.file_exists(p):
				return p
	for ext in STREAM_EXTENSIONS:
		var p := Assets.path("%s/%s.%s" % [MUSIC_DIR, name, ext], pack)
		if FileAccess.file_exists(p):
			return p
	return ""


## Whether a track loops (true for streamed music and unknown tracks).
static func loops(name: String, pack := "") -> bool:
	return bool(catalog(pack).get("tracks", {}).get(name, {}).get("loop", true))


## A ready-to-play stream for a named track (null if it is not on disk). Looping renders wrap to their
## loop pass (loop_start) instead of the file start, as the original's loop controllers do.
static func make_stream(name: String, pack := "") -> AudioStream:
	var path := track_path(name, pack)
	if path == "":
		return null
	var info: Dictionary = catalog(pack).get("tracks", {}).get(name, {})
	var s := make_file_stream(path, bool(info.get("loop", true)))
	if s is AudioStreamOggVorbis and info.get("loop_start") != null:
		(s as AudioStreamOggVorbis).loop_offset = float(info.loop_start)
	return s


## A stream for an audio file (OGG / MP3 / WAV), looping or not.
static func make_file_stream(path: String, loop: bool) -> AudioStream:
	match path.get_extension().to_lower():
		"ogg":
			var o := AudioStreamOggVorbis.load_from_file(path)
			if o:
				o.loop = loop
			return o
		"mp3":
			var m := AudioStreamMP3.load_from_file(path)
			if m:
				m.loop = loop
			return m
		"wav":
			var w := AudioStreamWAV.load_from_file(path)
			if w and loop:
				w.loop_mode = AudioStreamWAV.LOOP_FORWARD
				w.loop_end = int(w.get_length() * w.mix_rate)
			return w
	return null


static func _load_json(path: String) -> Dictionary:
	if _json_cache.has(path):
		return _json_cache[path]
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f != null:
		var j = JSON.parse_string(f.get_as_text())
		if j is Dictionary:
			out = j
	_json_cache[path] = out
	return out


## Forgets cached tables (after an import).
static func clear_cache() -> void:
	_json_cache.clear()
