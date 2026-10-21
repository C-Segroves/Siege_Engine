extends Node
## QA end-to-end driver: plays the app the way a player would (clicks / input actions on the real
## screens) and survives scene changes by living under the tree root.
##   Godot --path game --audio-driver Dummy res://tests/e2e_driver.tscn -- --flow=<flow> --shots=<dir>
## Flows: library | es1_shell | es2 | starsiege_human | starsiege_cybrid | saga | skirmish | gamepad
##        | coop_host / coop_join (with --autohost / --autojoin args for the launcher)
##        | pause [--mapname= --veh=] (in-battle menu, leave, results, rematch)
##        | abort --game=es1|es2|starsiege|starsiege-cybrid (abort a campaign mission from the menu)
##        | continue [--expect_pack=es2] | lan_host / lan_join [--mode=vs|team_vs|coop|campaign] [--leave=host|client]
##        | lobby_host / lobby_join: the same LAN match through the standard lobby (the host opens it with its default
##          settings at once, no host page; the client reads the host's options as text, readies and plays)
##          [--bots=<n> on the host: infantry bots, a thrown grenade and a client gunner seat over the LAN]
##          [--transport=ws on lan_join: joins ws://127.0.0.1:<--port=47700> (a WebSocket server) instead of discovering
##           an ENet host; --dedicated: the server has no host pilot (res://tests/server_ws_check.tscn plays it)]
##        | extraction_host / extraction_join (both with -- --extraction-fast): a LAN raid, both loot, the client
##          extracts (his stash gets the haul), the host is killed; saves and profiles are kept
## Every match ends on the results screen (MatchResults); pass_results() checks it and presses Continue.
## Prints "E2E: ..." progress, "E2E FAIL: ..." problems and "E2E DONE <n> failures" at the end.

const STEP := 0.4
## The vehicle the LAN extraction client has bought and calls in (a call-in, not a starter vehicle: it can be at risk).
const CALLIN_VEHICLE := "es1:RAPTOR"
const CALLIN_POD_SECONDS := 120.0
const CALLIN_VEHICLE_SECONDS := 240.0
const CALLIN_START_POINTS := 5000
const CALLIN_RINGS_M := [12.0, 24.0, 40.0, 60.0, 90.0, 130.0, 170.0, 210.0]
const CALLIN_DIRECTIONS := 12
const CALLIN_ANSWER_SECONDS := 1.5
## The mission ender's verdict grace plus its closing voice prompt (MissionEnder.VOICE_WAIT_MAX): a co-op match ends this long
## after the last enemy dies (it measured about 15 s).
const MISSION_END_SECONDS := 30.0
const MOVIE_START_MSEC := 2500
const MOVIE_NEXT_MSEC := 600
const MOVIE_ROUNDS := 6

var flow := ""
var shots := ""
var fails := 0
var _t0 := 0


func _ready() -> void:
	flow = _arg("flow")
	shots = _arg("shots")
	_t0 = Time.get_ticks_msec()
	_run.call_deferred()


var _last_scene := ""


func _process(_d: float) -> void:
	var n := scene_name() + "/" + screen()
	if n != _last_scene:
		_last_scene = n
		log_line("scene -> %s" % n)


func _arg(n: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % n):
			return a.substr(n.length() + 3)
	return ""


func _has(n: String) -> bool:
	return OS.get_cmdline_user_args().has("--" + n)


func _run() -> void:
	# become a root child that outlives scene changes
	var tree := get_tree()
	tree.current_scene = null
	match flow:
		"library":
			await flow_library()
		"es1_shell":
			await flow_es1_shell()
		"es2":
			await flow_campaign("es2", 2)
		"starsiege_human":
			await flow_campaign("starsiege", 1)
		"starsiege_cybrid":
			await flow_campaign("starsiege-cybrid", 1)
		"es1_launcher":
			await flow_campaign("es1", 2)
		"saga":
			await flow_saga()
		"skirmish":
			await flow_skirmish()
		"gamepad":
			await flow_gamepad()
		"battle":
			await flow_battle()
		"pause":
			await flow_pause()
		"abort":
			await flow_abort()
		"continue":
			open_scene("res://launcher.tscn")
			await wait_screen("menu")
			await wait(0.8)
			var cb := find_button("Continue campaign")
			log_line("Continue campaign offered: %s; Session.campaign=%s saga=%s" % [cb != null, Session.campaign, Session.saga])
			if cb:
				await click(cb, "Continue")
				await wait(1.5)
				log_line("continue -> screen '%s' heading %s campaign script %s" % [screen(), MatchFlow.make_mission_heading() if Session.campaign else "-", Session.campaign.get_script().resource_path if Session.campaign else "-"])
				if _arg("expect_pack") != "" and Session.campaign:
					expect(Session.campaign.pack_id() == _arg("expect_pack"), "Continue campaign resumes the %s campaign (got %s)" % [_arg("expect_pack"), Session.campaign.pack_id()])
					expect(not str(Session.briefing().get("briefing", "")).is_empty(), "the continued lobby's briefing has its text")
				await shot("continue")
				await click_text("Start mission")
				if await wait_scene_class("Battle", 40):
					await wait(3.0)
					log_line("continued battle: %s mission=%s" % [describe_battle(battle()), battle().config.get("mission", {}).get("name", battle().config.get("mission", {}).get("id", "?")) if battle().config.get("mission") is Dictionary else battle().config.get("mission")])
					if _arg("expect_pack") != "":
						var mpack := str(battle().config.get("mission", {}).get("pack", "es1")) if battle().config.get("mission") is Dictionary else "es1"
						var is_ss := battle().mission is StarsiegeMissionRuntime
						expect((is_ss and _arg("expect_pack") == "starsiege") or mpack == _arg("expect_pack"), "the continued battle plays a %s mission (pack %s)" % [_arg("expect_pack"), mpack])
					await shot("continue_battle")
		"coop_host", "coop_join":
			await flow_coop()
		"lan_host", "lan_join", "lobby_host", "lobby_join":
			var guard := SavedGuard.new()   # the lobby saves the pilot name (PlayerProfile)
			guard.back_up()
			await flow_lan()
			guard.restore()
		"extraction_host", "extraction_join":
			await flow_extraction()
		_:
			fail("unknown flow '%s'" % flow)
	log_line("DONE %d failures (%.0f s)" % [fails, (Time.get_ticks_msec() - _t0) / 1000.0])
	print("E2E DONE %d failures" % fails)
	get_tree().quit(1 if fails > 0 else 0)


# ------------------------------------------------------------------ helpers

func log_line(s: String) -> void:
	print("E2E: [%6.1f] %s" % [(Time.get_ticks_msec() - _t0) / 1000.0, s])


func fail(s: String) -> void:
	fails += 1
	print("E2E FAIL: ", s)


func expect(ok: bool, s: String) -> bool:
	if ok:
		log_line("ok   " + s)
	else:
		fail(s)
	return ok


func wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func frames(n := 2) -> void:
	for i in n:
		await get_tree().process_frame


## Waits until `cond` returns true (or `timeout` seconds). Returns whether it did.
func wait_for(cond: Callable, timeout := 20.0, what := "") -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > int(timeout * 1000.0):
			if what != "":
				fail("timeout (%.0f s) waiting for %s" % [timeout, what])
			return false
		await get_tree().process_frame
	return true


func shot(name: String) -> void:
	if shots == "":
		return
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var p := shots.path_join(flow + "_" + name + ".png")
	img.save_png(p)
	log_line("shot " + p)


func cur() -> Node:
	return get_tree().current_scene


func scene_name() -> String:
	var c := cur()
	return str(c.name) if c else "<none>"


func open_scene(path: String) -> Node:
	var n: Node = load(path).instantiate()
	get_tree().root.add_child(n)
	get_tree().current_scene = n
	return n


## The router's screen name (library / launcher), "" otherwise.
func screen() -> String:
	var c := cur()
	if c is ScreenRouter:
		return (c as ScreenRouter).current_name
	return ""


func wait_screen(n: String, timeout := 20.0) -> bool:
	return await wait_for(func() -> bool: return screen() == n, timeout, "screen '%s' (at scene %s screen '%s')" % [n, scene_name(), screen()])


func wait_scene_class(cls: String, timeout := 60.0) -> bool:
	return await wait_for(func() -> bool: return cur() != null and cur().get_class() != "" and _is(cur(), cls), timeout,
		"scene %s (now %s)" % [cls, scene_name()])


func _is(n: Node, cls: String) -> bool:
	match cls:
		"Battle":
			return n is Battle
		"Launcher":
			return n is Launcher
		"Library":
			return n is Library
		"EsShell":
			return n is EsShell
		"MatchResults":
			return n is MatchResults
	return false


func all_controls(root: Node, out: Array) -> Array:
	for c in root.get_children():
		if c is Control:
			out.append(c)
		all_controls(c, out)
	return out


## First visible button under the current scene whose text contains `text` (case-insensitive).
func find_button(text: String, root: Node = null) -> BaseButton:
	var r := root if root else get_tree().root
	for c in all_controls(r, []):
		if c is BaseButton and c.is_visible_in_tree() and str(c.get("text")).to_lower() == text.to_lower():
			return c
	for c in all_controls(r, []):
		if c is BaseButton and c.is_visible_in_tree() and str(c.get("text")).to_lower().contains(text.to_lower()):
			return c
	return null


## Skips the movies playing (a click or key press would be eaten by them): the campaign briefing and debriefing movies.
func skip_movies() -> void:
	var wait_msec := MOVIE_START_MSEC
	for round in MOVIE_ROUNDS:   # a skip starts the next movie of the list
		var t0 := Time.get_ticks_msec()
		while get_tree().root.find_children("*", "MoviePlayer", true, false).is_empty() and Time.get_ticks_msec() - t0 < wait_msec:
			await frames(5)   # a movie may still be loading
		var movies := get_tree().root.find_children("*", "MoviePlayer", true, false)
		if movies.is_empty():
			return
		for n in movies:
			n.call("_done")
		wait_msec = MOVIE_NEXT_MSEC
		await frames(5)


func list_buttons() -> String:
	var t: PackedStringArray = []
	for c in all_controls(get_tree().root, []):
		if c is BaseButton and c.is_visible_in_tree():
			t.append("'%s'%s" % [str(c.get("text")), "(disabled)" if c.disabled else ""])
	return ", ".join(t)


## Clicks a control with real mouse events (scrolling it into view first). Falls back to emitting
## `pressed` (reported) when the click did not reach it.
func click(c: Control, what := "") -> bool:
	if c == null:
		fail("click: no control %s; buttons: %s" % [what, list_buttons()])
		return false
	var sc := _scroll_parent(c)
	if sc:
		await frames(2)
		sc.ensure_control_visible(c)
		await frames(3)
	var got := [false]
	var cb := func() -> void: got[0] = true
	if c is BaseButton:
		(c as BaseButton).pressed.connect(cb)
	var pos := c.get_global_rect().get_center()
	var vp := c.get_viewport()
	var xf := vp.get_final_transform()
	var wpos := xf * pos
	var mv := InputEventMouseMotion.new()
	mv.position = wpos
	mv.global_position = wpos
	Input.parse_input_event(mv)
	await frames(1)
	for p in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = p
		ev.position = wpos
		ev.global_position = wpos
		Input.parse_input_event(ev)
		await frames(1)
	await frames(2)
	if not is_instance_valid(c):
		return true
	if c is BaseButton:
		if (c as BaseButton).pressed.is_connected(cb):
			(c as BaseButton).pressed.disconnect(cb)
		if not got[0] and not (c is OptionButton) and not (c is CheckBox):
			fail("mouse click did not press '%s' at %s (%s); pressing directly" % [str(c.get("text")), wpos, what])
			if c is BaseButton and not (c as BaseButton).disabled:
				(c as BaseButton).pressed.emit()
			return false
	return true


func click_text(text: String) -> bool:
	var b := find_button(text)
	if b == null:
		fail("no button '%s' on %s/%s; buttons: %s" % [text, scene_name(), screen(), list_buttons()])
		return false
	if b.disabled:
		fail("button '%s' is disabled" % text)
		return false
	log_line("click '%s'" % str(b.get("text")))
	return await click(b, text)


func _scroll_parent(c: Node) -> ScrollContainer:
	var p := c.get_parent()
	while p:
		if p is ScrollContainer:
			return p
		p = p.get_parent()
	return null


func tap(action: String) -> void:
	for p in [true, false]:
		var ev := InputEventAction.new()
		ev.action = action
		ev.pressed = p
		ev.strength = 1.0 if p else 0.0
		Input.parse_input_event(ev)
		await frames(1)
	await frames(2)


func pad_button(b: JoyButton) -> void:
	for p in [true, false]:
		var ev := InputEventJoypadButton.new()
		ev.button_index = b
		ev.pressed = p
		ev.device = 0
		Input.parse_input_event(ev)
		await frames(1)
	await frames(3)


