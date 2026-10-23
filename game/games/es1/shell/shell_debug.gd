class_name ShellDebug
extends RefCounted
## Test targets of the shell (--shell=<target>), screenshots and the scripted UI tests.
##
## --shell=menu:<id>[:<parent id>] | ttm:<script> | talk:<speaker>[:<line>] | general | intro | boot
##        | launch[:<mission>] | career-launch | autotest | hangar-test
## --screenshot=<png or prefix> [--shot-delay=<seconds>]
## Hangar screens without a career get a throw-away TEST career; --hangar-add=<vehicle id> builds and
## selects a Herc of any enabled pack (no campaign limits), --hangar-salvage=<id>,<id>... adds salvaged
## weapons to the armory.

const DEFAULT_SHOT_DELAY := 2.0
const SNAPSHOT_SIZE := Vector2i(640, 400)
const DEFAULT_SINGLE_MISSION := "SM_RCN01"
const BOOT_POLL := 0.25             # seconds between checks while the autotest waits for MENU1000
const BOOT_POLL_LIMIT := 400
const BOOT_SKIP_EVERY := 4          # polls between skip taps
const CAREER_TEST_MENUS := [1500, 1610]
const AUTOTEST_STEPS := [[1100, "_2_single.png"], [1110, "_3_params.png"], [99, ""], [1501, "_4_briefing.png"],
	[99, ""], [1000, ""], [1300, "_5_options.png"], [100, ""], [1200, "_6_career.png"], [1210, "_7_register.png"]]
const AUTOTEST_PILOT := "ACE"
const ARMING_BUTTON := 1800
const BUILD_BUTTON := 2000

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


func _tree() -> SceneTree:
	return shell.get_tree()


func run_target(t: String) -> void:
	var p := t.split(":")
	match p[0]:
		"menu":
			_open_test_menu(int(p[1]), int(p[2]) if p.size() > 2 else EsShell.MAIN_MENU)
		"ttm":
			shell.set_region(EsShell.MAIN_MENU)
			shell.play_ttm([p[1]])
		"talk":
			_play_test_talk(p[1], int(p[2]) if p.size() > 2 else 0)
		"general":
			shell.play_general([0, 1])
		"intro":
			shell.set_region(EsShell.MAIN_MENU)
			shell.play_intro()
		"boot":
			shell.sequences.boot()
		"launch":
			shell.start_mission(p[1] if p.size() > 1 else DEFAULT_SINGLE_MISSION, {"mode": "single"})
			return
		"career-launch":
			# BEGIN MISSION from the hangar with the (TEST) career's selected Herc
			apply_test_career(EsShell.HANGAR_HUB)
			shell.missions.launch_current_anyway()
			return
		"autotest":
			run_autotest()
			return
		"hangar-test":
			run_hangar_test()
			return
	if shell.screenshot_path != "":
		_shoot_and_quit()


func _open_test_menu(mid: int, parent: int) -> void:
	apply_test_career(mid)
	shell.set_region(EsShell.MAIN_MENU)
	if ShellData.meta().get("menu_region", {}).has(str(mid)):
		shell.goto_menu(mid)
	else:
		shell.goto_menu(parent)
		shell.open_menu(mid)


func _play_test_talk(sp: String, line: int) -> void:
	var c := int(sp.substr(1))
	if sp.begins_with("C"):
		shell.play_briefing_transmission(c, line)
	elif sp.begins_with("D"):
		shell.play_debriefing(c, line)
	else:
		shell.set_region(ShellSequences.GENERAL_REGION)
		shell.play_talk(sp, line)


## Hangar / briefing test screens: a throw-away TEST career when none is loaded, plus the
## --hangar-* flags.
func apply_test_career(mid: int) -> void:
	if not (mid in ShellHangar.HUB_MENUS or mid in CAREER_TEST_MENUS):
		return
	if EsShell.career.is_empty():
		EsShell.career = ShellCareers.make_test()
	EsShell.flow = "career"
	var campaign := shell.hangar.career_campaign()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hangar-add="):
			campaign.garage.apply_build({}, a.substr(13))
		elif a.begins_with("--hangar-salvage="):
			campaign.apply_salvage(Array(a.substr(17).split(",", false)))
	EsShell.career["campaign_state"] = campaign.to_dict()


func _shoot_and_quit() -> void:
	var delay := DEFAULT_SHOT_DELAY
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot-delay="):
			delay = float(a.substr(13))
	await _tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	_save_snapshot(shell.screenshot_path)
	shell.get_viewport().get_texture().get_image().save_png(shell.screenshot_path.get_basename() + "_window.png")
	_tree().quit()


# ------------------------------------------------------------------ scripted UI tests

