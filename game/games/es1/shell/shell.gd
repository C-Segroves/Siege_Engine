class_name EsShell
extends Control
## The original Earthsiege front end (GO.EXE) rebuilt on the exported shell data.
##
## Boot: intro cinematic (FLIC) -> startup TTMs (DYNAMIX, LEAD_IN, IINTRO, EARTH_W) -> blast doors (ESIEGE2.ANM)
## -> MENU1000. Menus are the original DLG layouts (ShellMenu), backgrounds are the REGN<r> regions,
## talking heads / intro pictures run on the TTM interpreter (TTMScene). Everything is drawn into a
## 320x200 8-bit frame buffer (ShellScreen).
##
## Parts: ShellInput (input actions -> menus), ShellCommands (what each button does), ShellMenuContent
## (remake additions, list contents, text gadgets), ShellSequences
## (cinematics, talking heads), ShellMissions (briefings, launching, debriefing, the killed pilot's replay),
## ShellCareers (careers = the pilots' Earthsiege autosaves in the shared SaveGames store), ShellBackups
## (CAREER BACKUPS: SAVE / RESTORE named saves of the same store), ShellHangar (the hub's 3D bay;
## ARMING / REPAIR / BUILD open the app's Hangar screen on the career's garage), ShellDebug (--shell= test
## targets).
##
## Hooks for the mission / campaign runtime (game/games/es1/mission_*.gd):
##   * EsShell.launch_handler = func(shell: EsShell, mission_name: String, campaign_state: Dictionary)
##     replaces the default "start a skirmish Battle" launch. `mission_requested` is emitted either way.
##   * EsShell.mission_result = {"success": bool, "text": String, ...} before returning to the shell
##     makes it show the debriefing (MENU1510 single / MENU1520 career) instead of the main menu.
##   * briefing_text feeds the briefing-map gadget, list_providers[id] / gadget_handlers[id]
##     override list contents and custom gadgets of any DLG.
##   * Public: start_mission(), play_briefing_transmission(), play_debriefing(), play_general(), goto_menu().
## Flags: --skip-intro --no-movie --screenshot=<png> --shell=<target> (ShellDebug).

signal mission_requested(mission_name: String, campaign_state: Dictionary)
signal menu_changed(menu_id: int)

## The pack whose music the shell plays.
const PACK := "es1"
const MAIN_MENU := 1000
const SINGLE_MENU := 1100
const PARAMS_MENU := 1110
const CAREER_MENU := 1200
const REGISTER_MENU := 1210
const BACKUPS_MENU := 1220
const OVERWRITE_BACKUP_MENU := 1240
const KILLED_MENU := 1250
const CAREER_OVER_MENU := 1260
const OPTIONS_MENU := 1300
const BRIEFING_MENU := 1500
const SINGLE_BRIEFING_MENU := 1501
const SINGLE_DEBRIEF_MENU := 1510
const CAREER_DEBRIEF_MENU := 1520
const HANGAR_HUB := 1700
const HANGAR_HUB_DEBRIEFED := 1710
const LAUNCHING_MENU := 9999
const OK_ID := 100
const CANCEL_ID := 99
const MULTIPLAYER_CMD := 9001
const LAUNCHER_CMD := 9002
const REPLAY_CMD := 9003               # remake: REPLAY on the killed-in-action warning (MENU1250)
const LAUNCHER_SCENE := "res://launcher.tscn"
## SM_<type> single missions on the disc (ZONES/MSN), grouped like the SINGLE MISSION list:
## [label, file code, commander briefing line].
const SINGLE_TYPES := [
	["RECON", "RCN", 0], ["SCOUT", "SCT", 0], ["PATROL", "PTL", 1], ["RAID", "RAD", 2],
	["SCRAMBLE", "SCR", 3], ["SEARCH & RESCUE", "SAR", 4], ["ASSAULT", "ASS", 5], ["ESCORT", "ESC", 7],
]
const SINGLE_MISSIONS := ["SM_ASS01", "SM_ESC50", "SM_PTL01", "SM_PTL02", "SM_RAD01", "SM_RAD02", "SM_RCN01",
	"SM_RCN02", "SM_RCN03", "SM_SAR01", "SM_SCR01", "SM_SCT01", "SM_SCT02", "SM_SCT50"]
