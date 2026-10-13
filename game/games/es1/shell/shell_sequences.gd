class_name ShellSequences
extends RefCounted
## The shell's non-interactive sequences: boot (FLIC + startup TTMs + blast doors), TTM scenes, ANM
## door animations, lip-synced talking heads (commanders, debriefing officers, the general, the
## hangar chief), credits and the quit animation. While one runs, `shell.busy` is set: any input
## skips the current piece (skip_requested), menu_back the rest (abort_requested).

const INTRO_MOVIE := "video/flic/intro3.ogv"
const INTRO_THEME_TTM := "IINTRO"     # startup TTM from which intro2 plays
const DEFAULT_ANM_FPS := 15.0
const COMMANDER_COUNT := 4
const GENERAL_REGION := 7000
## General Gierling's transmission at the start of each campaign 0..7 (GO.EXE table 0x814ec: G0_TEXT lines, played
## by 0x37f1e until -1): the welcome, then his verdict on the last tour and the next posting; line 54 "Gierling Out."
const GENERAL_LINES_BY_CAMPAIGN := [[0, 1, 2, 3, 5, 54], [6, 8, 9, 54], [10, 11, 12, 13, 14, 15, 16, 17, 18, 54],
	[19, 20, 21, 22, 23, 24, 25, 26, 54], [27, 28, 29, 30, 31, 32, 54], [33, 34, 35, 36, 37, 38, 39, 40, 41, 54],
	[42, 43, 44, 45, 46, 47, 54], [48, 49, 50, 51, 52, 53, 54]]
## Return from the sim (GO.EXE 0x3ba93): situation key of the song -> the scenes played, then the main
## menu (0x3b3db).  Pilot killed 0x3bc94: death + ENDFA (then the remake's replay prompt, MENU1250);
## campaign won 0x3bce6: intro2 + END_WIN1-3 + INTRO\EARTH; campaign lost 0x3bd30: losing + FAILED +
## INTRO\EARTH.
const CAREER_ENDINGS := {
	"pilot_killed": ["RES32/ENDFA"],
	"campaign_won": ["RES32/END_WIN1", "RES32/END_WIN2", "RES32/END_WIN3", "INTRO/EARTH"],
	"campaign_lost": ["RES32/FAILED", "INTRO/EARTH"],
}

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


func _tree() -> SceneTree:
	return shell.get_tree()


## A skippable sequence takes over the screen (no menus, no cursor).
func _begin() -> void:
	shell.busy = true
	shell.skip_requested = false
	shell.screen.cursor_visible = false


func _end() -> void:
	shell.busy = false
	shell.screen.cursor_visible = true


## Intro cinematic (unless --no-movie), startup TTMs and blast doors, then the main menu.
func boot() -> void:
	shell.set_region(EsShell.MAIN_MENU)
	shell.screen.cursor_visible = false
	if not OS.get_cmdline_user_args().has("--no-movie") and FileAccess.file_exists(Assets.path(INTRO_MOVIE)):
		var m := MoviePlayer.play(shell, INTRO_MOVIE)
		await m.finished
		print_verbose("shell: movie done at %d ms" % Time.get_ticks_msec())
	await play_intro()
	shell.goto_menu(EsShell.MAIN_MENU)


## Startup TTMs + blast doors.
func play_intro() -> void:
	shell.abort_requested = false
	shell.play_music("intro1")
	for n in ShellData.meta().get("startup", []):
		if shell.abort_requested:
			break
		if String(n).to_upper().ends_with(INTRO_THEME_TTM):
			shell.play_music("intro2")   # GO.EXE 0x3be13: intro2 from IINTRO.TTM on
		print_verbose("shell: TTM %s at %d ms" % [n, Time.get_ticks_msec()])
		await play_ttm([n])
	shell.screen.clear_fades()
	await play_anm("esiege2", "menucls1")


## Plays scripts in one scene until the main ones finish (or the player skips).
func play_ttm(names: Array, ambient := []) -> void:
	_begin()
	shell.scene = TTMScene.new(shell.screen)
	for n in names:
		shell.scene.add(n, true)
	for n in ambient:
		shell.scene.add(n, false)
	while not shell.scene.done and not shell.skip_requested and shell.is_inside_tree():
		await _tree().process_frame
	shell.scene = null
	_end()


## Blast-door animation (ESIEGE2 close / ESIEGE3 open) over the current screen.
func play_anm(anm_name: String, sound := "") -> void:
	var info: Dictionary = ShellData.meta().get("anm", {}).get(anm_name, {})
	var n := int(info.get("frames", 0))
	if n == 0:
		return
	shell.busy = true
	if sound != "":
		Sfx.play_ui(sound)
	var frame_time := 1.0 / float(info.get("fps", DEFAULT_ANM_FPS))
	for i in n:
		var img := Image.load_from_file(Assets.path("shell/anm/%s/%03d.png" % [anm_name, i + 1]))
		if img:
			shell.screen.show_overlay(ImageTexture.create_from_image(img))
		await _wait(frame_time)
	shell.busy = false