## --shell=autotest --screenshot=<dir/prefix>: boots (skipping each intro piece with ui_accept), then
## clicks through MAIN -> SINGLE MISSION -> MISSION PARAMS -> BRIEFING -> OPTIONS -> CAREER ->
## REGISTER, types a pilot name, accepts it, and opens MULTIPLAYER, saving a screenshot per step.
func run_autotest() -> void:
	var prefix := _take_prefix("user://shell_test")
	shell.sequences.boot()
	await _wait_for_main_menu()
	await snap(prefix + "_1_main.png")
	for step in AUTOTEST_STEPS:
		var c := shell.top().find(int(step[0]))
		if c.is_empty():
			print("autotest: control %d not on menu %d" % [step[0], shell.top().id])
			continue
		click(c.r.get_center())
		await _tree().create_timer(0.6).timeout
		print("autotest: clicked %d -> menu %d" % [step[0], shell.top().id if shell.top() else -1])
		if step[1] != "":
			await snap(prefix + step[1])
	_type_text(AUTOTEST_PILOT)
	await _tree().create_timer(0.3).timeout
	tap_action("ui_accept")
	await _tree().create_timer(0.6).timeout
	await snap(prefix + "_8_career_created.png")
	print("autotest: careers ", shell.careers.list.size(), " current ", EsShell.career.get("name", ""))
	click(shell.top().find(EsShell.MAIN_MENU).r.get_center())
	await _tree().create_timer(0.4).timeout
	# the shell frees itself when it opens the LAN UI: report from a static callback
	_tree().create_timer(1.0).timeout.connect(ShellDebug.report_scene_and_quit)
	click(shell.top().find(EsShell.MULTIPLAYER_CMD).r.get_center())


func _take_prefix(fallback: String) -> String:
	var prefix := shell.screenshot_path if shell.screenshot_path != "" else fallback
	shell.screenshot_path = ""
	return prefix


func _wait_for_main_menu() -> void:
	var polls := 0
	while (shell.top() == null or shell.top().id != EsShell.MAIN_MENU or shell.busy) and polls < BOOT_POLL_LIMIT:
		await _tree().create_timer(BOOT_POLL).timeout
		polls += 1
		if polls % BOOT_SKIP_EVERY == 0:
			tap_action("ui_accept")


## --shell=hangar-test --screenshot=<dir/prefix>: hub -> ARMING (the app's Hangar screen over the
## shell): builds the first Herc on offer, arms its first hardpoint with a counted weapon when there
## is one, prints the garage, closes; then BUILD on the post-debrief hub. A window shot per step.
func run_hangar_test() -> void:
	var prefix := _take_prefix("user://hangar_test")
	apply_test_career(EsShell.HANGAR_HUB)
	shell.set_region(EsShell.MAIN_MENU)
	shell.goto_menu(EsShell.HANGAR_HUB)
	await _tree().create_timer(0.5).timeout
	await snap(prefix + "_1_hub.png")
	click(shell.top().find(ARMING_BUTTON).r.get_center())
	await _tree().create_timer(1.0).timeout
	await snap_window(prefix + "_2_hangar.png")
	var screen := _open_hangar_screen()
	print("hangar-test: hangar open %s, %d Hercs, stock %s" % [screen != null, screen.garage.vehicles.size() if screen else 0,
		screen.garage.stock if screen else {}])
	if screen:
		screen.call("_build_selected_type")
		await _tree().create_timer(0.6).timeout
		await snap_window(prefix + "_3_built.png")
		print("hangar-test: after BUILD %d Hercs, selected %s" % [screen.garage.vehicles.size(), screen.garage.selected_entry().vehicle])
		screen.back_button.pressed.emit()
	await _tree().create_timer(0.4).timeout
	print("hangar-test: closed %s, saved Hercs %d" % [not shell.hangar.is_open(),
		(EsShell.career.campaign_state.garage.vehicles as Array).size()])
	shell.goto_menu(EsShell.HANGAR_HUB_DEBRIEFED)
	await _tree().create_timer(0.3).timeout
	click(shell.top().find(BUILD_BUTTON).r.get_center())
	await _tree().create_timer(0.6).timeout
	print("hangar-test: BUILD opens the hangar %s" % shell.hangar.is_open())
	_tree().quit()


func _open_hangar_screen() -> HangarScreen:
	for c in shell.get_children():
		if c is HangarRouter:
			return (c as HangarRouter).current as HangarScreen
	return null


static func report_scene_and_quit() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	print("autotest: after MULTIPLAYER current scene = ", tree.current_scene.name, " multiplayer_only=",
		tree.current_scene.get("multiplayer_only"))
	tree.quit()


# ------------------------------------------------------------------ synthetic input

## Presses and releases input action `action`.
static func tap_action(action: String) -> void:
	for p in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = p
		Input.parse_input_event(ev)


## Types `text` into the focused edit box (characters, not bindings).
static func _type_text(text: String) -> void:
	for ch in text:
		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = OS.find_keycode_from_string(ch)
		ev.unicode = ch.unicode_at(0)
		Input.parse_input_event(ev)


## Moves the cursor to virtual point `v` and clicks (ui_click is bound to the left button). The events are in the window's
## own pixels, like the OS's: the window turns them into viewport coordinates (the UI scale setting, content_scale_factor)
## before ShellScreen sees them, so the viewport position of the point goes through the viewport's screen transform.
func click(v: Vector2i) -> void:
	var w: Vector2 = shell.get_viewport().get_screen_transform() * shell.screen.to_window(v)
	var mv := InputEventMouseMotion.new()
	mv.position = w
	Input.parse_input_event(mv)
	for p in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = p
		ev.position = w
		Input.parse_input_event(ev)


func snap(path: String) -> void:
	await RenderingServer.frame_post_draw
	_save_snapshot(path)


## The whole window (app screens over the shell included).
func snap_window(path: String) -> void:
	await RenderingServer.frame_post_draw
	shell.get_viewport().get_texture().get_image().save_png(path)


func _save_snapshot(path: String) -> void:
	var img := shell.screen.snapshot()
	img.resize(SNAPSHOT_SIZE.x, SNAPSHOT_SIZE.y, Image.INTERPOLATE_NEAREST)
	img.save_png(path)