func pad_axis(axis: JoyAxis, v: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = v
	ev.device = 0
	Input.parse_input_event(ev)
	await frames(1)


func focus_text() -> String:
	var f := get_viewport().gui_get_focus_owner()
	if f == null:
		return "<none>"
	return "%s '%s'" % [f.get_class(), str(f.get("text"))]


# ------------------------------------------------------------------ battle helpers

func battle() -> Battle:
	return cur() as Battle


func describe_battle(b: Battle) -> String:
	var vs := []
	for id in b.vehicles:
		var v = b.vehicles[id]
		if is_instance_valid(v):
			vs.append("%s[%s team %d %s]" % [v.display_name, v.vehicle_id, v.team, "alive" if v.alive else "dead"])
	return "mode=%s player=%s vehicles=%d: %s" % [b.config.get("mode"), b.player.vehicle_id if b.player else "<none>",
		vs.size(), ", ".join(PackedStringArray(vs.slice(0, 12)))]


## Kills every hostile unit / structure the normal way (damage from the player) for up to `sec`
## seconds; then forces the mission's success when it still runs. Returns the battle result.
func win_battle(b: Battle, sec := 25.0) -> Dictionary:
	var player: Herc = b.player
	var t := Time.get_ticks_msec()
	var natural := false
	while not b.is_over() and Time.get_ticks_msec() - t < int(sec * 1000.0):
		if player and is_instance_valid(player) and player.alive:
			player.shield_front = player.shield_max
			player.shield_rear = player.shield_max
			for c in player.components:
				c.hp = c.max
			if b.mission and b.mission.get("regions") is Array:
				for ri in (b.mission.regions as Array).size():
					b.mission.fire_region(ri)
			for v in get_tree().get_nodes_in_group("vehicles"):
				if is_instance_valid(v) and v.team != player.team and v.alive:
					v.apply_hit(1e6, 1e6, player, v.global_position)
			if b.mission and b.mission.get("structures") is Array:
				for st in b.mission.structures:
					if is_instance_valid(st) and st.team != player.team and st.alive:
						st.destroy(player)
			_step_to_next_nav(b, player)
		for i in 10:
			await get_tree().physics_frame
		natural = b.is_over()
	if not b.is_over():
		log_line("mission did not end by destroying hostiles / nav in %.0f s: forcing success" % sec)
		if b.mission and b.mission.has_method("debrief") and b.mission is StarsiegeMissionRuntime:
			b.mission.debrief(true, "QA forced success")
		elif b.mission:
			b.mission.end_mission(true, 2, "QA forced success")
		else:
			b.end_match("QA forced end")
	else:
		log_line("mission ended naturally after the hostiles were destroyed")
	log_line("battle result: success=%s salvage=%s natural=%s" % [b.result.get("success"), b.result.get("salvage"), natural])
	return b.result


## Puts `player` on the mission's next unvisited nav point (no-op when there is none).
func _step_to_next_nav(b: Battle, player: Herc) -> void:
	if b.mission and b.mission.get("nav_points") is Array and b.mission.nav_index < b.mission.nav_points.size():
		player.global_position = b.mission.nav_points[b.mission.nav_index] + Vector3.UP * 2.0


## Walks `player` through the mission's remaining nav points. Earthsiege nav missions (mission types 1 / 2 /
## 7: "player group reached the end of its path", mission.md section 5) end there, not when the enemies die.
func visit_remaining_navs(b: Battle, player: Herc, timeout := 30.0) -> void:
	var t := Time.get_ticks_msec()
	while _navs_left(b) > 0 and not b.is_over() and Time.get_ticks_msec() - t < int(timeout * 1000.0):
		_step_to_next_nav(b, player)
		for i in 10:
			await get_tree().physics_frame
	log_line("nav points left: %d" % _navs_left(b))


static func _navs_left(b: Battle) -> int:
	if b.mission == null or not (b.mission.get("nav_points") is Array):
		return 0
	return maxi(b.mission.nav_points.size() - int(b.mission.nav_index), 0)


## Drives forward a moment and checks the player moved / legs animate.
func check_player_moves(b: Battle, sec := 2.5) -> void:
	var p := b.player
	if p == null:
		fail("battle has no player vehicle (%s)" % describe_battle(b))
		return
	var p0 := p.global_position
	# A soldier reads the movement input every frame (the new spawn path starts a pilot on foot beside his Herc);
	# a Herc keeps the throttle lever where it is put.
	Input.action_press("throttle_up")
	p.throttle = 0.8
	await wait(sec)
	var d := p.global_position.distance_to(p0)
	expect(d > 1.0, "player %s moved %.1f m in %.1f s (speed %.1f)" % [p.vehicle_id, d, sec, p.speed])
	Input.action_release("throttle_up")
	p.throttle = 0.0


func log_errors_marker(tag: String) -> void:
	print("E2E-MARK ", tag)


# ------------------------------------------------------------------ flow: library

func flow_library() -> void:
	var lib := open_scene("res://library.tscn")
	await wait_screen("home")
	await wait(1.0)
	await shot("01_home")
	await click_text("Your library")   # imports, game cards, soundtracks
	# pack toggle (click the first content check box twice)
	var cb: CheckBox = null
	for c in all_controls(lib, []):
		if c is CheckBox and c.is_visible_in_tree():
			cb = c
			break
	if expect(cb != null, "library has pack content toggles"):
		var before := cb.button_pressed
		log_line("toggle '%s' (was %s)" % [cb.text, before])
		await click(cb, "pack toggle")
		await frames(3)
		expect(cb.button_pressed != before, "pack toggle flips on click")
		var pilotable_after := Packs.pilotable().size()
		await shot("02_toggled")
		await click(cb, "pack toggle back")
		await frames(3)
		expect(cb.button_pressed == before, "pack toggle flips back")
		log_line("pilotable after toggle %d, now %d" % [pilotable_after, Packs.pilotable().size()])
	# jukebox
	var sb := find_button("(")   # a soundtrack button "Name (n)"
	var juke: BaseButton = null
	for c in all_controls(lib, []):
		if c is Button and c.is_visible_in_tree() and str(c.text).contains("(") and _scroll_parent(c) and c.get_parent() is HFlowContainer:
			juke = c
			break
	if expect(juke != null, "a soundtrack button is listed"):
		await click(juke, "soundtrack")
		await wait_screen("jukebox", 5)
		await wait(0.5)
		var track := find_button("[game]")
		if track == null:
			track = find_button("[")
		if expect(track != null, "jukebox lists tracks"):
			await click(track, "track")
			await wait(1.5)
			await shot("03_jukebox_playing")
			await click_text("Stop")
		await click_text("Back to library")
		await wait_screen("home", 5)
	# options: volume + rebind
	await click_text("Options & tools")
	var opt := find_button("Options", lib.current)
	await click(opt, "Options")
	if await wait_screen("options", 5):
		await wait(0.3)
		var sliders := all_controls(lib, []).filter(func(c): return c is HSlider and c.is_visible_in_tree())
		if expect(sliders.size() >= 2, "options has volume sliders"):
			var s: HSlider = sliders[0]
			var v0 := s.value
			s.grab_focus()
			await frames(2)
			await tap("ui_left")
			await tap("ui_left")
			log_line("master volume %s -> %s (bus db %.1f)" % [v0, s.value, AudioServer.get_bus_volume_db(0)])
			expect(s.value < v0, "ui_left lowers master volume")
		var b := find_button("Q")   # throttle stop binding shows "X, Pad LS click"
		var target: Button = null
		for c in all_controls(lib, []):
			if c is Button and c.is_visible_in_tree() and str(c.text).begins_with("X"):
				target = c
				break
		if expect(target != null, "throttle stop binding button found"):
			await click(target, "binding")
			await frames(2)
			await shot("04_capture")
			var k := InputEventKey.new()
			k.keycode = KEY_Z
			k.physical_keycode = KEY_Z
			k.pressed = true
			Input.parse_input_event(k)
			await frames(2)
			k = k.duplicate()
			k.pressed = false
			Input.parse_input_event(k)
			await frames(3)
			# Z already belongs to the torso-center action: the screen asks Swap / Clear / Cancel; Swap gives Z to throttle_stop
			if expect(find_button("Swap") != null, "binding Z, which another action uses, asks Swap / Clear / Cancel"):
				await click_text("Swap")
				await frames(3)
			var evs := InputMap.action_get_events("throttle_stop")
			var txt := []
			for e in evs:
				txt.append(e.as_text())
			log_line("throttle_stop events now: %s; button '%s'" % [txt, target.text])
			expect(str(txt).contains("Z"), "rebind throttle_stop to Z")
			await shot("05_rebound")
			await click_text("Reset all to defaults")
			await frames(3)
			await shot("06_reset_dialog")
			var confirm := find_button("Reset")
			# the dialog's confirm button is the last "Reset" button
			var resets := all_controls(get_tree().root, []).filter(func(c): return c is Button and c.is_visible_in_tree() and c.text == "Reset")
			if expect(not resets.is_empty(), "reset confirm dialog shown"):
				await click(resets[-1], "Reset confirm")
				await frames(3)
				var evs2 := InputMap.action_get_events("throttle_stop").map(func(e): return e.as_text())
				expect(not str(evs2).contains("Z"), "reset restores throttle_stop (%s)" % [evs2])
		await click_text("Back")
		await wait_screen("home", 5)
	await wait(0.3)   # the home page lays itself out
	# quit confirm: cancel, then confirm
	await click_text("Quit")
	await frames(3)
	await shot("07_quit_dialog")
	var cancel := find_button("Cancel")
	if expect(cancel != null, "quit asks for confirmation"):
		await click(cancel, "Cancel")
		await frames(3)
		expect(find_button("Cancel") == null, "Cancel closes the quit dialog")
	# Host LAN game (the primary button) routes to the launcher
	await click_text("Host LAN game")
	await wait_scene_class("Launcher", 10)
	await wait(0.5)
	log_line("arena/versus opened launcher screen '%s'" % screen())
	await shot("08_arena_versus")
	expect(screen() == "lobby", "Host LAN game opens the standard lobby (%s)" % screen())
	await click_text("Leave")   # the lobby was the first page: Leave goes to the front end, the library
	await wait_scene_class("Library", 10)
	await wait(1.0)
	log_line("Leave from the lobby -> scene %s" % scene_name())
	if cur() is Library:
		await click_text("Quit")
		await frames(3)
		var qs := all_controls(get_tree().root, []).filter(func(c): return c is Button and c.is_visible_in_tree() and c.text == "Quit")
		log_line("pressing the dialog's Quit: the app should exit now")
		await click(qs[-1], "Quit confirm")
		await wait(2.0)
		fail("app still running 2 s after confirming Quit")
	else:
		fail("launcher Back did not return to the library (scene %s)" % scene_name())


# ------------------------------------------------------------------ flow: ES1 original shell

func shell_node() -> EsShell:
	return cur() as EsShell


func shell_menu() -> int:
	var s := shell_node()
	return s.top().id if s and s.top() else -1


func shell_dump() -> String:
	var s := shell_node()
	if s == null or s.top() == null:
		return "<no menu>"
	var ids := []
	for c in s.top().controls:
		ids.append("%s:%s" % [c.get("id"), str(c.get("text", "")).left(16)])
	return "menu %d: %s" % [s.top().id, ", ".join(PackedStringArray(ids))]


func shell_click(cid: int) -> bool:
	var s := shell_node()
	if s == null or s.top() == null:
		fail("shell_click %d: no shell menu" % cid)
		return false
	var c: Dictionary = s.top().find(cid)
	if c.is_empty():
		fail("shell control %d not on %s" % [cid, shell_dump()])
		return false
	log_line("shell click %d on menu %d" % [cid, s.top().id])
	s.debug.click(c.r.get_center())
	await wait(0.6)
	return true


func shell_wait_menu(mid: int, timeout := 60.0) -> bool:
	return await wait_for(func() -> bool:
		var s := shell_node()
		if s and s.busy and Engine.get_process_frames() % 20 == 0:
			ShellDebug.tap_action("ui_accept")   # skip talking heads / cinematics
		return s != null and s.top() != null and s.top().id == mid and not s.busy, timeout,
		"shell menu %d (now %d, scene %s)" % [mid, shell_menu(), scene_name()])


func flow_es1_shell() -> void:
	var lib := open_scene("res://library.tscn")
	await wait_screen("home")
	await wait(1.0)
	# the library no longer offers the original shell; open it directly (developer / test path)
	Session.front_end = "res://es1_shell.tscn"
	get_tree().change_scene_to_file("res://es1_shell.tscn")
	await wait_scene_class("EsShell", 20)
	await wait(1.0)
	await shot("01_boot")
	if not await shell_wait_menu(EsShell.MAIN_MENU, 120):
		return
	await shot("02_main")
	log_line(shell_dump())
	var resume := _has("resume")
	if resume:
		# load the saved career: CAREER -> list -> PROCEED
		await shell_click(EsShell.HANGAR_HUB)
		await wait(3.0)
		log_line("main 1700 without a selected career -> %s" % shell_dump())
		if shell_menu() != EsShell.CAREER_MENU:
			await shell_click(EsShell.CAREER_MENU)
			await shell_wait_menu(EsShell.CAREER_MENU, 10)
		var sh := shell_node()
		var lst: Dictionary = sh.top().find(1202)
		log_line("career list items: %s" % [lst.get("items", [])])
		var idx := -1
		for i in sh.careers.list.size():
			if sh.careers.list[i].name == "QATEST":
				idx = i
		if idx >= 0:
			lst.sel = idx
			sh.commands.select(sh.top(), lst)
			await shot("R0_career_selected")
			log_line("selected career %s" % EsShell.career.get("name"))
			await shell_click(EsShell.HANGAR_HUB)
			await shell_wait_menu(EsShell.HANGAR_HUB, 120)
			var g: Garage = sh.hangar.career_campaign().garage
			log_line("resumed QATEST: next %s garage %s" % [EsShell.career.get("next_mission"), g.vehicles.map(func(e): return "%s %s" % [e.vehicle, e.loadout])])
			await shot("R2_hub_resumed")
		log_line("careers loaded: %s" % [sh.careers.list.map(func(c): return "%s missions=%s next=%s" % [c.name, c.get("missions"), c.get("next_mission")])])
		await shot("R1_career_menu")
		return
	await shell_click(EsShell.CAREER_MENU)
	await wait(0.6)
	log_line(shell_dump())
	await shell_click(EsShell.REGISTER_MENU)
	await wait(0.6)
	ShellDebug._type_text("QATEST")
	await wait(0.3)
	await shot("03_register")
	ShellDebug.tap_action("ui_accept")
	await wait(0.8)
	log_line("career after register: %s" % EsShell.career.get("name", "<none>"))
	log_line(shell_dump())
	expect(EsShell.career.get("name", "") == "QATEST", "new career QATEST created")
	await shot("04_career")
	# PROCEED (hub id 1700 on the career menu)
	await shell_click(EsShell.HANGAR_HUB)
	if not await shell_wait_menu(EsShell.HANGAR_HUB, 180):
		return
	await shot("05_hub")
	log_line(shell_dump())
	# ARMING -> app hangar
	await shell_click(ShellDebug.ARMING_BUTTON)
	await wait(1.0)
	var hs := _find_hangar_screen()
	if expect(hs != null, "ARMING opens the Hangar screen"):
		await shot("06_hangar")
		var n0 := hs.garage.vehicles.size()
		var built := find_button("Build")
		# "Build" section header button vs primary: press the primary Build button
		for c in all_controls(hs, []):
			if c is Button and c.text == "Build" and c.is_visible_in_tree():
				built = c
		await click(built, "Build")
		await wait(0.6)
		log_line("garage %d -> %d Hercs; status '%s'" % [n0, hs.garage.vehicles.size(), _status(hs)])
		expect(hs.garage.vehicles.size() == n0 + 1, "Build adds a Herc")
		await shot("07_built")
		# arm: pick a different weapon on the first hardpoint via its OptionButton
		var obs := all_controls(hs, []).filter(func(c): return c is OptionButton and c.is_visible_in_tree())
		log_line("option buttons: %d" % obs.size())
		var lo0: Array = hs.garage.selected_entry().loadout.duplicate()
		for ob in obs:
			var o := ob as OptionButton
			if o.item_count > 1 and o.get_parent() and o.get_parent().get_parent() is LoadoutEditor:
				var pick := (o.selected + 1) % o.item_count
				o.select(pick)
				o.item_selected.emit(pick)
				break
		await wait(0.4)
		log_line("loadout %s -> %s" % [lo0, hs.garage.selected_entry().loadout])
		expect(str(lo0) != str(hs.garage.selected_entry().loadout), "arming changes the selected Herc's loadout")
		await shot("08_armed")
		# scrap the new Herc
		await click_text("Scrap this Herc")
		await frames(3)
		var sc := all_controls(get_tree().root, []).filter(func(c): return c is Button and c.is_visible_in_tree() and c.text == "Scrap")
		if expect(not sc.is_empty(), "scrap asks for confirmation"):
			await shot("09_scrap_dialog")
			await click(sc[-1], "Scrap confirm")
			await wait(0.4)
			expect(hs.garage.vehicles.size() == n0, "Scrap removes the Herc (%d)" % hs.garage.vehicles.size())
		await click(hs.back_button, "hangar Back")
		await wait(0.6)
	log_line(shell_dump())
	await shot("10_hub_back")
	# BEGIN MISSION (OK on the hub)
	await shell_click(EsShell.OK_ID)
	await wait(1.0)
	if shell_menu() == 3000:
		log_line("unarmed warning shown; accepting")
		await shell_click(EsShell.OK_ID)
	if not await wait_scene_class("Battle", 90):
		return
	var b := battle()
	await wait(2.0)
	log_line(describe_battle(b))
	await shot("11_battle")
	await check_player_moves(b)
	await shot("12_battle_moving")
	var r := await win_battle(b)
	await wait(1.5)
	await shot("13_mission_end")
	expect(bool(r.get("success", false)), "mission won")
	await pass_results("es1_career")
	# back to the shell debriefing
	if not await wait_scene_class("EsShell", 40):
		return
	if not await shell_wait_menu(EsShell.CAREER_DEBRIEF_MENU, 120):
		return
	await shot("14_debrief")
	log_line(shell_dump())
	log_line("career after mission 1: missions=%s next=%s campaign_state.mission=%s" % [EsShell.career.get("missions"),
		EsShell.career.get("next_mission"), str(EsShell.career.get("campaign_state", {}).get("mission", "?"))])
	# leave the debriefing -> hub (debriefed) -> next mission
	await shell_click(EsShell.HANGAR_HUB_DEBRIEFED)
	await wait(1.0)
	log_line(shell_dump())
	await shot("15_after_debrief")
	if shell_menu() != EsShell.HANGAR_HUB_DEBRIEFED:
		await shell_wait_menu(EsShell.HANGAR_HUB_DEBRIEFED, 30)
	await shell_click(1499)
	if not await shell_wait_menu(EsShell.HANGAR_HUB, 180):
		return
	await shot("16_hub_mission2")
	log_line("next mission: %s" % EsShell.career.get("next_mission"))
	await shell_click(EsShell.OK_ID)
	await wait(1.0)
	if shell_menu() == 3000:
		await shell_click(EsShell.OK_ID)
	if await wait_scene_class("Battle", 90):
		await wait(2.0)
		log_line(describe_battle(battle()))
		await shot("17_battle2")
	expect(SaveGames.exists(ShellCareers.autosave_id("QATEST")), "career QATEST saved as its pilot's autosave (SaveGames)")


func _find_hangar_screen() -> HangarScreen:
	for c in all_controls(get_tree().root, []):
		if c is HangarScreen:
			return c
	return null


# ------------------------------------------------------------------ flow: launcher campaigns

## Campaign lobby -> hangar (build) -> Start mission -> win -> debrief -> continue, `missions` times.
func flow_campaign(game: String, missions: int) -> void:
	if game == "es1":
		open_scene("res://launcher.tscn")
		await wait_screen("menu")
		await click_text("Metaltech: Earthsiege campaign")
	else:
		var l := open_scene("res://launcher.tscn") as Launcher
		await wait_screen("menu")
		LauncherAutomation._start_campaign_of(game)
		l.show_started_campaign()
	if not await wait_screen("lobby", 30):
		return
	for k in missions:
		await campaign_mission(k + 1)
		if fails > 6:
			return


func campaign_mission(k: int) -> void:
	await wait(1.5)
	var heading := MatchFlow.make_mission_heading()
	var ctx0 := Session.availability_context()
	var g := Session.garage()
	log_line("lobby %d: %s; garage %s; mission herc %s" % [k, heading, g.vehicles.map(func(e): return e.vehicle) if g else "-", Session.mission_herc()])
	log_line("availability: unlocked_vehicles=%s stock=%s" % [ctx0.get("unlocked_vehicles", []).size() if ctx0.get("unlocked_vehicles") is Array else "?", ctx0.get("salvage_stock", {})])
	await shot("m%d_01_lobby" % k)
	if k == 1:
		await click_text("Hangar")
		if await wait_screen("hangar", 5):
			await wait(1.0)
			await shot("m%d_02_hangar" % k)
			var hs := cur().current as HangarScreen
			var n0 := hs.garage.vehicles.size()
			for c in all_controls(hs, []):
				if c is Button and c.text == "Build" and c.is_visible_in_tree():
					await click(c, "Build")
					break
			await wait(0.5)
			log_line("build: %d -> %d Hercs, status '%s'" % [n0, hs.garage.vehicles.size(), _status(hs)])
			expect(hs.garage.vehicles.size() > n0 or _status(hs) != "", "Build adds a Herc or explains why not")
			await shot("m%d_03_built" % k)
			await click(hs.primary_button, "Back to lobby")
			await wait_screen("lobby", 5)
			await wait(0.8)
			await shot("m%d_04_lobby_back" % k)
	var picker := (cur().current as LobbyScreen).herc_row.picker
	var e: Dictionary = picker.entry() if picker != null else {}
	log_line("launching with %s %s" % [e.get("vehicle"), e.get("loadout")])
	await click_text("Start mission")
	if not await wait_scene_class("Battle", 90):
		return
	var b := battle()
	await wait(3.0)
	log_line(describe_battle(b))
	if not e.is_empty():
		expect(b.player != null and b.player.vehicle_id == str(e.vehicle), "battle player Herc %s == chosen %s" % [b.player.vehicle_id if b.player else "<none>", e.vehicle])
	await shot("m%d_05_battle" % k)
	await check_player_moves(b)
	var r := await win_battle(b)
	await wait(1.0)
	await shot("m%d_06_end" % k)
	await pass_results("m%d" % k)
	if not await wait_screen("debrief", 40):
		return
	await wait(0.5)
	await shot("m%d_07_debrief" % k)
	var stock0: Dictionary = ctx0.get("salvage_stock", {}).duplicate()
	await click_text("Continue")
	await wait(1.0)
	log_line("after continue: screen '%s'" % screen())
	var ctx1 := Session.availability_context()
	log_line("after mission %d: heading %s; stock %s -> %s; unlocked vehicles %s -> %s; salvage %s" % [k,
		MatchFlow.make_mission_heading() if Session.campaign else "-", stock0, ctx1.get("salvage_stock", {}),
		(ctx0.get("unlocked_vehicles", []) as Array).size() if ctx0.get("unlocked_vehicles") is Array else "?",
		(ctx1.get("unlocked_vehicles", []) as Array).size() if ctx1.get("unlocked_vehicles") is Array else "?", r.get("salvage")])
	if r.get("salvage") is Array and not (r.salvage as Array).is_empty():
		var any_added := false
		for w in r.salvage:
			if int(ctx1.get("salvage_stock", {}).get(w, 0)) > int(stock0.get(w, 0)):
				any_added = true
		expect(any_added or ctx1.get("salvage_stock", {}).is_empty(), "salvage %s joins the armory stock" % [r.salvage])
	expect(heading != MatchFlow.make_mission_heading() if Session.campaign else true, "campaign advanced past %s" % heading)


func _status(s: Object) -> String:
	return str(s.call("status_text")) if s and s.has_method("status_text") else ""


# ------------------------------------------------------------------ flow: saga

func flow_saga() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://saves/autosave.json"))
	open_scene("res://launcher.tscn")
	await wait_screen("menu")
	await wait(0.5)
	await click_text("Saga:")
	if not await wait_screen("lobby", 20):
		return
	log_line("saga stage: %s" % Session.saga.stage_name())
	await campaign_mission(1)
	# skip the rest of Earthsiege: win every remaining mission through the campaign's bookkeeping
	var es1_garage := Session.garage().vehicles.map(func(e): return "%s(%s)" % [e.name, e.vehicle])
	log_line("ES1 garage before skipping: %s" % [es1_garage])
	var n := 0
	while Session.saga.stage == 0 and n < 200:
		Session.last_result = {"success": true, "vars": Session.campaign.prepared_vars(), "salvage": []}
		Session.finish_mission()
		n += 1
	log_line("skipped %d ES1 missions; saga stage now %s (%s)" % [n, Session.saga.stage, Session.saga.stage_name()])
	expect(Session.saga.stage == 1, "saga reaches Earthsiege 2 after ES1 victory")
	var es2_garage := Session.garage().vehicles.map(func(e): return "%s(%s)" % [e.name, e.vehicle]) if Session.garage() else []
	log_line("ES2 garage: %s" % [es2_garage])
	var carried := true
	for x in es1_garage:
		if not es2_garage.has(x):
			carried = false
	expect(carried, "ES1 garage carried into ES2 (%s -> %s)" % [es1_garage, es2_garage])
	(cur() as Launcher).show_campaign()
	if not await wait_screen("lobby", 10):
		return
	await campaign_mission(2)
	var es2_g := Session.garage().vehicles.map(func(e): return "%s(%s)" % [e.name, e.vehicle])
	n = 0
	while Session.saga.stage == 1 and n < 200:
		Session.last_result = {"success": true, "vars": Session.campaign.prepared_vars(), "salvage": []}
		Session.finish_mission()
		n += 1
	log_line("skipped %d ES2 missions; saga stage %s needs_choice %s" % [n, Session.saga.stage, Session.saga.needs_choice()])
	(cur() as Launcher).show_campaign()
	if not await wait_screen("saga_choice", 10):
		return
	await wait(0.5)
	await shot("s_choice")
	await click_text("Human campaign")
	if not await wait_screen("lobby", 20):
		return
	var ss_g := Session.garage().vehicles.map(func(e): return "%s(%s)" % [e.name, e.vehicle])
	log_line("Starsiege garage: %s (ES2 had %s)" % [ss_g, es2_g])
	var c2 := true
	for x in es2_g:
		if not ss_g.has(x):
			c2 = false
	expect(c2, "ES2 garage carried into Starsiege")
	await campaign_mission(3)
	# save / continue
	await click_text("Leave")   # the campaign lobby saves and leaves
	await wait_scene_class("Library", 10)   # the main menu (docs/MENU_MAP.md)
	await wait(0.5)
	await shot("s_menu_continue")
	await click_text("Continue campaign")
	await wait(1.0)
	log_line("continue -> screen '%s' stage %s" % [screen(), Session.saga.stage_name() if Session.saga else "<no saga>"])
	expect(screen() == "lobby" and Session.saga != null and Session.saga.stage == 2, "Continue campaign resumes the saga at Starsiege")
	await shot("s_continued")


## On foot (docs/CODING_STANDARDS.md section 2): the left stick strafes (turn_left / turn_right), the right
## stick turns the soldier (aim_left / aim_right).
func gamepad_check_soldier(b: Battle) -> void:
	var s := b.player
	var side := s.global_transform.basis.x
	var p0 := s.global_position
	await pad_axis(JOY_AXIS_LEFT_X, -1.0)
	await wait(1.0)
	await pad_axis(JOY_AXIS_LEFT_X, 0.0)
	var strafe := (s.global_position - p0).dot(side)
	expect(absf(strafe) > 1.0, "on foot: left stick strafes (%.1f m sideways)" % strafe)
	var y0 := s.rotation.y
	var t0 := s.torso_target
	await pad_axis(JOY_AXIS_RIGHT_X, -1.0)
	await wait(1.0)
	await pad_axis(JOY_AXIS_RIGHT_X, 0.0)
	var turned := maxf(absf(s.rotation.y - y0), absf(s.torso_target - t0))
	expect(turned > 0.05, "on foot: right stick turns the soldier (%.2f rad)" % turned)


# ------------------------------------------------------------------ flow: skirmish through the offline lobby

## Menu -> Skirmish: the offline lobby. --mapname= picks the map the way Game Options does; --veh= puts that vehicle on the
## active operator slot (Operator Setup's Herc), parked beside the soldier.
func skirmish_from_menu() -> void:
	await click_text("Host LAN game")   # skirmish is a hosted game alone against the bots
	await wait_screen("lobby", 5)
	await wait(0.8)
	var lobby := (cur() as Launcher).current as LobbyScreen
	if _arg("veh") != "":
		var profile := lobby.profile
		profile.make_active_slot().vehicle = Assets.qualify(_arg("veh"))
		profile.save()
		lobby.on_setup_closed()
		await wait(0.4)
	if _arg("mapname") != "":
		var entries := MapPicker.make_entries()
		for i in entries.size():
			if str(entries[i].name).to_lower().contains(_arg("mapname").to_lower()):
				lobby.apply_settings(GameOptionsModel.make_with_map(Net.settings, i))
				break
		await wait(0.4)
	log_line("skirmish lobby: map %s, roster %s" % [Net.settings.get("map", "?"), Net.roster])


# ------------------------------------------------------------------ flow: skirmish

func flow_skirmish() -> void:
	open_scene("res://launcher.tscn")
	await wait_screen("menu")
	await wait(0.8)
	await skirmish_from_menu()
	await shot("01_lobby")
	await lan_press_start("Start match")
	if not await wait_scene_class("Battle", 90):
		return
	var b := battle()
	await wait(3.0)
	log_line(describe_battle(b))
	await shot("02_battle")
	await check_player_moves(b)
	await shot("03_moving")
	# fire for a moment
	if b.player:
		for w in b.player.weapons:
			w.trigger = true
		await wait(1.5)
		await shot("04_firing")
		for w in b.player.weapons:
			w.trigger = false
	b.use_chase = true
	await wait(0.5)
	await shot("05_chase")
	# end the match by destroying every opponent
	for v in get_tree().get_nodes_in_group("vehicles"):
		var n := 0
		while v != b.player and v.alive and v.team != b.player.team and n < 50:
			v.apply_hit(1e6, 1e6, b.player, v.global_position)
			n += 1
	log_line("alive after kill: %s" % [get_tree().get_nodes_in_group("vehicles").filter(func(v): return v.alive).map(func(v): return v.display_name)])
	await wait_for(func() -> bool: return b.is_over(), 10.0)
	if not b.is_over():
		log_line("match not over 10 s after destroying all opponents (respawn=%s frag_limit=%s); ending" % [b.config.get("respawn"), b.config.get("frag_limit")])
		b.end_match("QA end")
	await wait(1.0)
	await shot("06_end")
	await pass_results("skirmish")
	if await wait_scene_class("Launcher", 30):
		await wait(1.0)
		log_line("after match: launcher screen '%s'" % screen())
		await shot("07_back")


# ------------------------------------------------------------------ flow: gamepad only

func flow_gamepad() -> void:
	open_scene("res://library.tscn")
	await wait_screen("home")
	await wait(0.5)
	log_line("focus on open: %s" % focus_text())
	# walk down with the d-pad until "Host LAN game" (primary) is focused
	var n := 0
	while not focus_text().contains("Host LAN game") and n < 60:
		await pad_button(JOY_BUTTON_DPAD_DOWN)
		n += 1
	log_line("after %d d-pad downs focus: %s" % [n, focus_text()])
	await shot("01_lib_focus")
	if not expect(focus_text().contains("Host LAN game"), "d-pad reaches 'Host LAN game'"):
		return
	await pad_button(JOY_BUTTON_A)
	await wait_scene_class("Launcher", 10)
	await wait(0.5)
	log_line("launcher screen '%s' focus %s" % [screen(), focus_text()])
	await shot("02_host")
	await pad_button(JOY_BUTTON_B)
	await wait(0.5)
	log_line("pad B -> '%s' focus %s" % [screen(), focus_text()])
	expect(scene_name() == "Library" and screen() == "home", "pad B from Host LAN game returns to the library (the main menu)")
	n = 0
	while not focus_text().contains("Host LAN game") and n < 60:
		await pad_button(JOY_BUTTON_DPAD_DOWN)
		n += 1
	log_line("focus %s after %d" % [focus_text(), n])
	await pad_button(JOY_BUTTON_A)
	await wait_scene_class("Launcher", 10)
	await wait(1.0)
	expect(screen() == "lobby", "pad A on Host LAN game opens the lobby, alone it is a skirmish against bots (%s)" % screen())
	await shot("03_lobby")
	await wait(1.0)
	await pad_button(JOY_BUTTON_START)   # menu_primary: the footer's Start match
	await wait(0.4)
	if find_button("Start anyway") != null:
		await click_text("Start anyway")
	if not await wait_scene_class("Battle", 60):
		return
	var b := battle()
	await wait(3.0)
	var p0 := b.player.global_position
	await pad_axis(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	await wait(2.5)
	await pad_axis(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	log_line("throttle %.2f speed %.1f moved %.1f m" % [b.player.throttle, b.player.speed, b.player.global_position.distance_to(p0)])
	expect(b.player.global_position.distance_to(p0) > 1.0, "right trigger drives the %s" % ("soldier forward" if b.player is Infantry else "Herc"))
	if b.player is Infantry:
		await gamepad_check_soldier(b)   # skirmish starts on foot (BattleInfantry): the left stick strafes
	else:
		await pad_axis(JOY_AXIS_LEFT_X, -1.0)
		var y0 := b.player.rotation.y
		await wait(1.0)
		await pad_axis(JOY_AXIS_LEFT_X, 0.0)
		expect(absf(b.player.rotation.y - y0) > 0.05, "left stick turns (%.2f rad)" % (b.player.rotation.y - y0))
	var shots_before := get_tree().get_nodes_in_group("projectiles").size()
	var ev := InputEventJoypadButton.new()
	ev.button_index = JOY_BUTTON_RIGHT_SHOULDER
	ev.pressed = true
	Input.parse_input_event(ev)
	await wait(0.2)
	var triggered := b.player.weapons.filter(func(w): return w.trigger).size()
	await wait(0.8)
	await shot("04_fire")
	ev = ev.duplicate()
	ev.pressed = false
	Input.parse_input_event(ev)
	expect(triggered > 0, "pad RB holds fire group 1 (%d weapons triggered)" % triggered)
	await pad_button(JOY_BUTTON_START)
	await wait(0.5)
	await shot("05_start")
	log_line("after Start: mouse mode %d" % Input.mouse_mode)


# ------------------------------------------------------------------ flow: LAN co-op (two processes)

func flow_coop() -> void:
	open_scene("res://launcher.tscn")
	var role := "host" if flow == "coop_host" else "client"
	if not await wait_scene_class("Battle", 120):
		log_line("screen '%s' roster %s" % [screen(), Net.roster])
		return
	var b := battle()
	await wait(4.0)
	log_line("%s battle: %s" % [role, describe_battle(b)])
	log_line("roster: %s" % [Net.roster])
	await shot("01_" + role)
	expect(b.player != null, "%s has its own player vehicle" % role)
	var others := []
	for id in b.vehicles:
		var v = b.vehicles[id]
		if is_instance_valid(v) and v != b.player and v.owner_peer != 1 or (role == "client" and is_instance_valid(v) and v.owner_peer == 1 and v.get_meta("local_player", false) == false and v.display_name == "Host"):
			others.append(v)
	var remote: Herc = null
	for id in b.vehicles:
		var v = b.vehicles[id]
		if is_instance_valid(v) and v != b.player and str(v.display_name) in ["Host", "Client"]:
			remote = v
	expect(remote != null, "%s sees the other pilot (vehicles: %s)" % [role, describe_battle(b)])
	# both drive forward; each checks the other's puppet moves
	var rp0: Vector3 = remote.global_position if remote else Vector3.ZERO
	Input.action_press("throttle_up")   # players start on foot (BattleInfantry): the action runs a soldier, drives a Herc
	await wait(4.0)
	if remote:
		var d := remote.global_position.distance_to(rp0)
		expect(d > 1.0, "%s: remote pilot puppet moved %.1f m via snapshots" % [role, d])
	await shot("02_" + role + "_moving")
	Input.action_release("throttle_up")
	if b.player:
		b.player.throttle = 0.0
	# fire at the other / at enemies; the host damages an AI unit and the client checks it replicated
	if role == "host":
		var ai: Herc = null
		for v in get_tree().get_nodes_in_group("vehicles"):
			if v.team != b.player.team and v.alive:
				ai = v
				break
		if ai:
			log_line("host damages %s (net %d)" % [ai.display_name, ai.net_id])
			ai.apply_hit(1e6, 1e6, b.player, ai.global_position)
		for w in b.player.weapons:
			w.trigger = true
		await wait(2.0)
		for w in b.player.weapons:
			w.trigger = false
		await wait(4.0)
		await shot("03_host_after_kill")
		var vs := {}
		for id in b.vehicles:
			vs[id] = b.vehicles[id].alive
		log_line("host alive map %s" % [vs])
		await wait(4.0)
		log_line("host ends the match")
		for v in get_tree().get_nodes_in_group("vehicles"):
			if v.team != b.player.team and v.alive:
				v.apply_hit(1e6, 1e6, b.player, v.global_position)
		await wait(1.0)
		if not b.is_over():
			b.end_match("QA: host ends the match")
	else:
		for w in b.player.weapons:
			w.trigger = true
		await wait(2.0)
		for w in b.player.weapons:
			w.trigger = false
		await wait(4.0)
		var vs := {}
		for id in b.vehicles:
			vs[id] = b.vehicles[id].alive
		log_line("client alive map %s" % [vs])
		await shot("03_client_after_kill")
	await pass_results(role)
	if await wait_scene_class("Launcher", 60):
		await wait(1.5)
		log_line("%s after match: screen '%s' online %s" % [role, screen(), Net.is_online()])
		await shot("04_" + role + "_after")


# ------------------------------------------------------------------ flow: a battle from the command-line flags

## --flow=battle plus the battle flags (--herc= --map= --arena= --world=): driving, flight, AI behaviour.
func flow_battle() -> void:
	open_scene("res://games/es1/battle.tscn")
	if not await wait_scene_class("Battle", 30):
		return
	var b := battle()
	await wait(2.5)
	log_line(describe_battle(b))
	var p := b.player
	if p == null:
		fail("no player")
		return
	await shot("01_start")
	var p0 := p.global_position
	log_line("player at %s on_floor %s ground %.1f" % [p0, p.is_on_floor(), MapBuilder.ground_height(b, p0)])
	p.throttle = 1.0
	if p is Flyer:
		(p as Flyer).lift_input = 0.6
	var samples := []
	for i in 6:
		await wait(1.0)
		samples.append("%.1fm/s@%s" % [p.velocity.length(), p.global_position.snapped(Vector3.ONE * 0.1)])
	if p is Flyer:
		(p as Flyer).lift_input = 0.0
	log_line("drive samples: %s" % [samples])
	var d := p.global_position.distance_to(p0)
	expect(d > 5.0, "%s moves under full throttle (%.1f m in 6 s)" % [p.vehicle_id, d])
	for i in p.get_slide_collision_count():
		var c := p.get_slide_collision(i)
		log_line("collides with %s" % [c.get_collider()])
	await shot("02_after_drive")
	p.throttle = 0.0
	b.use_chase = true
	await wait(0.5)
	await shot("03_chase")
	# let the AI fight on its own for a while
	var kills0 := 0
	var shots_fired := 0
	var t := Time.get_ticks_msec()
	var hp0 := {}
	for id in b.vehicles:
		hp0[id] = b.vehicles[id].integrity
	await wait(_arg("watch").to_float() if _arg("watch") != "" else 25.0)
	var changed := []
	for id in b.vehicles:
		var v = b.vehicles[id]
		if is_instance_valid(v):
			if absf(v.integrity - float(hp0.get(id, 1.0))) > 0.001 or not v.alive or v.deaths > 0:
				changed.append("%s int %.2f kills %d deaths %d" % [v.display_name, v.integrity, v.kills, v.deaths])
	log_line("after watching AI: %s" % [changed])
	expect(not changed.is_empty(), "AI units fight (someone took damage)")
	await shot("04_after_watch")


# ------------------------------------------------------------------ flow: LAN through the UI (two processes)

## lan_host: menu -> Host LAN game -> mode (--mode=coop|vs|team_vs|campaign) in the lobby's Game
## Options -> wait for the client -> Start match. lan_join: menu -> Join LAN game -> discovered server -> Ready.
## lobby_host / lobby_join open the lobby without the menu and check its chat and the client's read-only options too.
func flow_lan() -> void:
	var role := "host" if flow in ["lan_host", "lobby_host"] else "client"
	var via_lobby := flow.begins_with("lobby")
	var mode := _arg("mode") if _arg("mode") != "" else "coop"
	var dedicated := _has("dedicated")
	open_scene("res://launcher.tscn")
	await wait_screen("menu")
	await wait(0.8)
	for c in all_controls(cur(), []):
		if c is LineEdit and c.is_visible_in_tree():
			(c as LineEdit).text = "Host" if role == "host" else "Client"
			(c as LineEdit).text_changed.emit((c as LineEdit).text)
			break
	log_line("pilot name set to %s" % Net.player_name)
	if role == "host":
		if via_lobby:
			await lan_open_lobby_directly(mode)
		else:
			await lan_open_lobby_from_menu(mode)
		lan_check_lobby_mode(mode)
		await wait_for(func() -> bool: return Net.roster.size() >= 2, 60.0, "the client to join")
		var start := find_button("Start mission" if mode == "campaign" else "Start match")
		var client_ready := Net.make_unready_names().is_empty()
		expect(start != null and start.disabled != client_ready, "host: Start match is disabled exactly while the client is not ready")
		if mode == "team_vs":
			await lan_host_sees_team_change()
			await lan_host_assign_all()
		if via_lobby:
			await lan_check_lobby_chat(role)
		await wait_for(func() -> bool: return Net.roster.keys().all(func(id): return int(id) == 1 or bool(Net.roster[id].ready)),
			30.0, "the client to be ready")
		await wait(0.5)
		expect(start != null and not start.disabled, "host: Start match is enabled once the client is ready")
		await wait(1.0)
		await shot("02_lobby_host")
		log_line("host lobby roster: %s" % [Net.roster])
		await lan_press_start("Start mission" if find_button("Start mission") != null else "Start match")
	else:
		await click_text("Join LAN game")
		await wait_screen("browser", 5)
		var by_ws := _arg("transport") == "ws"
		var ok := not by_ws and await wait_for(func() -> bool: return find_button("Host's game") != null, 20.0, "LAN discovery of the host")
		await shot("01_browser")
		if ok:
			await click_text("Host's game")
		else:
			var le: LineEdit = null
			for c in all_controls(cur(), []):
				if c is LineEdit and c.is_visible_in_tree() and le == null:
					le = c   # the address row comes first (the password row follows)
			le.text = "127.0.0.1"
			if by_ws:
				le.text = "ws://127.0.0.1:%s" % (_arg("port") if _arg("port") != "" else str(Net.GAME_PORT))
			await click_text("Join address")
		if not await wait_screen("lobby", 15):
			return
		await wait(1.5)
		await shot("02_lobby_client")
		log_line("client lobby summary roster: %s settings %s" % [Net.roster, Net.settings])
		if mode == "campaign":
			await check_client_campaign_isolation()
		lan_check_lobby_mode(mode)
		if mode == "team_vs":
			await lan_client_switch_team()
		if via_lobby:
			lan_check_client_options()
			await lan_check_lobby_chat(role)
		await lan_press_ready()
	if not await wait_scene_class("Battle", 60):
		return
	var b := battle()
	await wait(4.0)
	log_line("%s battle: %s" % [role, describe_battle(b)])
	await shot("03_battle_" + role)
	var remote: Herc = null
	for id in b.vehicles:
		var v = b.vehicles[id]
		if is_instance_valid(v) and b.player and v != b.player and str(v.display_name) in ["Host", "Client"]:
			remote = v
	expect(b.player != null, "%s has a player vehicle" % role)
	expect(remote != null or dedicated, "%s sees the other pilot" % role)
	if mode == "campaign":
		await lan_check_objectives(role, b)
	if b.player is Infantry:
		await lan_check_boarding(role, b, remote as Infantry)   # before anyone runs away from his Herc
	if b.player is Infantry and int(b.config.get(InfantryBots.CONFIG_KEY, 0)) > 0:
		await lan_check_infantry(role, b, remote as Infantry)
	var rp0: Vector3 = remote.global_position if remote else Vector3.ZERO
	var my0: Vector3 = b.player.global_position if b.player else Vector3.ZERO
	Input.action_press("throttle_up")   # a Herc's throttle rises, a soldier runs (both host-simulated)
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	Input.parse_input_event(rb)
	var remote_fired := false
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 4000:
		if remote and is_instance_valid(remote):
			for w in remote.weapons:
				if w.trigger:
					remote_fired = true
		await get_tree().process_frame
	rb = rb.duplicate()
	rb.pressed = false
	Input.parse_input_event(rb)
	Input.action_release("throttle_up")
	if b.player:
		b.player.throttle = 0.0
	if remote:
		expect(remote.global_position.distance_to(rp0) > 1.0, "%s: other pilot moved %.1f m" % [role, remote.global_position.distance_to(rp0)])
	if b.player:
		expect(b.player.global_position.distance_to(my0) > 1.0, "%s: own Herc moved %.1f m (client = host-simulated)" % [role, b.player.global_position.distance_to(my0)])
	expect(remote_fired or dedicated, "%s sees the other pilot's fire triggers (pad RB)" % role)
	await shot("04_moving_" + role)
	if not dedicated:
		await lan_check_chat(role, b)
	if _arg("leave") != "":
		await lan_leave_mid_match(role, b, remote)
		return
	# the host destroys one enemy; both log which net ids are dead
	if role == "host":
		var victim: Herc = null
		for v in get_tree().get_nodes_in_group("vehicles"):
			if v.team != b.player.team and v.alive and v != remote:
				victim = v
				break
		if victim:
			var n := 0
			while victim.alive and n < 50:
				victim.apply_hit(1e6, 1e6, b.player, victim.global_position)
				n += 1
			log_line("host destroyed %s net %d" % [victim.display_name, victim.net_id])
	await wait(3.0)
	var dead := []
	for id in b.vehicles:
		if is_instance_valid(b.vehicles[id]) and not b.vehicles[id].alive:
			dead.append(id)
	log_line("%s dead net ids: %s" % [role, dead])
	await shot("05_after_kill_" + role)
	if role == "host":
		await wait(3.0)
		log_line("host destroys every enemy to end the match")
		for v in get_tree().get_nodes_in_group("vehicles"):
			var n := 0
			while v.team != b.player.team and v.alive and n < 50:
				v.apply_hit(1e6, 1e6, b.player, v.global_position)
				n += 1
		if mode == "campaign":
			await finish_coop_campaign_mission(b, remote)
		elif not mode in ["vs", "team_vs"]:
			await wait_for(func() -> bool: return b.is_over(), MISSION_END_SECONDS, "co-op match end after all enemies died")
		if not b.is_over():
			b.end_match("QA end")
	else:
		var seen := [false]
		b.match_finished.connect(func(_r): seen[0] = true)
		var navs_seen := [0]
		var watch_navs := func() -> void:
			while is_instance_valid(b) and b.mission != null and not b.is_over():
				navs_seen[0] = maxi(navs_seen[0], int(b.mission.nav_index))
				await get_tree().physics_frame
		watch_navs.call()
		await wait_for(func() -> bool: return cur() is MatchResults or cur() is Launcher, 90.0 if mode == "campaign" else 40.0)
		log_line("client: match_finished signal seen=%s" % [seen[0]])
		if mode == "campaign":
			expect(navs_seen[0] > 1, "client: the host's nav progress reaches the client's mission (nav index %d)" % navs_seen[0])
	await wait(1.0)
	await shot("06_end_" + role)
	await pass_results("lan_" + role)
	if dedicated:   # the server starts the next match by itself (DedicatedServer, results_seconds later)
		expect(await wait_scene_class("Battle", 90), "client: the dedicated server started the next match")
		return
	if await wait_scene_class("Launcher", 40):
		await wait(1.5)
		if mode == "campaign" and role == "host":
			await pass_campaign_debrief()
		log_line("%s after match: screen '%s' online %s roster %d" % [role, screen(), Net.is_online(), Net.roster.size()])
		expect(screen() == "lobby" and Net.is_online(), "%s: results -> Continue returns to the LAN lobby" % role)
		await shot("07_after_" + role)
		if role == "host":
			await wait(8.0)   # keep the session open while the client is still on its results screen


## LAN chat both ways (BattleChat): each side says an all line and a team line through the chat input (chat_all /
## chat_team, chat_send); the other side receives the all line with the sender's name, and the team line only when
## both play on one team.
func lan_check_chat(role: String, b: Battle) -> void:
	var other := "client" if role == "host" else "host"
	for action in ["chat_all", "chat_team"]:
		await tap(action)
		var line: ChatInputLine = b.chat.panel.find_children("*", "ChatInputLine", true, false)[0]
		expect(b.chat.panel.is_open() and line.has_focus(), "%s: %s opens the chat input" % [role, action])
		line.text = "e2e %s from %s" % [action, role]
		await tap("chat_send")
	var log := b.overlay.chat_log
	var has := func(text: String) -> bool: return log.entries.any(func(e: Dictionary) -> bool: return e.text == text)
	var ok := await wait_for(has.bind("e2e chat_all from %s" % other), 20.0, "the %s's all-chat line" % other)
	expect(ok, "%s receives the %s's all-chat line" % [role, other])
	var same_team := b.chat.team_of(multiplayer.get_unique_id()) == b.chat.team_of(_other_peer(b))
	if same_team:
		ok = await wait_for(has.bind("e2e chat_team from %s" % other), 10.0, "the %s's team line" % other)
		expect(ok, "%s receives the %s's team line (same team)" % [role, other])
	else:
		await wait(3.0)
		expect(not has.call("e2e chat_team from %s" % other), "%s does not receive the other team's team line" % role)
	var sender := log.entries.filter(func(e: Dictionary) -> bool: return e.text == "e2e chat_all from %s" % other)
	expect(not sender.is_empty() and str(sender[0].sender).to_lower() == other, "%s: the line names its sender (%s)" % [role, sender[0].sender if not sender.is_empty() else "?"])
	await shot("04b_chat_" + role)
	await wait(2.0)   # the other side may still be waiting for these lines


## The menu way in: Host LAN game (a versus lobby with its default settings at once)
## campaign) -> the host sets the mode, map, bots and team mode in Game Options (here through the model the panel uses).
func lan_open_lobby_from_menu(mode: String) -> void:
	await click_text("Host LAN game")
	if not await wait_screen("lobby", 5):
		return
	await wait(0.5)
	await lan_apply_host_options(mode)


## The direct way in: the lobby opens with the default settings of the mode (no menu).
func lan_open_lobby_directly(mode: String) -> void:
	(cur() as Launcher).go("lobby", {"kind": "vs" if mode == "team_vs" else mode})
	if not await wait_screen("lobby", 5):
		return
	await wait(0.5)
	await lan_apply_host_options(mode)


## The host picks `kind` (a MatchFlow mode) in the lobby's Game Options mode picker, the way a player does (mouse or pad:
## the OptionButton's own selection signal).
func lan_pick_mode(lobby: LobbyScreen, kind: String) -> bool:
	var picker := lobby.options.controls.get("mode") as OptionButton
	var at := MatchFlow.make_offered_modes().find(kind)
	if picker == null or at < 0:
		fail("the host's mode picker offers no '%s'" % kind)
		return false
	picker.select(at)
	picker.item_selected.emit(at)
	await wait(0.5)
	if not expect(str(Net.settings.get("mode", "")) == kind, "picking '%s' in the lobby sets the mode (%s)" % [kind, Net.settings.get("mode")]):
		return false
	return true


## Applies the mode and the --mapname / --ai / --bots / --infantry arguments to the host's lobby, as Game Options does.
func lan_apply_host_options(mode: String) -> void:
	var lobby := (cur() as Launcher).current as LobbyScreen
	var s := Net.settings
	var kind := "vs" if mode == "team_vs" else mode
	if str(s.get("mode", "")) != kind:
		await lan_pick_mode(lobby, kind)
		s = Net.settings
	if _arg("mapname") != "":
		var es := MapPicker.make_entries()
		for i in es.size():
			if str(es[i].name).to_lower().contains(_arg("mapname").to_lower()):
				s = GameOptionsModel.make_with_map(s, i)
				break
	if _arg("ai") != "":
		s = GameOptionsModel.make_with_value(s, "ai", int(_arg("ai")))
	if _arg("bots") != "":
		s = GameOptionsModel.make_with_value(s, InfantryBots.CONFIG_KEY, int(_arg("bots")))
	if _arg("infantry") != "":
		s = GameOptionsModel.make_with_value(s, LobbySettings.INFANTRY_PACK_KEY, _arg("infantry"))
	if mode == "team_vs":
		var team_modes := GameOptionsModel.make_game_modes(s).filter(func(m: Dictionary) -> bool: return bool(m.team_based))
		if team_modes.is_empty():
			fail("host: the map offers no team game mode")
		else:
			s = GameOptionsModel.make_with_game_mode(s, str(team_modes[0].id))
	lobby.apply_settings(s)
	await wait(0.5)
	await shot("01_lobby_options_" + mode)


## The host's Start; the warning about parts this mode leaves off ("Start anyway") is answered yes.
func lan_press_start(text: String) -> void:
	await click_text(text)
	await wait(0.4)
	if find_button("Start anyway") != null:
		log_line("the start warning asked about parts left off; answering Start anyway")
		await click_text("Start anyway")


## Ready on the lobby footer; the warning about parts this mode leaves off ("Ready anyway") is answered yes.
func lan_press_ready() -> void:
	await click_text("Ready")
	await wait(0.4)
	if find_button("Ready anyway") != null:
		log_line("the ready warning asked about parts left off; answering Ready anyway")
		await click_text("Ready anyway")


## The lobby chat (LobbyChatHub) both ways: the client says a line, the host sees it and answers to everybody.
func lan_check_lobby_chat(role: String) -> void:
	var hub := LobbyChatHub.ensure(get_tree())
	await wait(0.5)
	var said := func(text: String) -> bool: return hub.history.any(func(l: Dictionary) -> bool: return l.text == text)
	if role == "client":
		hub.say("all", "ready when you are")
		expect(await wait_for(func() -> bool: return said.call("gl hf"), 20.0, "the host's lobby chat line"), "client: the host's lobby chat line arrives")
	else:
		expect(await wait_for(func() -> bool: return said.call("ready when you are"), 20.0, "the client's lobby chat line"), "host: the client's lobby chat line arrives")
		hub.say("all", "gl hf")
	await wait(0.5)


## A client reads the host's options as text: no option control in Game Options, the host's map and mode named.
func lan_check_client_options() -> void:
	var lobby := (cur() as Launcher).current as LobbyScreen
	expect(lobby.options.find_children("*", "OptionButton", true, false).is_empty(), "client: the options are text, not controls")
	var text := ""
	for c in lobby.options.find_children("*", "Label", true, false):
		text += str(c.text) + "
"
	expect(text.contains(str(Net.settings.get("map", "?"))), "client: the host's map is shown (%s)" % Net.settings.get("map", "?"))


## The lobby's mode: versus is a deathmatch without teams; a team mode offers teams (the host's Adjust teams button, the
## local pilot's team picker on his card).
func lan_check_lobby_mode(mode: String) -> void:
	var lobby := (cur() as Launcher).current as LobbyScreen
	var shown := lobby != null and (find_button("Adjust teams...") != null or lobby.carousel.card_for("peer:%d" % Net.my_id()) != null
		and lobby.carousel.card_for("peer:%d" % Net.my_id()).team_picker.is_visible_in_tree())
	if mode == "vs":
		expect(Net.settings.get("game_mode") == "deathmatch" and not Net.settings.get("teams", false), "versus defaults to deathmatch (%s)" % Net.settings.get("game_mode"))
		expect(not shown, "deathmatch lobby: no team controls")
	elif mode == "team_vs":
		expect(bool(Net.settings.get("teams", false)) and shown, "team mode lobby: the team controls show (%d teams)" % int(Net.settings.get("team_count", 0)))


## Client: moves itself to the second team with the picker on his own card.
func lan_client_switch_team() -> void:
	var lobby := (cur() as Launcher).current as LobbyScreen
	var card := lobby.carousel.card_for("peer:%d" % Net.my_id())
	if not expect(card != null and card.team_picker.is_visible_in_tree(), "client: a team picker on his own card"):
		return
	var mine := int(Net.roster[Net.my_id()].team)
	expect(mine == TeamAssignment.UNASSIGNED, "client: a joiner starts unassigned (team %d)" % mine)
	var other := 1
	var picker := card.team_picker
	picker.select(picker.get_item_index(other + TeamList.PICKER_ID_OFFSET))
	picker.item_selected.emit(picker.get_item_index(other + TeamList.PICKER_ID_OFFSET))
	var ok := await wait_for(func() -> bool: return int(Net.roster[Net.my_id()].team) == other, 10.0, "the client's team change to come back from the host")
	expect(ok, "client: the team change replicates (team %d -> %d)" % [mine, other])
	await shot("02b_team_switch_client")


## Host: Start is blocked while the host has no team; Assign all places him and balances the teams.
func lan_host_assign_all() -> void:
	expect(MatchFlow.make_start_block_reason().begins_with("No team yet"), "host: Start is blocked while a pilot is unassigned (%s)" % MatchFlow.make_start_block_reason())
	await shot("02c_unassigned_host")
	await click_text("Assign all")
	var ok := await wait_for(func() -> bool: return TeamAssignment.make_unassigned_names(Net.roster, Net.settings).is_empty(), 10.0, "Assign all")
	var sizes := TeamAssignment.make_team_sizes(Net.roster, Net.settings)
	expect(ok and sizes.max() - sizes.min() <= 1, "host: Assign all leaves nobody unassigned and balances the teams (%s)" % [sizes])


## Host: sees the client's team change in the roster.
func lan_host_sees_team_change() -> void:
	var client_id := -1
	for id in Net.roster:
		if int(id) != 1:
			client_id = int(id)
	var before := int(Net.roster[client_id].team) if client_id != -1 else -1
	var ok := await wait_for(func() -> bool: return client_id != -1 and int(Net.roster[client_id].team) != TeamAssignment.UNASSIGNED, 30.0, "the client to switch team")
	expect(ok, "host: sees the client's team change (%d -> %d)" % [before, int(Net.roster[client_id].team) if client_id != -1 else -1])
	await wait(0.5)
	await shot("02a_team_list_host")


## Co-op campaign: the objectives panel lists the mission's objectives on both peers; the client's come from the
## host (battle effect "objectives") and match the host's.
func lan_check_objectives(role: String, b: Battle) -> void:
	var panel := b.overlay.objectives
	var ok := await wait_for(func() -> bool: return panel.line_count() > 0 and (role == "host" or panel.uses_host_lines()), 15.0, "%s objectives" % role)
	expect(ok, "%s: the objectives panel shows the mission (%s)" % [role, panel.shown_lines()])
	if role == "client":
		expect(panel.shown_lines() == MissionObjectives.make_lines(b) or panel.uses_host_lines(), "client: objectives come from the host")


## The peer id of the other player in a two-player LAN match.
func _other_peer(b: Battle) -> int:
	for id in Net.roster:
		if int(id) != multiplayer.get_unique_id():
			return int(id)
	return 0


## Co-op starts on foot (BattleInfantry): the client boards his parked Herc with vehicle_enter_exit, drives it
## and gets out again; both peers see the occupancy, the hidden soldier and the moving Herc.
func lan_check_boarding(role: String, b: Battle, remote: Infantry) -> void:
	var me := b.multiplayer.get_unique_id()
	# the host reads the client's peer from the roster: once the client has boarded, his soldier's owner_peer is EMPTY
	# (OccupancyDirector), and he may already be inside when the host gets here
	var client_peer := me if role == "client" else _other_peer(b)
	expect(b.player is Infantry and (b.player as Infantry).armor_id.ends_with("LIGHT"), "%s starts on foot in light armour" % role)
	if role == "client":
		await wait(1.0)
		_press_action("vehicle_enter_exit")
		var boarded := await wait_for(func() -> bool: return b.player != null and not (b.player is Infantry), 10.0, "the client boarding his Herc")
		if boarded:
			expect(VehicleOccupancy.of(b.player).pilot() == me, "client: occupancy names the client as pilot")
			await shot("05_boarded_client")
			var p0: Vector3 = b.player.global_position
			Input.action_press("throttle_up")
			await wait(2.5)
			Input.action_release("throttle_up")
			expect(b.player.global_position.distance_to(p0) > 2.0, "client: the boarded Herc moves (%.1f m)" % b.player.global_position.distance_to(p0))
			await wait(1.0)
			_press_action("vehicle_enter_exit")
			await wait_for(func() -> bool: return b.player is Infantry and not (b.player as Infantry).stowed, 10.0, "the client getting out")
			expect(b.player is Infantry, "client: on foot again after vehicle_enter_exit")
		await wait(2.0)
		return
	var seen_inside := await wait_for(func() -> bool: return remote != null and remote.stowed, 20.0, "host to see the client's soldier inside")
	if seen_inside:
		var herc := b.occupancy.vehicle_of(client_peer)
		expect(herc != null and herc.owner_peer == client_peer, "host: the client pilots his Herc (owner peer %d)" % client_peer)
		var p1: Vector3 = herc.global_position if herc else Vector3.ZERO
		await wait_for(func() -> bool: return herc != null and herc.global_position.distance_to(p1) > 2.0, 10.0, "host to see the client's Herc move")
		await wait_for(func() -> bool: return remote != null and not remote.stowed, 20.0, "host to see the client get out")
		expect(herc != null and VehicleOccupancy.of(herc).is_empty() and herc.owner_peer == 0, "host: the Herc is empty again")


## Infantry over the LAN (host-authoritative): both peers see the host's bots moving, the host's thrown grenade
## flies and bursts on the client, and the client works a Beowulf turret from its gunner seat (his aim and
## trigger reach the host's TurretCrew).
func lan_check_infantry(role: String, b: Battle, remote: Infantry) -> void:
	var want := int(b.config.get(InfantryBots.CONFIG_KEY, 0))
	var bots_seen := func() -> Array: return b.vehicles.values().filter(func(h) -> bool:
		return is_instance_valid(h) and h is Infantry and InfantryBots.is_bot(int(h.get_meta("bot_id", 0))))
	await wait_for(func() -> bool: return bots_seen.call().size() == want, 15.0, "%s to see %d bots" % [role, want])
	var start := {}
	for bot in bots_seen.call():
		start[bot] = (bot as Infantry).global_position
	await wait(4.0)
	var moved: Array = bots_seen.call().filter(func(bot) -> bool: return start.has(bot) and bot.global_position.distance_to(start[bot]) > 3.0)
	expect(moved.size() > 0, "%s sees the bots move (%d of %d)" % [role, moved.size(), want])
	if role == "host":
		await lan_host_infantry(b, remote)
	else:
		await lan_client_infantry(b)


func lan_host_infantry(b: Battle, remote: Infantry) -> void:
	await wait(1.0)
	var me := b.player as Infantry
	me.kit.counts[me.kit.grenade_id] = 1
	b.infantry.gear.apply_throw(1, InfantryGearDirector.SLOT_GRENADE, 0.5)
	expect(get_tree().get_nodes_in_group("thrown_items").size() > 0, "host: grenade thrown")
	await wait(4.0)
	var client_peer := remote.owner_peer if remote else -1
	var id := b.spawner.allocate_id()
	var at := remote.global_position + Vector3(12, 0, 0) if remote else Vector3.ZERO
	at.y = MapBuilder.ground_height(b, at)
	b.send_spawn({"net_id": id, "vehicle": "tribes2:BEOWULF", "team": 0, "owner": 0, "xf": Transform3D(Basis(), at),
		"loadout": [], "name": "Beowulf", "ai": {}, "parked": true})
	var tank: Herc = b.vehicles.get(id)
	await wait(1.0)
	b.occupancy.apply_board(client_peer, tank, 1)
	var crew := TurretCrew.find(tank)
	var aimed := await wait_for(func() -> bool: return crew.trigger_bits != 0 and absf(tank.torso_yaw - 1.0) < 0.2, 20.0,
		"the client's turret aim and trigger on the host")
	expect(aimed, "host: the client gunner turns the Beowulf turret (%.2f) and fires (bits %d)" % [tank.torso_yaw, crew.trigger_bits])
	await wait(2.0)
	b.occupancy.apply_exit(client_peer, tank)
	await wait(2.0)


func lan_client_infantry(b: Battle) -> void:
	var flew := await wait_for(func() -> bool: return get_tree().get_nodes_in_group("thrown_items").size() > 0, 15.0,
		"the host's grenade on the client")
	expect(flew, "client: sees the host's grenade fly")
	if flew:
		expect(await wait_for(func() -> bool: return get_tree().get_nodes_in_group("thrown_items").is_empty(), 6.0, "the burst"),
			"client: the grenade bursts (host's message)")
	var gunning := await wait_for(func() -> bool: return b.pilot is GunnerPilot, 25.0, "the gunner seat")
	expect(gunning, "client: in the Beowulf's gunner seat with gunner controls")
	if not gunning:
		return
	await shot("05_gunner_client")
	var gp := b.pilot as GunnerPilot
	gp.aim_yaw = 1.0
	var rb := InputEventJoypadButton.new()
	rb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	rb.pressed = true
	Input.parse_input_event(rb)
	await wait(4.0)
	rb = rb.duplicate()
	rb.pressed = false
	Input.parse_input_event(rb)
	expect(await wait_for(func() -> bool: return b.player is Infantry and not (b.player as Infantry).stowed, 15.0, "the host to let him out"),
		"client: on foot again after the host empties the gunner seat")


func _press_action(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)


# ------------------------------------------------------------------ results screen

## Waits for the results screen, checks it, screenshots it and presses Continue.
func pass_results(tag: String) -> void:
	if not await wait_scene_class("MatchResults", 40):
		return
	var r := cur() as MatchResults
	await wait(0.8)
	var s := r.summary
	log_line("results %s: headline '%s' winner '%s' time %.0f s pilots %s salvage %s rematch %s" % [tag, s.get("headline"),
		s.get("winner"), float(s.get("seconds", 0)), (s.get("pilots", []) as Array).map(func(p): return "%s %d/%d" % [p.name, p.kills, p.deaths]),
		s.get("salvage"), r.can_rematch()])
	expect(str(s.get("headline", "")) != "" and not (s.get("pilots", []) as Array).is_empty(), "results screen shows headline and pilots (%s)" % tag)
	expect(find_button("Continue") != null, "results screen offers Continue (%s)" % tag)
	expect((find_button("Rematch") != null) == r.can_rematch(), "Rematch offered exactly when the mode allows (%s, mode %s)" % [tag, s.get("mode")])
	await shot("results_" + tag)
	await click_text("Continue")


## Co-op campaign host: the campaign's debriefing comes after the results; Continue goes back to the lobby.
func pass_campaign_debrief() -> void:
	if not expect(await wait_screen("debrief", 10), "co-op campaign host sees the debriefing (screen '%s')" % screen()):
		return
	await shot("debrief_host")
	await click_text("Continue")
	await wait_screen("lobby", 10)
	await wait(1.0)


## Co-op campaign (playtest E3): the host walks the CLIENT's vehicle through the nav points and destroys every hostile
## unit (each wave its death regions wake) and structure; the host-authoritative mission must then end in success.
func finish_coop_campaign_mission(b: Battle, remote: Herc) -> void:
	var walker: Herc = remote if remote != null and is_instance_valid(remote) else b.player
	log_line("host walks %s through the nav points" % walker.display_name)
	var t := Time.get_ticks_msec()
	while not b.is_over() and Time.get_ticks_msec() - t < 60000:
		if _navs_left(b) > 0:
			_step_to_next_nav(b, walker)
		for v in get_tree().get_nodes_in_group("vehicles"):
			if v.team != b.player.team and v.alive:
				v.apply_hit(1e6, 1e6, b.player, v.global_position)
		for st in b.mission.structures:
			if st.team != b.player.team and st.alive:
				st.destroy(b.player)
		for i in 10:
			await get_tree().physics_frame
	log_line("co-op mission: navs left %d, dormant groups %s, over %s, result %s" % [_navs_left(b), b.mission.dormant_groups.keys(),
		b.is_over(), b.result])
	expect(b.is_over() and bool(b.result.get("success", false)), "co-op campaign mission ends in success with the client's nav progress and all hostiles down")


## A button of the open in-battle menu (null when it is not open).
func battle_menu_button(text: String) -> BaseButton:
	var b := battle()
	if b == null or b.battle_menu() == null:
		return null
	return find_button(text, b.battle_menu())


## Confirms the open ConfirmDialog by clicking its confirm button.
func confirm_dialog() -> void:
	await wait(0.3)   # the dialog centres itself after its first layout
	for c in all_controls(get_tree().root, []):
		if c is ConfirmDialog and not c.is_queued_for_deletion():
			await click((c as ConfirmDialog).confirm_button, "confirm")
			return
	fail("no confirm dialog open")


func _save_named_shot(file_name: String) -> void:
	if shots == "":
		return
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(shots.path_join(file_name))
	log_line("shot " + shots.path_join(file_name))


# ------------------------------------------------------------------ flow: in-battle menu

## Skirmish -> Esc opens the menu (paused, mouse free) -> Options -> back -> Resume (pad Start
## opens / B closes) -> Leave match (confirm) -> results -> Rematch -> menu -> Leave -> results -> Continue.
func flow_pause() -> void:
	open_scene("res://launcher.tscn")
	await wait_screen("menu")
	await wait(0.8)
	await skirmish_from_menu()
	await lan_press_start("Start match")
	if not await wait_scene_class("Battle", 90):
		return
	var b := battle()
	await wait(3.0)
	log_line("objective: '%s'" % BattleRules.make_objective_text(b.config))
	await tap("menu_pause")
	await wait(0.3)
	expect(b.is_menu_open() and get_tree().paused, "Esc (menu_pause) opens the in-battle menu and pauses")
	expect(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "mouse released while the menu is open")
	await shot("01_menu")
	await _save_named_shot("ui_pause.png")
	await click(battle_menu_button("Options"), "Options")
	await wait(0.5)
	expect(b.battle_menu() != null and b.battle_menu().current_name == "options", "Options opens over the battle")
	await shot("02_options")
	await tap("menu_back")
	await wait(0.3)
	await click(battle_menu_button("Resume"), "Resume")
	await wait(0.3)
	expect(not b.is_menu_open() and not get_tree().paused, "Resume closes the menu and unpauses")
	await pad_button(JOY_BUTTON_START)
	expect(b.is_menu_open(), "pad Start opens the menu")
	await pad_button(JOY_BUTTON_B)
	expect(not b.is_menu_open(), "pad B resumes")
	await tap("menu_pause")
	await click(battle_menu_button("Leave match"), "Leave match")
	await wait(0.3)
	await shot("03_leave_confirm")
	await confirm_dialog()
	if not await wait_scene_class("MatchResults", 10):
		return
	await wait(0.8)
	await shot("04_results")
	await _save_named_shot("ui_results.png")
	await click_text("Rematch")
	if not await wait_scene_class("Battle", 60):
		return
	await wait(2.0)
	expect(battle().player != null, "Rematch starts the skirmish again")
	await tap("menu_pause")
	await click(battle_menu_button("Leave match"), "Leave match")
	await confirm_dialog()
	await pass_results("rematch_left")
	expect(await wait_scene_class("Launcher", 20), "Continue returns to the launcher")


# ------------------------------------------------------------------ flow: abort a campaign mission

## Campaign (--game=es1|es2|starsiege|starsiege-cybrid) -> launch -> pad Start -> Abort mission ->
## results -> debriefing (failed) -> Continue: the campaign records it as a lost mission.
func flow_abort() -> void:
	var game := _arg("game") if _arg("game") != "" else "es1"
	var l := open_scene("res://launcher.tscn") as Launcher
	await wait_screen("menu")
	LauncherAutomation._start_campaign_of(game)
	l.show_started_campaign()
	if not await wait_screen("lobby", 30):
		return
	await wait(1.0)
	var before := str(Session.campaign.current_mission())
	await click_text("Start mission")
	if not await wait_scene_class("Battle", 90):
		return
	await wait(3.0)
	await pad_button(JOY_BUTTON_START)
	expect(battle().is_menu_open(), "pad Start opens the menu in a %s mission" % game)
	await shot("01_menu")
	await click(battle_menu_button("Abort mission"), "Abort mission")
	await confirm_dialog()
	await pass_results("abort_" + game)
	if not await wait_screen("debrief", 20):
		return
	await wait(0.5)
	await shot("02_debrief")
	expect(not bool(Session.last_result.get("success", true)), "the debriefing reports a failed mission")
	await click_text("Continue")
	await wait(1.0)
	var c = Session.campaign
	log_line("after abort: %s -> %s" % [before, c.current_mission() if c else "-"])
	var hist: Array = []
	if c and c.get("history") is Array:
		hist = c.get("history")
	elif c and c.get("results") is Array:
		hist = c.get("results")
	expect(not hist.is_empty() and not bool(hist.back().get("success", true)), "%s records the aborted mission as failed" % game)


# ------------------------------------------------------------------ LAN: leaving and co-op client isolation

## Co-op campaign client in the lobby: no campaign of its own, the Herc choice is the host's offer.
func check_client_campaign_isolation() -> void:
	await wait_for(func() -> bool: return Net.settings.has(MatchFlow.CAMPAIGN_OFFER), 10.0, "the host's campaign offer")
	await wait(0.5)
	expect(Session.campaign == null and Session.saga == null, "co-op client has no campaign of its own (campaign %s saga %s)" % [Session.campaign, Session.saga])
	var offer: Dictionary = Net.settings.get(MatchFlow.CAMPAIGN_OFFER, {})
	var host_ids: Array = (offer.get("garage", {}).get("vehicles", []) as Array).map(func(v): return str(v.vehicle))
	var picker: GaragePicker = null
	for c in all_controls(cur(), []):
		if c is GaragePicker:
			picker = c
	if not expect(picker != null, "client lobby shows the host's campaign Hercs"):
		return
	var ids := []
	for i in picker.choice_count():
		picker.select_choice(i)
		ids.append(str(picker.entry().vehicle))
	var mission_herc: Dictionary = offer.get("mission_herc", {})
	if not mission_herc.is_empty():
		host_ids.append(str(mission_herc.vehicle))
	log_line("client choices %s; host offer %s" % [ids, host_ids])
	expect(ids == host_ids, "client Herc choices == the host campaign's offer")
	picker.select_choice(0)
	await shot("02b_lobby_client_campaign")


## --leave=host|client: that side opens the menu mid-match and leaves; the other side checks the result.
func lan_leave_mid_match(role: String, b: Battle, remote: Herc) -> void:
	var leaver := _arg("leave")
	if role == leaver:
		await wait(2.0)
		await tap("menu_pause")
		expect(b.is_menu_open() and not get_tree().paused, "%s: LAN menu opens without pausing" % role)
		await shot("05_menu_" + role)
		await click(battle_menu_button("Leave match"), "Leave match")
		await confirm_dialog()
		expect(await wait_scene_class("Launcher", 20), "%s left: back at the launcher" % role)
		await wait(1.0)
		log_line("%s after leaving: screen '%s' online %s status '%s'" % [role, screen(), Net.is_online(), _status(cur().current)])
		await shot("06_left_" + role)
		return
	if role == "client":
		expect(await wait_scene_class("Launcher", 30), "client: the host leaving ends the match")
		await wait(1.0)
		var status := _status(cur().current)
		log_line("client after host left: screen '%s' status '%s'" % [screen(), status])
		expect(status.contains("host left"), "client is told the host left ('%s')" % status)
		await shot("06_host_left_client")
		return
	var remote_id := remote.net_id if remote else -1
	expect(await wait_for(func() -> bool: return not b.vehicles.has(remote_id), 20.0), "host: the leaving client's vehicle is removed")
	await shot("06_client_left_host")
	b.end_match("QA: host ends the match after the client left")
	await pass_results("host_after_client_left")


# ------------------------------------------------------------------ LAN extraction raid

const SavedGuard := preload("res://tests/saved_campaign_guard.gd")


## A LAN extraction raid (docs/design/extraction.md): the host makes an extraction lobby with squads (both on one
## team), both drop in aboard a transport, the host downs the client and revives him by holding interact (the client
## sees its downed overlay and gets up), both loot a cache (the host checks the client's inventory, the client sees its own), the client
## calls an exfil and boards it (the host puts him beside the landed transport) and finds the haul in his stash;
## the host is then killed and the raid ends for both on the results screen.
func flow_extraction() -> void:
	var role := "host" if flow == "extraction_host" else "client"
	var guard := SavedGuard.new()
	guard.back_up()
	var pilot := "XHost" if role == "host" else "XClient"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(ExtractionProfile.make_id(pilot))))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveGames.make_profile_path(OperatorProfile.make_id(pilot))))
	if role == "client":
		_prepare_callin_profile(pilot)
	open_scene("res://launcher.tscn")
	await wait_screen("menu")
	await wait(0.8)
	for c in all_controls(cur(), []):
		if c is LineEdit and c.is_visible_in_tree():
			(c as LineEdit).text = pilot
			(c as LineEdit).text_changed.emit(pilot)
			break
	if role == "host":
		await _extraction_host_lobby()
	else:
		await _extraction_client_lobby()
	if await wait_scene_class("Battle", 60):
		await _extraction_raid(role, battle())
	guard.restore()


