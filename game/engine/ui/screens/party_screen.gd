class_name PartyScreen
extends LauncherScreen
## The party: pilots who ready up together and go to one game server together (docs/design/party.md). Built on the lobby's look:
## the members with their ready state and operator summary, the chat, and the leader's choice of destination (a LAN game, an
## online game, or a typed address). Create a party on the master server (online) or on this PC for the LAN, or join one by its
## code or from the LAN list. When everybody is ready the leader presses Go and every member's client connects to the
## chosen server (PartyFlow); after the raid the members come back here. The party itself lives in PartySession.

const GO_TEXT := "Go"
const READY_TEXT := "Ready"
const NOT_READY_TEXT := "Not ready"
const INTRO_TEXT := "A party is a short-lived group: everybody readies up, then the leader sends you all to one game server together, " \
	+ "on one team (in a raid: one squad on one transport). No account is needed."
const NO_CODE_TEXT := "Type the party's code first."
const WAITING_TEXT := "Waiting for the leader to press Go."
const CHOOSE_TEXT := "Choose a server to go to."
## A message (a refusal, the chosen server) stays in the footer this long before the usual hint comes back.
const NOTICE_MSEC := 6000

var session: PartySession
var _start_box: VBoxContainer
var _lan_list: VBoxContainer
var _lan_key := ""
var _code_edit: LineEdit
var _lan_address: LineEdit
var _members: PartyMemberList
var _destination_label: Label
var _picker: ServerPicker
var _chat: PartyChatStrip
var _cancel_button: Button
var _notice_until := 0


func open(_args: Dictionary) -> void:
	set_page_title("party")
	set_back("Back", _leave)
	session = PartySession.ensure(get_tree())
	session.apply_return()
	session.client.changed.connect(_on_changed)
	session.client.ended.connect(_on_ended)
	session.client.failed.connect(_notice)
	session.flow.status_changed.connect(_on_flow_status)
	session.flow.failed.connect(_on_flow_failed)
	Net.parties_changed.connect(_show_lan_parties)
	Net.start_discovery()
	_build()


func _exit_tree() -> void:
	if session == null:
		return
	for pair in [[session.client.changed, _on_changed], [session.client.ended, _on_ended], [session.client.failed, _notice],
			[session.flow.status_changed, _on_flow_status], [session.flow.failed, _on_flow_failed], [Net.parties_changed, _show_lan_parties]]:
		if (pair[0] as Signal).is_connected(pair[1]):
			(pair[0] as Signal).disconnect(pair[1])


func _leave() -> void:
	Net.stop_discovery()
	router.back()


## Shows `text` in the footer for a few seconds, over the hint the party's state would give.
func _notice(text: String) -> void:
	_notice_until = Time.get_ticks_msec() + NOTICE_MSEC
	set_status(text)


func _build() -> void:
	_notice_until = 0   # a new page (a party was made, joined or left) says what it needs to itself
	for c in content.get_children():
		c.queue_free()
		content.remove_child(c)
	_members = null
	_picker = null
	_chat = null
	if session.client.is_in_party():
		_build_party()
	else:
		_build_start()
	_on_changed()


# ------------------------------------------------------------------ no party yet