## MENU1110 option values (labels approximated — the original value strings live in GO.EXE).
const PARAM_VALUES := {
	1116: ["LIMITED", "UNLIMITED"], 1117: ["REALISTIC", "REDUCED", "NONE"], 1118: ["EASY", "MEDIUM", "HARD"],
	1119: ["CLEAR", "HAZY", "FOGGY"], 1120: ["DAY", "DUSK", "NIGHT"],
}
const MAX_HISTORY := 16
const MUSIC_VOLUME_DB := -6.0
const SUBTITLE_WIDTH := 276
const SUBTITLE_LINES := 3
const TEXTBOX_HEIGHT := 29
const TOAST_SECONDS := 2.5

static var booted := false
static var launch_handler: Callable
static var mission_result := {}
static var career := {}                 # current career / campaign state
static var single := {"type": 0, "params": {1116: 0, 1117: 0, 1118: 1, 1119: 0, 1120: 0}}
static var last_launch := {}
static var flow := "single"             # which branch BEGIN MISSION launches: "single" or "career"

var screen: ShellScreen
var region := 1000
var region_bg: Image
var stack: Array = []                   # ShellMenu, top = active
var history: Array = []                 # full-screen menu ids
var scene: TTMScene                     # animation running behind / instead of the menus
var subtitle := ""
var list_providers := {}                # list id -> Callable(menu, ctl) -> Array
var gadget_handlers := {}               # gadget id -> Callable(menu, ctl, img)
var briefing_text := ""
var debrief_text := ""
var music: AudioStreamPlayer
var voice: AudioStreamPlayer
var busy := false                       # a sequence (TTM / talk / anm) owns the screen
var skip_requested := false             # skip the running sequence piece
var abort_requested := false            # skip the rest of a sequence chain
var launching := false
var screenshot_path := ""
var textbox: Image

var sequences := ShellSequences.new(self)
var careers := ShellCareers.new()
var backups := ShellBackups.new(self)
var hangar := ShellHangar.new(self)
var missions := ShellMissions.new(self)
var commands := ShellCommands.new(self)
var content := ShellMenuContent.new(self)
var debug := ShellDebug.new(self)
var _input_router := ShellInput.new(self)
var _music_name := ""
var _toast_id := 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var args := OS.get_cmdline_user_args()
	if _wants_launcher(args):
		switch_scene.call_deferred(LAUNCHER_SCENE)
		return
	if not launch_handler.is_valid():
		MissionLaunch.install()
	_build_screen()
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	careers.load_all()
	_apply_flags(args)
	_start(args)


func _wants_launcher(args: PackedStringArray) -> bool:
	for a in args:
		if a.begins_with("--autohost=") or a.begins_with("--autojoin="):
			return true
	if not ShellData.available():
		push_warning("shell data missing (run tools/export_shell.py) - falling back to the dev launcher")
		return true
	return false


func _build_screen() -> void:
	screen = ShellScreen.new()
	add_child(screen)
	music = AudioStreamPlayer.new()
	music.volume_db = MUSIC_VOLUME_DB
	add_child(music)
	voice = AudioStreamPlayer.new()
	add_child(voice)
	var tb := ShellData.sheet("TEXTBOX", "RES32")
	textbox = tb[0] if not tb.is_empty() else null


func _apply_flags(args: PackedStringArray) -> void:
	for a in args:
		if a.begins_with("--screenshot="):
			screenshot_path = a.substr(13)


func _start(args: PackedStringArray) -> void:
	var target := ""
	for a in args:
		if a.begins_with("--shell="):
			target = a.substr(8)
	var first_boot := not booted
	booted = true
	if target != "":
		debug.run_target(target)
	elif not mission_result.is_empty():
		missions.show_debriefing()
	elif not first_boot or args.has("--skip-intro"):
		goto_menu(MAIN_MENU)
	else:
		sequences.boot()


func _exit_tree() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _input(event: InputEvent) -> void:
	_input_router.handle(event)


# ================================================================== regions / music

