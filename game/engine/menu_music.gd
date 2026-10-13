class_name MenuMusic
extends RefCounted
## Music of the app's own screens, chosen by the game the player is in (docs/formats/audio_video.md §3):
##   * a game's context (its campaign's briefing / debriefing / hangar, the saga's Starsiege choice, a LAN lobby
##     on its map): that game's original menu music -- Earthsiege 2 SHELL2 / SHELL1, Starsiege SHELL1,
##     Tribes CD track 2, Battledrome's shell song; Earthsiege plays its shell's region song for the same
##     place (briefing map, debriefing, main menu); Tribes 2's shell was silent, so is its context;
##   * the app's own hubs (library home, launcher main menu) belong to no game: silent (remake decision);
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


## The app's hubs: no game's music.
static func play_app_hub() -> void:
	Sfx.stop_music(HUB_FADE)


## The running campaign's game, on app screen `screen` ("briefing", "debrief", ...).
static func play_for_campaign(screen: String) -> void:
	if Session.campaign != null:
		play_for_pack(Session.campaign_pack(Session.campaign), screen)


## The menu music of game `pack` on app screen `screen`; silence for a game without menu music.
static func play_for_pack(pack: String, screen := "") -> void:
	match pack:
		ES1:
			_play_es1(String(_es1_regions().get(ES1_REGION_BY_SCREEN.get(screen, ES1_MAIN_REGION), "")))
		BATTLEDROME:
			Sfx.play_music(String(MusicLibrary.situations(BATTLEDROME).get("shell", "")), MENU_FADE, BATTLEDROME)
		_:
			if not CdMusic.play_menu(pack):
				Sfx.stop_music(HUB_FADE)


## The campaign is over (won when `won`): Earthsiege's ending songs (GO.EXE 0x3bce6 intro2 / 0x3bd30 losing),
## else the game's menu music.
static func play_campaign_end(pack: String, won: bool) -> void:
	if pack == ES1:
		_play_es1(String(MusicLibrary.situations(ES1).get("campaign_won" if won else "campaign_lost", "")))
	else:
		play_for_pack(pack)


## The pilot was killed in a campaign mission: Earthsiege's death song (GO.EXE 0x3bc94), else the game's
## menu music (the other games had no death music).
static func play_pilot_killed(pack: String) -> void:
	if pack == ES1:
		_play_es1(String(MusicLibrary.situations(ES1).get("pilot_killed", "")))
	else:
		play_for_pack(pack)


## The game a battle config's map comes from: "pack:id" maps, Battledrome arenas, else Earthsiege worlds.
static func make_pack_of_map_config(config: Dictionary) -> String:
	if config.has("arena") and not config.has("map"):
		return BATTLEDROME
	var map := String(config.get("map", ""))
	return map.get_slice(":", 0) if map.contains(":") else ES1


static func _play_es1(track: String) -> void:
	if track != "":
		Sfx.play_music(track, MENU_FADE, ES1)


static func _es1_regions() -> Dictionary:
	return MusicLibrary.situations(ES1).get("region_music", {})