func _build_start() -> void:
	set_primary("Create LAN party", _create_lan)
	_start_box = VBoxContainer.new()
	content.add_child(_start_box)
	_start_box.add_child(Widgets.paragraph(INTRO_TEXT, "DimLabel"))
	_start_box.add_child(Widgets.section("Create a party"))
	var online := Widgets.button("Create online party", _create_online)
	online.disabled = not OnlineSettings.has_master()
	online.tooltip_text = "Uses the master server of Options > Online." if OnlineSettings.has_master() else PartySession.NO_MASTER_TEXT
	_start_box.add_child(Widgets.row([online, Widgets.button("Create LAN party", _create_lan)]))
	_start_box.add_child(Widgets.section("Join a party"))
	_code_edit = Widgets.line_edit("", "party code, for example K7QWM")
	_code_edit.max_length = PartyRegistry.CODE_LENGTH + 2
	_code_edit.text_submitted.connect(func(_t: String) -> void: _join_online())
	_start_box.add_child(OptionRow.new("Party code", _code_edit))
	var join_online := Widgets.button("Join online party", _join_online)
	join_online.disabled = not OnlineSettings.has_master()
	join_online.tooltip_text = "" if OnlineSettings.has_master() else PartySession.NO_MASTER_TEXT
	_start_box.add_child(Widgets.row([join_online]))
	_start_box.add_child(Widgets.section("LAN parties (auto-discovered)"))
	_lan_list = VBoxContainer.new()
	_lan_key = ""
	_start_box.add_child(_lan_list)
	_lan_address = Widgets.line_edit("", "the leader's IP, when the list stays empty")
	_start_box.add_child(OptionRow.new("Leader's address", _lan_address))
	_start_box.add_child(Widgets.row([Widgets.button("Join LAN party by code", _join_lan_typed)]))
	_show_lan_parties()


func _show_lan_parties() -> void:
	if not is_instance_valid(_lan_list):
		return
	var key := JSON.stringify(Net.parties.keys().map(func(k: String) -> String: return "%s|%s|%s" % [k, Net.parties[k].get("members"), Net.parties[k].get("code")]))
	if key == _lan_key:
		return   # the broadcast arrives every second: rebuilding the rows would take the focus away
	_lan_key = key
	for c in _lan_list.get_children():
		c.queue_free()
	if Net.parties.is_empty():
		_lan_list.add_child(Widgets.label("searching ...", "DimLabel"))
	for k in Net.parties:
		var p: Dictionary = Net.parties[k]
		var text := "%s   %d/%d   code %s" % [p.get("name", "party"), int(p.get("members", 0)), int(p.get("max", 0)), p.get("code", "")]
		var host := str(p.ip)
		var port := int(p.port)
		var code := str(p.get("code", ""))
		var b := Widgets.button(text, func() -> void: _join_lan(host, port, code))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_lan_list.add_child(b)


func _create_online() -> void:
	_start(session.create_online())


func _create_lan() -> void:
	_start(session.create_lan())


func _join_online() -> void:
	if PartyRegistry.make_clean_code(_code_edit.text) == "":
		_notice(NO_CODE_TEXT)
		return
	_start(session.join_online(_code_edit.text))


func _join_lan_typed() -> void:
	if PartyRegistry.make_clean_code(_code_edit.text) == "" or _lan_address.text.strip_edges() == "":
		_notice("Type the party code and the leader's address.")
		return
	_join_lan(_lan_address.text.strip_edges(), PartyLanHost.DEFAULT_PORT, _code_edit.text)


func _join_lan(host: String, port: int, code: String) -> void:
	session.join_lan(host, port, code)
	_notice("Joining the party ...")


func _start(error_text: String) -> void:
	_notice(error_text if error_text != "" else "Contacting the party service ...")


# ------------------------------------------------------------------ in a party

func _build_party() -> void:
	set_primary(READY_TEXT, _on_primary)
	var head := Widgets.label("", "HeaderLabel")
	head.name = "PartyHeader"
	content.add_child(head)
	var columns := HBoxContainer.new()
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(columns)
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(right)
	_members = PartyMemberList.new()
	_members.kick_requested.connect(func(id: int) -> void: session.client.kick(id))
	left.add_child(_members)
	left.add_child(Widgets.row([Widgets.button("Operator Setup...", _open_setup), Widgets.button("Leave party", _ask_leave, Widgets.DANGER)]))
	_chat = PartyChatStrip.new(session.client)
	left.add_child(_chat)
	right.add_child(Widgets.section("Destination"))
	_destination_label = Widgets.paragraph("", "")
	right.add_child(_destination_label)
	_cancel_button = Widgets.button("Cancel trip", func() -> void: session.flow.cancel(), Widgets.DANGER)
	right.add_child(_cancel_button)
	if session.client.am_leader():
		_picker = ServerPicker.new()
		_picker.picked.connect(_on_server_picked)
		right.add_child(_picker)