## Shell region: background REGN<r>.DBM + palette (3000/5000 + campaign index pick the palette/picture).
func set_region(r: int, campaign := -1) -> void:
	var base := r
	if campaign >= 0 and (r == 3000 or r == 5000):
		r = base + campaign
	region = r
	var pic := "REGN%d" % (base if base == 3000 else r)
	region_bg = ShellData.background(pic, "RES32")
	if region_bg == null:
		region_bg = ShellData.background("REGN1000", "RES32")
	screen.clear_fades()
	screen.set_palette(ShellData.palette("REGN%d" % r, "RES32"), false)
	var track = region_music().get(str(base))
	if track != null:
		play_music(str(track))


## Region -> track (GO.EXE 0x395a0 / table 0x817d0, decoded in tools/music_games.py); older exports from meta.
func region_music() -> Dictionary:
	var m: Dictionary = MusicLibrary.situations(PACK).get("region_music", {})
	return m if not m.is_empty() else ShellData.meta().get("region_music", {})


## Plays an Earthsiege track (MusicLibrary: the chosen music device's render, looping from its loop pass);
## silently skips tracks that have not been rendered.
func play_music(track: String) -> void:
	if track == _music_name:
		return
	var s := MusicLibrary.make_stream(track, PACK)
	if s == null:
		return
	music.stream = s
	music.play()
	_music_name = track


## Forgets the playing track so the next play_music() restarts it.
func reset_music() -> void:
	_music_name = ""


# ================================================================== menus

func top() -> ShellMenu:
	return stack.back() if not stack.is_empty() else null


## Full-screen menu (replaces the stack). Region follows GO.EXE's menu -> region table.
func goto_menu(mid: int) -> void:
	screen.show_overlay(null)
	scene = null
	subtitle = ""
	screen.cursor_visible = true
	_apply_flow(mid)
	_apply_menu_region(mid)
	if mid in [SINGLE_DEBRIEF_MENU, CAREER_DEBRIEF_MENU]:
		_start_debrief_officer(mid)
	stack.clear()
	if history.is_empty() or history.back() != mid:
		history.append(mid)
	if history.size() > MAX_HISTORY:
		history.pop_front()
	_push(mid)


static func _apply_flow(mid: int) -> void:
	if mid == SINGLE_MENU:
		flow = "single"
	elif mid in [CAREER_MENU, HANGAR_HUB, HANGAR_HUB_DEBRIEFED]:
		flow = "career"


func _apply_menu_region(mid: int) -> void:
	var regions: Dictionary = ShellData.meta().get("menu_region", {})
	if regions.has(str(mid)):
		var r := int(regions[str(mid)])
		set_region(r, (int(career.get("campaign", 0)) if mid == CAREER_DEBRIEF_MENU else 0) if r == 5000 else -1)
	if mid == 1610:
		screen.set_palette(ShellData.palette("REGN1610", "RES32"), false)


## The debriefing officer stays on screen (head + blinks from C<c>_BLNK) behind the window, head
## included from the first frame (QA #9: after a skipped talk the bare body showed for the set-up wait).
func _start_debrief_officer(mid: int) -> void:
	var c := clampi(int(career.get("campaign", 0)) if mid == CAREER_DEBRIEF_MENU else 0, 0, 3)
	if ShellData.ttm("C%d_BLNK" % c).size() > 0:
		scene = TTMScene.new(screen)
		scene.set_background(region_bg)
		scene.apply_setup_frame(scene.add("C%d_BLNK" % c, false))


## Popup over the current menu (dialogs without their own region).
func open_menu(mid: int) -> void:
	var regions: Dictionary = ShellData.meta().get("menu_region", {})
	if regions.has(str(mid)) or stack.is_empty():
		goto_menu(mid)
	else:
		_push(mid)


func close_popup() -> void:
	if stack.size() > 1:
		stack.pop_back()
		refresh(top())
		Sfx.play_ui("button")
	else:
		back()


func back() -> void:
	if history.size() >= 2:
		history.pop_back()
		goto_menu(history.pop_back())
	else:
		goto_menu(MAIN_MENU)


## The full-screen menu under the popups (null when no menu is open).
func base_menu() -> ShellMenu:
	return stack[0] if not stack.is_empty() else null


func _push(mid: int) -> void:
	var m := ShellMenu.create(mid, self)
	if m == null:
		push_warning("menu %d not exported" % mid)
		return
	content.customize(m)
	stack.append(m)
	refresh(m)
	menu_changed.emit(mid)


## Fills lists from providers (list_providers first) and the hangar screens' fields.
func refresh(m: ShellMenu) -> void:
	content.refresh(m)