## The client's operator brings raid points and a bought vehicle in his active slot: what the call-ins spend and deliver.
func _prepare_callin_profile(pilot: String) -> void:
	var o := OperatorProfile.load_for(pilot)
	o.apply_raid_points(CALLIN_START_POINTS)
	o.unlocks.apply_add(UnlockId.make("vehicle", CALLIN_VEHICLE))
	o.make_active_slot().vehicle = CALLIN_VEHICLE
	o.save()


func _extraction_host_lobby() -> void:
	await click_text("Host LAN game")
	await wait_screen("lobby", 5)
	await wait(0.5)
	var lobby := (cur() as Launcher).current as LobbyScreen
	await lan_pick_mode(lobby, ExtractionRules.MODE)
	var s := Net.settings
	var entries := MapPicker.make_entries()
	for i in entries.size():
		if str(entries[i].name).contains("Katabatic"):
			s = GameOptionsModel.make_with_map(s, i)
	s = GameOptionsModel.make_with_value(s, "ai", 0)   # faction vehicles
	s = GameOptionsModel.make_with_value(s, InfantryBots.CONFIG_KEY, 2)   # faction soldiers
	s = GameOptionsModel.make_with_squads(s, true)   # squads: the client joins the host's team (revive)
	lobby.apply_settings(s)
	await wait(0.5)
	await shot("x01_host_settings")
	await wait_for(func() -> bool: return Net.roster.size() >= 2, 60.0, "the client to join")
	await wait_for(func() -> bool: return Net.roster.keys().all(func(id): return int(id) == 1 or bool(Net.roster[id].ready)), 30.0, "the client to be ready")
	await wait(1.0)
	expect(Net.roster.values().all(func(e) -> bool: return e.get("kit") is Dictionary and not (e.kit.items as Array).is_empty()),
		"both kits reached the host's roster")
	Net.set_my_info("team", 0)   # one squad: host and client are teammates (revive)
	Net.assign_team(_client_peer(), 0)
	await wait(1.0)
	await shot("x02_lobby_host")
	await lan_press_start("Start match")


