class_name MenuMusic
extends RefCounted
## Music of the app's own screens, chosen by the game the player is in (docs/formats/audio_video.md §3):
##   * a game's context (its campaign's briefing / debriefing / hangar, the saga's Starsiege choice, a LAN lobby
##     on its map): that game's original menu music -- Earthsiege 2 SHELL2 / SHELL1, Starsiege SHELL1,
##     Tribes CD track 2, Battledrome's shell song; Earthsiege plays its shell's region song for the same
##     place (briefing map, debriefing, main menu); Tribes 2's shell was silent, so is its context;
##   * the app's own hubs (library home), and any game or map without menu music of its own
##     (Tribes 2's silent shell, the remake's extraction maps, a game whose music isn't installed): the
##     installed music, shuffled (MusicShuffle), carrying on if it is already playing;
##   * the end of a campaign: Earthsiege's won / lost songs, the other games' menu music (they had none);
##   * a pilot killed in a campaign mission (the replay prompt): Earthsiege's death song, else the menu music.
## The jukebox plays what the player picks and is left alone.  A song only restarts when it changes.

const ES1 := "es1"
const BATTLEDROME := "bd"
const STARSIEGE := "starsiege"
const HUB_FADE := 1.0
const MENU_FADE := 1.0
## App screen -> the Earthsiege shell region it stands for (GO.EXE 0x395a0: 5000 debriefing, 6000 briefing map).
const ES1_REGION_BY_SCREEN := {"briefing": "6000", "debrief": "5000"}
const ES1_MAIN_REGION := "1000"

static var _shuffle := MusicShuffle.new()


## The app's hubs: no game's music of their own, so the installed music, shuffled.
static func play_app_hub() -> void:
	play_unscored()


## Somewhere no game scored: keep the shuffle going, or start it (silence only with no music installed).
static func play_unscored(prefer_pack := "") -> void:
	if _shuffle.is_playing():
		return
	if not _shuffle.start(prefer_pack):
		Sfx.stop_music(HUB_FADE)


## The running campaign's game, on app screen `screen` ("briefing", "debrief", ...).
static func play_for_campaign(screen: String) -> void:
	if Session.campaign != null:
		play_for_pack(Session.campaign_pack(Session.campaign), screen)


## The menu music of game `pack` on app screen `screen`; the shuffle for a game without menu music.
static func play_for_pack(pack: String, screen := "") -> void:
	match pack:
		ES1:
			_play_es1(String(_es1_regions().get(ES1_REGION_BY_SCREEN.get(screen, ES1_MAIN_REGION), "")), pack)
		BATTLEDROME:
			_play_named(String(MusicLibrary.situations(BATTLEDROME).get("shell", "")), BATTLEDROME)
		_:
			if not CdMusic.play_menu(pack):
				play_unscored(pack)


## The campaign is over (won when `won`): Earthsiege's ending songs (GO.EXE 0x3bce6 intro2 / 0x3bd30 losing),
## else the game's menu music.
static func play_campaign_end(pack: String, won: bool) -> void:
	if pack == ES1:
		_play_es1(String(MusicLibrary.situations(ES1).get("campaign_won" if won else "campaign_lost", "")), pack)
	else:
		play_for_pack(pack)


## The pilot was killed in a campaign mission: Earthsiege's death song (GO.EXE 0x3bc94), else the game's
## menu music (the other games had no death music).
static func play_pilot_killed(pack: String) -> void:
	if pack == ES1:
		_play_es1(String(MusicLibrary.situations(ES1).get("pilot_killed", "")), pack)
	else:
		play_for_pack(pack)


## The game a battle config's map comes from: "pack:id" maps, Battledrome arenas, else Earthsiege worlds.
static func make_pack_of_map_config(config: Dictionary) -> String:
	if config.has("arena") and not config.has("map"):
		return BATTLEDROME
	var map := String(config.get("map", ""))
	return map.get_slice(":", 0) if map.contains(":") else ES1


static func _play_es1(track: String, pack: String) -> void:
	_play_named(track, ES1, pack)


## A game's named menu song, or the shuffle when it has none on disk.
static func _play_named(track: String, music_pack: String, prefer_pack := "") -> void:
	if track == "" or MusicLibrary.track_path(track, music_pack) == "":
		play_unscored(prefer_pack if prefer_pack != "" else music_pack)
		return
	Sfx.play_music(track, MENU_FADE, music_pack)


static func _es1_regions() -> Dictionary:
	return MusicLibrary.situations(ES1).get("region_music", {})