## ShellMenu host hook: draws gadget `c` of menu `m`.
func draw_gadget(m: ShellMenu, c: Dictionary, img: Image) -> void:
	content.draw_gadget(m, c, img)


## Runs button / list control `c` of menu `m` (sound, then its command).
func activate(m: ShellMenu, c: Dictionary) -> void:
	if c.is_empty() or launching:
		return
	Sfx.play_ui("button")
	commands.run(m, int(c.id))


# ================================================================== frame loop

func _process(delta: float) -> void:
	if screen == null:
		return
	if scene:
		scene.update(delta)
		screen.image.copy_from(scene.scr)
	elif region_bg:
		screen.image.copy_from(region_bg)
	hangar.draw_bay()
	hangar.apply_stick_orbit(delta)
	if not busy:
		for m in stack:
			m.draw(screen.image, delta)
	if subtitle != "":
		_draw_subtitle()


func _draw_subtitle() -> void:
	var f := ShellData.font("NM_GREEN")
	var lines := f.wrap(subtitle, SUBTITLE_WIDTH)
	var h := mini(lines.size(), SUBTITLE_LINES) * (f.height + 1) + 8
	var y := ShellScreen.H - h - 3
	var box_y := ShellScreen.H - TEXTBOX_HEIGHT - 3
	if textbox and h <= TEXTBOX_HEIGHT:
		ShellData.blit(screen.image, textbox, 16, box_y)
		y = box_y + (TEXTBOX_HEIGHT - (h - 8)) / 2
	else:
		ShellData.fill(screen.image, Rect2i(14, y, 292, h), 31)
		y += 4
	for i in mini(lines.size(), SUBTITLE_LINES):
		f.draw(screen.image, ShellScreen.W / 2 - f.width(lines[i]) / 2, y, lines[i])
		y += f.height + 1


## Short message in the original text box (bottom of the screen) for a few seconds.
func toast(text: String) -> void:
	subtitle = text
	_toast_id += 1
	var id := _toast_id
	await get_tree().create_timer(TOAST_SECONDS).timeout
	if is_inside_tree() and id == _toast_id and subtitle == text:
		subtitle = ""


# ================================================================== public sequences / missions

## Startup TTMs + blast doors. Any input skips the current piece, menu_back skips the rest.
func play_intro() -> void:
	await sequences.play_intro()


func play_ttm(names: Array, ambient := []) -> void:
	await sequences.play_ttm(names, ambient)


func play_anm(anm_name: String, sound := "") -> void:
	await sequences.play_anm(anm_name, sound)


func play_talk(speaker: String, line: int, ambient := []) -> void:
	await sequences.play_talk(speaker, line, ambient)


func play_briefing_transmission(campaign: int, line: int) -> void:
	await sequences.play_briefing_transmission(campaign, line)


func play_debriefing(campaign: int, line: int) -> void:
	await sequences.play_debriefing(campaign, line)


func play_general(lines: Array, campaign := -1) -> void:
	await sequences.play_general(lines, campaign)


func start_instant_action() -> void:
	await missions.start_instant_action()


func start_mission(mission_name: String, campaign_state: Dictionary) -> void:
	await missions.start_mission(mission_name, campaign_state)


## Shows the "launching" placeholder menu while the battle loads.
func show_launching(mission_name: String, campaign_state: Dictionary) -> void:
	last_launch = {"mission": mission_name, "state": campaign_state}
	mission_requested.emit(mission_name, campaign_state)
	stack.clear()
	_push(LAUNCHING_MENU)


# ================================================================== multiplayer / scenes

## Opens the LAN host / join UI (launcher.gd in multiplayer-only mode).
func open_multiplayer() -> void:
	var l: Node = load(LAUNCHER_SCENE).instantiate()
	l.set("multiplayer_only", true)
	replace_with(l)


## Leaves Earthsiege for the app's main menu (game library); the app keeps running.
func leave_to_main_menu() -> void:
	Sfx.stop_music(0.5)
	switch_scene(Session.MAIN_MENU_SCENE)


func switch_scene(path: String) -> void:
	replace_with(load(path).instantiate())


## Makes `n` the current scene and frees the shell.
func replace_with(n: Node) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var tree := get_tree()
	tree.root.add_child(n)
	tree.current_scene = n
	queue_free()