func _extraction_client_lobby() -> void:
	await click_text("Join LAN game")
	await wait_screen("browser", 5)
	if await wait_for(func() -> bool: return find_button("XHost's game") != null, 20.0, "LAN discovery of the host"):
		await click_text("XHost's game")
	else:
		for c in all_controls(cur(), []):
			if c is LineEdit and c.is_visible_in_tree():
				(c as LineEdit).text = "127.0.0.1"
		await click_text("Join address")
	await wait_screen("lobby", 15)
	await wait(2.0)
	expect(find_button("Operator Setup...") != null, "client lobby: the Operator Setup button (the raid kit)")
	await shot("x02_lobby_client")
	await lan_press_ready()


func _extraction_raid(role: String, b: Battle) -> void:
	var x := b.extraction
	expect(x != null, "%s: extraction raid running" % role)
	await wait_for(func() -> bool: return x.containers.size() > 0 and b.player != null, 20.0, "the raid setup")
	expect(x.containers.size() > 0 and x.zones.size() == 3, "%s: caches (%d) and zones from the host" % [role, x.containers.size()])
	var me := b.player as Infantry
	await wait_for(func() -> bool: return is_instance_valid(me) and not me.stowed, 60.0, "the drop-in to land")
	expect(not me.stowed, "%s: dropped in and on foot" % role)
	await shot("x03_landed_" + role)
	if role == "host":
		await _extraction_host_revive(b, x)
		await _extraction_host_callins(b, x)
		await _extraction_host_part(b, x)
	else:
		await _extraction_client_revived(b, x)
		await _extraction_client_callins(b, x)
		await _extraction_client_part(b, x)
	await pass_results("extraction_" + role)


