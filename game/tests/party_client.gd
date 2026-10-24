extends Node
## One member of a party for tests/party_check.gd: a client process that runs the real launcher on the party screen and uses it as a
## player would (buttons, fields), reporting with "PTY <name> <what>" lines on stdout.
##   godot --headless --audio-driver Dummy --path game res://tests/party_client.tscn -- --role=leader|member --name=PartyLead
##       --kind=online|lan --master=127.0.0.1:47720 --server=127.0.0.1:47780 [--code=K7QWM] [--lan-host=127.0.0.1] [--expect=3] [--no-discovery]
## leader: creates the party (PARTY CODE <code>), says hello, waits for --expect members, all ready, picks --server as the destination
##         (typed address) and presses Go (GO).
## member: joins by the code (online: the master; lan: the leader's address), presses Ready (READY), reads the chat line (CHAT ok).
## both:   the game starts (BATTLE late), then RaidWatch's lines (LANDED, TEAM, SEES, RESULT, RESULTS), then Continue: the party
##         screen again (BACK <members> <me away?>).

const HELLO_TEXT := "hello party"
const STEP_SECONDS := 60.0
const BATTLE_SECONDS := 420.0

var _name := "PartyLead"
var _role := "leader"
var _kind := "online"
var _master := "127.0.0.1:47720"
var _server := "127.0.0.1:47780"
var _code := ""
var _lan_host := "127.0.0.1"
var _expect := 2
var _launcher: Launcher
var _session: PartySession


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and "=" in a:
			var value := a.get_slice("=", 1)
			match a.get_slice("=", 0):
				"--role": _role = value
				"--name": _name = value
				"--kind": _kind = value
				"--master": _master = value
				"--server": _server = value
				"--code": _code = value
				"--lan-host": _lan_host = value
				"--expect": _expect = int(value)
		elif a == "--no-discovery":
			Net.discovery_enabled = false
	Net.player_name = _name
	OnlineSettings.apply_master(_master if _kind == "online" else "")
	_run.call_deferred()


func _say(text: String) -> void:
	print("PTY %s %s" % [_name, text])


func _fail(why: String) -> void:
	_say("FAILED %s" % why)
	get_tree().quit(1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _run() -> void:
	_launcher = load("res://launcher.tscn").instantiate()
	_launcher.set_meta("start_mode", Launcher.PARTY_START_MODE)
	get_tree().root.add_child(_launcher)
	get_tree().current_scene = _launcher
	if not await _wait_for(func() -> bool: return _launcher.current_name == "party", STEP_SECONDS):
		_fail("no party screen")
		return
	_session = PartySession.ensure(get_tree())
	await _wait_for(func() -> bool: return _session.is_inside_tree(), STEP_SECONDS)
	if _role == "leader":
		await _lead()
	else:
		await _join()
	var battle := await _wait_for_battle()
	if battle == null:
		_fail("no battle")
		return
	var watch := RaidWatch.new(battle, _say)
	add_child(watch)
	var results: MatchResults = await watch.run()
	await _come_back(results)


## The party screen of the launcher.
func _screen() -> PartyScreen:
	return _launcher.current as PartyScreen


func _press(text: String) -> bool:
	var b := _find_button(_screen(), text)
	if b == null or b.disabled:
		return false
	b.pressed.emit()
	return true


func _find_button(root: Node, text: String) -> Button:
	for c in root.get_children():
		if c is Button and (c as Button).text.begins_with(text) and (c as Button).is_visible_in_tree():
			return c
		var found := _find_button(c, text)
		if found != null:
			return found
	return null


func _find_edit(root: Node, placeholder: String) -> LineEdit:
	for c in root.get_children():
		if c is LineEdit and (c as LineEdit).placeholder_text.begins_with(placeholder):
			return c
		var found := _find_edit(c, placeholder)
		if found != null:
			return found
	return null


func _lead() -> void:
	await _wait_for(func() -> bool: return _press("Create online party" if _kind == "online" else "Create LAN party"), STEP_SECONDS)
	if not await _wait_for(func() -> bool: return _session.client.is_in_party(), STEP_SECONDS):
		_fail("the party was not created: %s" % _screen().status_text())
		return
	_say("PARTY CODE %s %s" % [_session.client.code, _kind])
	_session.client.say(HELLO_TEXT)
	var members_ok := await _wait_for(func() -> bool:
		return _session.client.members().size() >= _expect and (_session.client.view.get("waiting", []) as Array).is_empty(), BATTLE_SECONDS)
	_say("MEMBERS %d" % _session.client.members().size() if members_ok else "FAILED members %d" % _session.client.members().size())
	await _wait_for(func() -> bool: return _screen()._picker != null, STEP_SECONDS)
	_find_edit(_screen(), ServerPicker.SERVER_HINT).text = _server
	await _wait_for(func() -> bool: return _press("Use this address") and not _session.client.destination().is_empty(), STEP_SECONDS)
	await _wait_for(func() -> bool: return not _session.client.destination().is_empty(), STEP_SECONDS)
	_say("DESTINATION %s" % str(_session.client.destination().get("address", "")))
	await _wait_for(func() -> bool: return not _screen().primary_button.disabled, STEP_SECONDS)
	_screen().primary_button.pressed.emit()
	_say("GO")


func _join() -> void:
	if _kind == "online":
		_find_edit(_screen(), "party code").text = _code
		await _wait_for(func() -> bool: return _press("Join online party"), STEP_SECONDS)
	else:
		_find_edit(_screen(), "party code").text = _code
		_find_edit(_screen(), "the leader's IP").text = _lan_host
		await _wait_for(func() -> bool: return _press("Join LAN party by code"), STEP_SECONDS)
	if not await _wait_for(func() -> bool: return _session.client.is_in_party(), STEP_SECONDS):
		_fail("could not join: %s" % _screen().status_text())
		return
	_say("JOINED %d" % _session.client.members().size())
	var heard := await _wait_for(func() -> bool: return _session.client.chat.any(func(l: Dictionary) -> bool: return str(l.text) == HELLO_TEXT), STEP_SECONDS)
	_say("CHAT ok" if heard else "FAILED chat")
	await _wait_for(func() -> bool: return _screen().primary_button.text == PartyScreen.READY_TEXT and _press(PartyScreen.READY_TEXT), STEP_SECONDS)
	await _wait_for(func() -> bool: return _screen()._my_ready(), STEP_SECONDS)
	_say("READY")


func _wait_for_battle() -> Battle:
	var found: Array = [null]
	await _wait_for(func() -> bool:
		for c in get_tree().root.get_children():
			if c is Battle and (c as Battle).extraction != null:
				found[0] = c
				return true
		return false, BATTLE_SECONDS)
	return found[0] as Battle


## Continue on the results screen: the launcher opens the party screen again and the service hears the pilot is back.
func _come_back(results: MatchResults) -> void:
	if results == null:
		_fail("no results screen")
		return
	results.continue_to_front_end()
	var back := await _wait_for(func() -> bool:
		var l := get_tree().current_scene as Launcher
		return l != null and l.current_name == "party", STEP_SECONDS)
	_launcher = get_tree().current_scene as Launcher
	if not back:
		_fail("the party screen did not come back")
		return
	var away := await _wait_for(func() -> bool:
		for m: Dictionary in _session.client.members():
			if int(m.id) == _session.client.my_id():
				return not bool(m.in_raid)
		return false, STEP_SECONDS)
	_say("BACK %d %s" % [_session.client.members().size(), "present" if away else "still away"])
	await get_tree().create_timer(1.5).timeout
	get_tree().quit(0)
