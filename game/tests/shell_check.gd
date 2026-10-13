extends Node
## ES1 shell regressions (headless).
## QA #15: registering a second pilot with an existing career's name is refused with a message.
## QA #9: the ES1 debriefing officer keeps his head behind the DEBRIEFING panel
## from the first frame the menu shows - after his talk was skipped with ui_accept and when the
## debriefing opens directly (the bare body of REGN5000 must never show).
## Button look (docs/formats/shell.md section 5): MAIN MENU text buttons have the STYLES.DAT face
## colour[0] (light grey, not the dark ring colour) and dark ACTIVE label pixels; CRT gamma 1.0 is exact.
## Pilot killed (GO.EXE 0x3bc94): a career mission whose pilot died plays death + ENDFA instead of the
## debriefing, does not end the career but puts it back at its restore point (the save written at launch),
## and shows the killed-in-action warning (MENU1250) over the main menu with REPLAY, which flies the same
## mission again. A finished career's PROCEED shows CAREER OVER (MENU1260).
## The player's saves and career files are backed up and restored (saved_campaign_guard).
##   godot --headless --audio-driver Dummy --path game res://tests/shell_check.tscn -- --skip-intro --no-movie

const SHELL_SCENE := "res://es1_shell.tscn"
const SETTLE_SECONDS := 1.0
const SHOWN_FRAMES := 2           # frames after the menu opens (the e2e screenshot's moment)
const SKIP_AFTER_FRAMES := 3
## The officer's region of the 320x200 screen (right of the DEBRIEFING window).
const OFFICER_RECT := Rect2i(170, 40, 150, 160)
## Pixels allowed to differ (his eyes blink on their own timer).
const MAX_DIFFERENT_PIXELS := 200
const DUPLICATE_PILOT := "QADUPLICATE"
const ACTIVE_TEXT_INDEX := 0x1c   # ACTIVE.DFN letter colour (0x14 is its highlight)
const MIN_LABEL_PIXELS := 20

const KILLED_PILOT := "QAKILLED"

var _fails := 0
var _guard = preload("res://tests/saved_campaign_guard.gd").new()