## Host: puts the client's soldier beside his own, downs him, then holds interact by him until he is up.
func _extraction_host_revive(b: Battle, x: ExtractionDirector) -> void:
	var client := _client_peer()
	var mine := b.player as Infantry
	var theirs := b.occupancy.soldier_of(client)
	expect(theirs != null and TeamRelations.is_allied(mine.team, theirs.team), "host: the client is in his squad")
	var spot := b.infantry.make_on_ground(x.zones[0] + Vector3(6, 0, 0))
	mine.global_position = spot + Vector3.UP * 0.3
	theirs.global_position = b.infantry.make_on_ground(spot + Vector3(1.6, 0, 0)) + Vector3.UP * 0.3
	mine.velocity = Vector3.ZERO
	theirs.velocity = Vector3.ZERO
	await wait(1.5)
	theirs.spawn_protection = 0.0
	theirs.apply_spawn_protection()
	theirs.apply_hit(0.0, 1e6, null, theirs.global_position)
	expect(theirs.alive and DownedState.is_downed(theirs), "host: a lethal hit downs the client (teammate up)")
	await wait(1.5)
	expect(InfantryInteraction.of(b).make_hint(mine).contains("revive"), "host: the interact hint offers the revive")
	var hold := InputEventAction.new()
	hold.action = "interact"
	hold.pressed = true
	Input.parse_input_event(hold)
	await wait(0.6)
	await shot("x03b_host_reviving")
	await wait_for(func() -> bool: return not DownedState.is_downed(theirs), 15.0, "the revive")
	var up := hold.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	expect(theirs.alive and not DownedState.is_downed(theirs), "host: the client is revived")
	await wait(1.0)


