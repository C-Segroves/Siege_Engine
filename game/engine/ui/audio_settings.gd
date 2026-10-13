class_name AudioSettings
## Master and music volume, the music device and Battledrome's voices switch, kept in user://settings.json (Assets.settings) as 0..1 linear levels
## and applied to the Master bus and the Sfx music player.

const MASTER_KEY := "volume_master"
const MUSIC_KEY := "volume_music"
const DEFAULT_LEVEL := 1.0
const MASTER_BUS := 0
## Sfx plays music this much below full level (its own mix default).
const MUSIC_HEADROOM_DB := -6.0
const SILENT_DB := -80.0
## Battledrome Preferences VOICES (SoundManager +0x10a, default on: the shipped STORAGE.DAT reads voices 1): the
## arena announcer and the Herc's warning voice.
const VOICES_KEY := "bd_voices"
const DEFAULT_VOICES := true


static func level(key: String) -> float:
	return clampf(float(Assets.settings.get(key, DEFAULT_LEVEL)), 0.0, 1.0)


## Stores a level (0..1) and applies it right away.
static func apply_level(key: String, value: float) -> void:
	Assets.settings[key] = clampf(value, 0.0, 1.0)
	Assets.save_settings()
	apply_saved()


static func apply_saved() -> void:
	AudioServer.set_bus_volume_db(MASTER_BUS, make_db(level(MASTER_KEY)))
	var music_db := MUSIC_HEADROOM_DB + make_db(level(MUSIC_KEY))
	Sfx.music_volume_db = music_db
	if Sfx.music_player != null and Sfx.music_player.playing:
		Sfx.music_player.volume_db = music_db


## Switches the FM music render (MusicLibrary.DEVICES) and restarts the playing track with it.
static func apply_music_device(id: String) -> void:
	MusicLibrary.set_device(id)
	Sfx.reload_music()


static func voices_on() -> bool:
	return bool(Assets.settings.get(VOICES_KEY, DEFAULT_VOICES))


static func apply_voices(on: bool) -> void:
	Assets.settings[VOICES_KEY] = on
	Assets.save_settings()


static func make_db(linear: float) -> float:
	return maxf(linear_to_db(linear), SILENT_DB)