func _wait(seconds: float) -> void:
	var t := 0.0
	while t < seconds and shell.is_inside_tree():
		await _tree().process_frame
		t += shell.get_process_delta_time()


# ------------------------------------------------------------------ talking heads

## Lip-synced speech (TalkingHead): speaker "C0".."C3" (commanders), "D0".."D3" (debrief officers), "G0" (general),
## "T1" (hangar chief). `line` indexes <speaker>_FILES.DAT / <speaker>_TEXT.BIN.
func play_talk(speaker: String, line: int, ambient := []) -> void:
	shell.subtitle = TalkingHead.make_subtitle(speaker, line)
	_begin()
	shell.scene = TTMScene.new(shell.screen)
	shell.scene.set_background(shell.region_bg)
	var talk := TalkingHead.new(shell.scene, shell.voice, shell, func() -> bool: return shell.skip_requested)
	await talk.play(speaker, line, ambient)
	shell.subtitle = ""
	_end()


## MENU1499: campaign commander C<campaign> briefs the next mission (line = mission type 0..8).
func play_briefing_transmission(campaign: int, line: int) -> void:
	var c := clampi(campaign, 0, COMMANDER_COUNT - 1)
	shell.stack.clear()
	shell.set_region(3000, c)
	var amb := []
	for n in ["C%d_BRD" % c, "C%d_BRJ" % c]:
		if not ShellData.ttm(n).is_empty():
			amb.append(n)
	await play_talk("C%d" % c, line, amb)


## Debriefing officer D<campaign>; line indexes D?_TEXT (0 = "Well done", 4 = "You failed" ...).
func play_debriefing(campaign: int, line: int) -> void:
	var c := clampi(campaign, 0, COMMANDER_COUNT - 1)
	shell.set_region(5000, c)
	var amb := []
	if not ShellData.ttm("C%d_BLNK" % c).is_empty():
		amb.append("C%d_BLNK" % c)
	await play_talk("D%d" % c, line, amb)


## MENU1490: General Gierling on the video monitor (region 7000), several lines in a row.  With a
## campaign (0..7) his transmission plays that campaign's world theme (GO.EXE 0x37f1e). The monitor shows him at
## once and between the lines (G0_ON / G0_OFF / G0_STAT are leftovers: GO.EXE never loads them).
func play_general(lines: Array, campaign := -1) -> void:
	shell.stack.clear()
	shell.set_region(GENERAL_REGION)
	var themes: Array = MusicLibrary.situations(EsShell.PACK).get("general_transmission_by_campaign", [])
	if campaign >= 0 and campaign < themes.size():
		shell.play_music(String(themes[campaign]))
	for l in lines:
		if shell.abort_requested:
			break
		await play_talk("G0", int(l))


## The general's transmission for the start of campaign `campaign` (GENERAL_LINES_BY_CAMPAIGN).
func play_general_for_campaign(campaign: int) -> void:
	if campaign >= 0 and campaign < GENERAL_LINES_BY_CAMPAIGN.size():
		await play_general(GENERAL_LINES_BY_CAMPAIGN[campaign], campaign)


# ------------------------------------------------------------------ credits / quit

func play_credits() -> void:
	shell.stack.clear()
	shell.play_music("intro2")
	shell.abort_requested = false
	for n in ShellData.meta().get("credits", []):
		if shell.abort_requested:
			break
		await play_ttm([n])
	shell.reset_music()
	shell.set_region(EsShell.MAIN_MENU)
	shell.goto_menu(EsShell.MAIN_MENU)


## The career is over (`ending`: "campaign_won" / "campaign_lost"): its song and scenes, then the main menu.
func play_career_ending(ending: String) -> void:
	await _play_ending_scenes(ending)
	_return_to_main_menu()


## The pilot was killed: the death song and ENDFA, then the main menu under the killed-in-action warning
## (MENU1250, with the remake's REPLAY).
func play_pilot_killed() -> void:
	await _play_ending_scenes("pilot_killed")
	_return_to_main_menu()
	shell.open_menu(EsShell.KILLED_MENU)


## Situation `ending`'s song and scenes (a CAREER_ENDINGS key).
func _play_ending_scenes(ending: String) -> void:
	shell.stack.clear()
	shell.play_music(String(MusicLibrary.situations(EsShell.PACK).get(ending, "")))
	shell.abort_requested = false
	for n in CAREER_ENDINGS.get(ending, []):
		if shell.abort_requested:
			break
		await play_ttm([n])


func _return_to_main_menu() -> void:
	shell.reset_music()
	shell.history = []
	shell.set_region(EsShell.MAIN_MENU)
	shell.goto_menu(EsShell.MAIN_MENU)


## EXIT TO DOS: the blast doors open, then the app's main menu (game library) returns; the
## original quit to DOS, here leaving Earthsiege must not close the whole app.
func play_quit() -> void:
	shell.stack.clear()
	await play_anm("esiege3", "menuopn2")
	shell.leave_to_main_menu()