## Client: waits to be downed (overlay, crawl controls), then to be revived by the host.
func _extraction_client_revived(b: Battle, x: ExtractionDirector) -> void:
	var me := b.player as Infantry
	await wait_for(func() -> bool: return DownedState.is_downed(me), 60.0, "being downed by the host")
	expect(DownedState.is_downed(me) and x.revive.get_node_or_null("DownedPilot") != null, "client: downed, crawl controls on")
	await wait(0.5)
	expect(x.revive.hud.make_downed_text(me).begins_with("bleeding out"), "client: the downed overlay '%s'" % x.revive.hud.make_downed_text(me))
	await shot("x03b_client_downed")
	await wait_for(func() -> bool: return not DownedState.is_downed(me), 30.0, "the host's revive")
	expect(me.alive and not DownedState.is_downed(me) and x.revive.get_node_or_null("DownedPilot") == null, "client: revived, own controls back")


## True when a vehicle of `vehicle_id` stands in the battle (a delivered call-in).
func _has_vehicle(b: Battle, vehicle_id: String) -> bool:
	return b.vehicles.values().any(func(v: Variant) -> bool: return is_instance_valid(v) and v.vehicle_id == vehicle_id and v.alive)


## Host: sees the client's orbital pod (a crate on both sides) and then his vehicle delivery arrive.
func _extraction_host_callins(b: Battle, x: ExtractionDirector) -> void:
	var c := x.callins
	var client := _client_peer()
	expect(await wait_for(func() -> bool: return c.points.get_balance(client) > 0, 30.0, "the client's raid points"),
		"host: the client's raid points reached the host (%d RP)" % c.points.get_balance(client))
	expect(await wait_for(func() -> bool: return c.orders.values().any(func(o: CallinOrder) -> bool: return o.kind == CallinRules.KIND_AMMO and o.peer == client),
		CALLIN_POD_SECONDS, "the client's pod order"), "host: the client's ammo pod order arrived over the LAN")
	expect(await wait_for(func() -> bool: return not c.crates.is_empty(), CALLIN_POD_SECONDS, "the pod's crate"), "host: the pod landed and its crate stands (%d)" % c.crates.size())
	await shot("x03c_host_pod")
	expect(await wait_for(func() -> bool: return c.orders.values().any(func(o: CallinOrder) -> bool: return o.kind == CallinRules.KIND_VEHICLE and o.peer == client),
		CALLIN_VEHICLE_SECONDS, "the client's vehicle order"), "host: the client's vehicle delivery order arrived over the LAN")
	expect(await wait_for(func() -> bool: return _has_vehicle(b, CALLIN_VEHICLE), CALLIN_VEHICLE_SECONDS, "the delivered vehicle"),
		"host: the delivered %s stands in the battle" % CALLIN_VEHICLE)
	await shot("x03d_host_vehicle")