func _ready() -> void:
	if not ShellData.available():
		print("shell_debrief_check: SKIP (shell data not exported)")
		get_tree().quit(0)
		return
	_guard.back_up()
	var shell: EsShell = load(SHELL_SCENE).instantiate()
	add_child(shell)
	await _wait(SETTLE_SECONDS)
	_check_duplicate_career(shell)
	await _check_button_look(shell)
	_check_gamma()
	await _check_pilot_killed(shell)
	_check_finished_career(shell)
	var direct := await _capture_debrief(shell, false)
	var head_direct := _count_different(direct, shell.region_bg)
	var skipped := await _capture_debrief(shell, true)
	var head_skipped := _count_different(skipped, shell.region_bg)
	_expect(head_direct > MAX_DIFFERENT_PIXELS, "officer's head drawn at once when the debriefing opens (%d px over the body)" % head_direct)
	_expect(head_skipped > MAX_DIFFERENT_PIXELS, "officer's head drawn at once after a skipped talk (%d px over the body)" % head_skipped)
	var diff := _count_different(direct, skipped)
	_expect(diff <= MAX_DIFFERENT_PIXELS, "skipped talk leaves the same officer as the direct debriefing (%d pixels differ)" % diff)
	_guard.restore()
	print("shell_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


## REGISTER twice with the same name: one career, and the second attempt explains why.
func _check_duplicate_career(shell: EsShell) -> void:
	for attempt in 2:
		shell.goto_menu(EsShell.CAREER_MENU)
		shell.open_menu(EsShell.REGISTER_MENU)
		shell.top().find(103, ShellMenu.T_EDIT).text = DUPLICATE_PILOT
		shell.commands.run(shell.top(), EsShell.OK_ID)
	var count := shell.careers.list.filter(func(c: Dictionary) -> bool: return c.name == DUPLICATE_PILOT).size()
	_expect(count == 1, "a duplicate career name is refused (%d careers named %s)" % [count, DUPLICATE_PILOT])
	_expect(shell.subtitle.contains("ALREADY REGISTERED"), "the shell says why ('%s')" % shell.subtitle)
	_expect(shell.top() != null and shell.top().id == EsShell.REGISTER_MENU, "REGISTER stays open for another name")
	_expect(SaveGames.exists(ShellCareers.autosave_id(DUPLICATE_PILOT)), "the registered career is its pilot's autosave in the save store")
	shell.subtitle = ""


## Back from the sim with the career pilot killed: the death song and scenes, the career back at its
## restore point (not over), the killed-in-action warning with REPLAY, and REPLAY relaunches the mission.
func _check_pilot_killed(shell: EsShell) -> void:
	var career := shell.careers.make_new(KILLED_PILOT)
	MissionLaunch.ensure_campaign_state(career)
	shell.careers.save(career)
	ShellCareers.save_restore_point(career)   # as MissionLaunch.launch does
	var mission := str(career.next_mission)
	career["missions"] = 7                     # what the lost battle must not keep
	EsShell.career = career
	EsShell.last_launch = {"state": {"mode": "career"}}
	EsShell.mission_result = {"success": false, "pilot_killed": true}
	shell.reset_music()
	shell.missions.show_debriefing()
	await get_tree().process_frame
	var song := String(MusicLibrary.situations(EsShell.PACK).get("pilot_killed", ""))
	var want := MusicLibrary.make_stream(song, EsShell.PACK)
	_expect(want != null and shell.music.stream != null and is_equal_approx(shell.music.stream.get_length(), want.get_length())
		and shell.busy, "the killed pilot's scenes play (busy) with the %s song" % song)
	shell.abort_requested = true
	shell.skip_requested = true
	for i in SKIP_AFTER_FRAMES * 4:
		await get_tree().process_frame
	_expect(not bool(EsShell.career.get("over", false)) and str(EsShell.career.get("name", "")) == KILLED_PILOT,
		"a killed pilot no longer ends the career")
	_expect(int(EsShell.career.get("missions", -1)) == 0 and str(EsShell.career.next_mission) == mission,
		"the career is back at its restore point (mission %s)" % mission)
	_expect(shell.top() != null and shell.top().id == EsShell.KILLED_MENU and shell.base_menu().id == EsShell.MAIN_MENU,
		"the killed-in-action warning shows over the main menu")
	_expect(not shell.top().find(EsShell.REPLAY_CMD).is_empty() and not shell.top().find(EsShell.CANCEL_ID).is_empty(),
		"it offers REPLAY and DONE")
	await _check_replay(shell, mission)


## REPLAY launches the career's mission again (the launch handler is stubbed: no battle starts).
func _check_replay(shell: EsShell, mission: String) -> void:
	var launched := []
	var handler := EsShell.launch_handler
	EsShell.launch_handler = func(_s: Node, mission_name: String, _state: Dictionary) -> void: launched.append(mission_name)
	shell.commands.run(shell.top(), EsShell.REPLAY_CMD)
	for i in SKIP_AFTER_FRAMES:
		await get_tree().process_frame
	EsShell.launch_handler = handler
	shell.launching = false
	_expect(launched == [mission], "REPLAY flies mission %s again (%s)" % [mission, launched])
	shell.goto_menu(EsShell.MAIN_MENU)


## PROCEED with a finished career: CAREER OVER (MENU1260) instead of the hub.
func _check_finished_career(shell: EsShell) -> void:
	EsShell.career = {"name": KILLED_PILOT, "over": true, "victory": true}
	shell.goto_menu(EsShell.CAREER_MENU)
	shell.commands.run(shell.top(), EsShell.HANGAR_HUB)
	_expect(shell.top().id == EsShell.CAREER_OVER_MENU, "a finished career cannot be continued: CAREER OVER (%d)" % shell.top().id)
	EsShell.career = {}
	shell.goto_menu(EsShell.MAIN_MENU)


## First MAIN MENU text button: face = style 0 colour[0], label drawn in the ACTIVE letter colour.
func _check_button_look(shell: EsShell) -> void:
	shell.goto_menu(EsShell.MAIN_MENU)
	for i in SHOWN_FRAMES:
		await get_tree().process_frame
	var m := shell.top()
	var button := {}
	for c in m.controls:
		if int(c.type) == ShellMenu.T_BUTTON and int(c.flags) == 0 and c.enabled and str(c.label) != "":
			button = c
			break
	_expect(not button.is_empty(), "MAIN MENU has a text button")
	if button.is_empty():
		return
	var r: Rect2i = button.r
	var face_at := r.position + Vector2i(ShellStyle.FACE_INSET, ShellStyle.FACE_INSET)
	var face := _index_at(shell.screen.image, face_at)
	var want := m.styles[ShellMenu.STYLE_NORMAL].face_color()
	_expect(face == want, "button '%s' face is STYLES.DAT colour[0] (%d, want %d)" % [button.label, face, want])
	var letters := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if _index_at(shell.screen.image, Vector2i(x, y)) == ACTIVE_TEXT_INDEX:
				letters += 1
	_expect(letters >= MIN_LABEL_PIXELS, "button '%s' label drawn in the ACTIVE colour (%d px)" % [button.label, letters])


func _check_gamma() -> void:
	var c := Color8(60, 120, 231)
	_expect(DisplaySettings.make_corrected(c, 1.0).is_equal_approx(c), "CRT gamma 1.0 shows the raw palette")
	_expect(DisplaySettings.make_corrected(c, DisplaySettings.DEFAULT_GAMMA).r > c.r, "default CRT gamma brightens mid tones")


static func _index_at(img: Image, p: Vector2i) -> int:
	return int(round(img.get_pixelv(p).r * 255.0))


## The officer region of MENU1520 after the debriefing talk (skipped with ui_accept) or without it.
func _capture_debrief(shell: EsShell, after_skipped_talk: bool) -> Image:
	EsShell.career = {"name": "TEST", "campaign": 0}
	if after_skipped_talk:
		_press_accept_soon()
		await shell.sequences.play_debriefing(0, 0)
	shell.goto_menu(EsShell.CAREER_DEBRIEF_MENU)
	for i in SHOWN_FRAMES:
		await get_tree().process_frame
	return shell.screen.image.get_region(OFFICER_RECT)


## Skips the talk the way a player does: ui_accept a few frames after it starts.
func _press_accept_soon() -> void:
	for i in SKIP_AFTER_FRAMES:
		await get_tree().process_frame
	for pressed in [true, false]:
		var ev := InputEventAction.new()
		ev.action = "ui_accept"
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame


func _count_different(a: Image, b: Image) -> int:
	var n := 0
	var bb := b.get_region(OFFICER_RECT) if b.get_size() != a.get_size() else b
	for y in a.get_height():
		for x in a.get_width():
			if a.get_pixel(x, y) != bb.get_pixel(x, y):
				n += 1
	return n


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1