func _on_server_picked(server: Dictionary) -> void:
	session.client.set_destination(server)
	_notice("Destination: %s" % str(server.get("name", server.get("address", ""))))


func _open_setup() -> void:
	var profile := OperatorProfile.load_for(Net.player_name)
	var settings := GameOptionsModel.make_default_settings(GameOptionsModel.KIND_EXTRACTION, true)
	var setup := OperatorSetupLauncher.open(self, LobbyAnnouncer.make_context(settings, profile), profile.active_slot)
	setup.closed.connect(func(_changed := true) -> void: session.client.set_summary(PartySession.make_my_summary()))


func _ask_leave() -> void:
	ConfirmDialog.ask(self, "Leave the party?", func() -> void:
		session.leave()
		_build(), "Leave", Widgets.DANGER)


func _on_primary() -> void:
	if not session.client.is_in_party():
		return
	if session.client.am_leader():
		session.client.go()
	else:
		session.client.set_ready(not _my_ready())


func _my_ready() -> bool:
	for m: Dictionary in session.client.members():
		if int(m.id) == session.client.my_id():
			return bool(m.ready)
	return false


# ------------------------------------------------------------------ following the party

func _on_changed() -> void:
	if session == null:
		return
	if session.client.is_in_party() != (_members != null):
		_build()
		return
	if _members == null:
		return
	var view := session.client.view
	(content.find_child("PartyHeader", true, false) as Label).text = make_header_text(session)
	_members.refresh(view)
	_destination_label.text = make_destination_text(session.client.destination())
	_cancel_button.visible = session.flow.is_busy()
	_refresh_primary()
	if not session.flow.is_busy() and Time.get_ticks_msec() >= _notice_until:
		set_status(make_status_text(session))


## "Party K7QWM  -  online  -  3 / 8".
static func make_header_text(p_session: PartySession) -> String:
	var view := p_session.client.view
	return "Party %s  -  %s  -  %d / %d members" % [p_session.client.code, "LAN" if p_session.client.lan else "online",
		(view.get("members", []) as Array).size(), int(view.get("max", 0))]


static func make_destination_text(d: Dictionary) -> String:
	if d.is_empty():
		return CHOOSE_TEXT
	return "%s\n[%s]  %s\n%s" % [d.get("name", d.address), d.get("mode", ""), d.get("map", ""), d.address]


## The footer line: why Go waits, or what to do next.
static func make_status_text(p_session: PartySession) -> String:
	var view := p_session.client.view
	if p_session.client.am_leader():
		if (view.get("destination", {}) as Dictionary).is_empty():
			return CHOOSE_TEXT
		var waiting: Array = view.get("waiting", [])
		return "Waiting for %s." % ", ".join(PackedStringArray(waiting)) if not waiting.is_empty() else "Everybody is ready. Press Go."
	return WAITING_TEXT


func _refresh_primary() -> void:
	var busy := session.flow.is_busy()
	if session.client.am_leader():
		primary_button.text = GO_TEXT
		primary_button.disabled = busy or not (session.client.view.get("waiting", []) as Array).is_empty() \
			or (session.client.destination()).is_empty()
	else:
		primary_button.text = NOT_READY_TEXT if _my_ready() else READY_TEXT
		primary_button.disabled = busy


func _on_flow_status(text: String) -> void:
	_notice(text)
	if _cancel_button != null:
		_cancel_button.visible = session.flow.is_busy()
	if _members != null:
		_refresh_primary()


func _on_flow_failed(reason: String) -> void:
	_notice(reason)
	if _members != null:
		_refresh_primary()


func _on_ended(reason: String) -> void:
	_build()
	_notice(reason)