## The player designates ground near his soldier (what the laser does), over the LAN to the host, spot after spot on rings
## around him until the host makes an order (its checks are the host's word: terrain, sky, the approach). True when it did.
func _request_callin_ahead(b: Battle, c: CallinDirector, kind: String) -> bool:
	var me := b.player
	var points_before := c.points.mine
	var reasons := {}
	for ring in CALLIN_RINGS_M:
		for i in CALLIN_DIRECTIONS:
			var spot: Vector3 = me.global_position + Vector3.FORWARD.rotated(Vector3.UP, TAU * float(i) / CALLIN_DIRECTIONS) * ring
			var request := CallinRequest.make(kind, "", Net.my_id(), spot)
			var plan: Dictionary = c.checks.make_plan(request, true)
			if not bool(plan.ok):
				reasons[str(plan.get("reason", ""))] = int(reasons.get(str(plan.get("reason", "")), 0)) + 1
				continue
			c.request_designated(request)
			if await wait_for(func() -> bool: return c.points.mine < points_before, CALLIN_ANSWER_SECONDS):
				return true
	log_line("client: the host made no %s order on any spot around %s (spots refused: %s)" % [kind, me.global_position, reasons])
	return false


## Client: calls in an orbital pod, then his vehicle; both arrive for him and for the host.
func _extraction_client_callins(b: Battle, x: ExtractionDirector) -> void:
	var c := x.callins
	expect(await wait_for(func() -> bool: return c.points.mine > 0, 30.0, "own raid points"), "client: brings %d raid points" % c.points.mine)
	var before := c.points.mine
	expect(c.make_local_refusal(CallinRules.KIND_AMMO, "") == "", "client: the pod is not refused ('%s')" % c.make_local_refusal(CallinRules.KIND_AMMO, ""))
	await _request_callin_ahead(b, c, CallinRules.KIND_AMMO)
	expect(await wait_for(func() -> bool: return c.views.values().any(func(v: Dictionary) -> bool: return v.get("kind") == CallinRules.KIND_AMMO),
		30.0, "the host's order view"), "client: the host's word on the pod order came back")
	expect(await wait_for(func() -> bool: return c.points.mine < before, 10.0, "the pod's price"), "client: the pod was paid in raid points (%d -> %d)" % [before, c.points.mine])
	expect(await wait_for(func() -> bool: return not c.crates.is_empty(), CALLIN_POD_SECONDS, "the pod's crate"), "client: the pod landed and its crate stands (%d)" % c.crates.size())
	await shot("x03c_client_pod")
	await wait_for(func() -> bool: return c.make_local_refusal(CallinRules.KIND_VEHICLE, "") == "", CALLIN_POD_SECONDS, "the shared cooldown")
	expect(c.make_local_refusal(CallinRules.KIND_VEHICLE, "") == "", "client: the vehicle delivery is not refused ('%s')" % c.make_local_refusal(CallinRules.KIND_VEHICLE, ""))
	await _request_callin_ahead(b, c, CallinRules.KIND_VEHICLE)
	expect(await wait_for(func() -> bool: return _has_vehicle(b, CALLIN_VEHICLE), CALLIN_VEHICLE_SECONDS, "the delivered vehicle"),
		"client: the delivered %s stands in his battle" % CALLIN_VEHICLE)
	await shot("x03d_client_vehicle")


func _client_peer() -> int:
	for id in Net.roster:
		if int(id) != 1:
			return int(id)
	return 0


## Host: puts both soldiers beside two caches, loots his own, checks the client's loot, brings the client to the
## landed exfil transport, then dies.
func _extraction_host_part(b: Battle, x: ExtractionDirector) -> void:
	var client := _client_peer()
	var caches := x.containers.values().filter(func(c) -> bool: return not (c as LootContainer).stacks.is_empty())
	var mine := b.player as Infantry
	var theirs := b.occupancy.soldier_of(client)
	for s in [mine, theirs]:   # the factions' squads must not end the flow before the exfil (stray fire, falls)
		(s as Infantry).spawn_protection = 600.0
		(s as Infantry).apply_spawn_protection()
		(s as Infantry).destroyed.connect(func(h: Herc, k: Node) -> void:
			log_line("%s killed by %s (%s) at %s" % [h.display_name, k.name if k else "nothing (world)", h.get_meta(KillText.CAUSE_META, ""), h.global_position]))
	mine.global_position = (caches[0] as LootContainer).position + Vector3(0.6, 0.3, 0)   # caches on roofs: stay on them
	theirs.global_position = (caches[1] as LootContainer).position + Vector3(0.6, 0.3, 0)
	var client_before := JSON.stringify((x.inventories[client] as ExtractionInventory).make_state())
	await wait(1.0)
	var mine_before := JSON.stringify(x.my_inventory.make_state())
	for attempt in 3:   # bots' blasts may push him off a roof: put him back and try again
		mine.global_position = (caches[0] as LootContainer).position + Vector3(0.6, 0.3, 0)
		mine.velocity = Vector3.ZERO
		await wait(0.3)
		_press_action("interact")
		await wait(1.0)
		if JSON.stringify(x.my_inventory.make_state()) != mine_before:
			break
		log_line("host loot attempt %d: soldier %s cache %s" % [attempt, mine.global_position, (caches[0] as LootContainer).position])
	expect(JSON.stringify(x.my_inventory.make_state()) != mine_before, "host looted a cache (%s)" % [x.find_container_near(mine.global_position)])
	await wait_for(func() -> bool: return JSON.stringify((x.inventories[client] as ExtractionInventory).make_state()) != client_before, 20.0, "the client's loot")
	expect(JSON.stringify((x.inventories[client] as ExtractionInventory).make_state()) != client_before, "host: the client's inventory grew (host-authoritative)")
	await wait_for(func() -> bool: return x.transports.exfils.values().any(func(e) -> bool: return e.state == "landed"), 90.0, "the client's exfil to land")
	var landed: Array = x.transports.exfils.values().filter(func(e) -> bool: return e.state == "landed")
	if expect(not landed.is_empty(), "host: the client's exfil transport landed"):
		var t: Herc = b.vehicles.get(int(landed[0].net_id))
		theirs.global_position = t.global_position + Vector3(BoardingRules.make_hull_radius(t) + 0.2, 0.3, 0)
		theirs.velocity = Vector3.ZERO
	await wait_for(func() -> bool: return x.status.get(client) == ExtractionDirector.STATUS_EXTRACTED, 30.0, "the client to extract")
	expect(x.status.get(client) == ExtractionDirector.STATUS_EXTRACTED, "host: the client extracted")
	await shot("x05_host_after_client_exfil")
	mine.spawn_protection = 0.0
	mine.apply_spawn_protection()
	var n := 0
	while mine.alive and n < 20:
		mine.apply_hit(0.0, 1e6, null, mine.global_position)
		n += 1
	await wait(0.5)
	expect(x.my_status == ExtractionDirector.STATUS_DEAD, "host: killed in action")
	expect(x.containers.values().any(func(c) -> bool: return (c as LootContainer).kind == "bag"), "host: his bag lies on the ground")
	await shot("x06_host_killed")


## Client: loots the cache the host put him beside, calls the exfil, waits to be extracted, checks his stash.
func _extraction_client_part(b: Battle, x: ExtractionDirector) -> void:
	var me := b.player as Infantry
	await wait_for(func() -> bool: return x.find_container_near(me.global_position) != null, 30.0, "the host to put us beside a cache")
	var cache := x.find_container_near(me.global_position)
	var cache_id := cache.container_id if cache else -1
	var units := cache.make_item_count() + cache.money if cache else 0
	var before := JSON.stringify(x.my_inventory.make_state())
	_press_action("interact")
	await wait_for(func() -> bool: return JSON.stringify(x.my_inventory.make_state()) != before, 10.0, "our inventory from the host")
	expect(JSON.stringify(x.my_inventory.make_state()) != before, "client: own inventory updated by the host")
	var left := x.containers.get(cache_id) as LootContainer
	expect(left == null or left.make_item_count() + left.money < units, "client: the cache changed on the client")
	await shot("x04_client_looted")
	var carried := x.my_inventory.make_stacks()
	_press_action("exfil_call")
	await wait_for(func() -> bool: return not x.exfil_states.is_empty(), 10.0, "the exfil state")
	expect(not x.exfil_states.is_empty(), "client: the exfil call reached the host and its state came back")
	await wait_for(func() -> bool: return x.my_status == ExtractionDirector.STATUS_EXTRACTED, 120.0, "extraction")
	expect(x.my_status == ExtractionDirector.STATUS_EXTRACTED, "client: extracted")
	await shot("x05_client_extracted")
	var p := ExtractionProfile.load_for(Net.player_name)
	expect(int(p.stats.get("extracted", 0)) == 1 and carried.all(func(s) -> bool: return p.stash.count(str(s[0])) >= 1),
		"client: the haul is in his own stash (%d stacks)" % p.stash.stacks.size())
