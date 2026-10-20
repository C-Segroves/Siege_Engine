class_name ShellMenuContent
extends RefCounted
## What the shell's menus show beyond the DLG layouts: remake additions (MULTIPLAYER, DEV LAUNCHER, REPLAY),
## per-menu setup, list contents (overridable through EsShell.list_providers) and the text gadgets
## (briefing, debriefing, pilot record; custom ones through EsShell.gadget_handlers).

const SPACE_SCANCODE := 57

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


## Remake-specific additions and per-menu runtime state.
func customize(m: ShellMenu) -> void:
	match m.id:
		EsShell.MAIN_MENU:
			_customize_main(m)
		EsShell.OPTIONS_MENU:
			_customize_options(m)
		EsShell.PARAMS_MENU:
			for k in EsShell.PARAM_VALUES:
				m.set_items(k, EsShell.PARAM_VALUES[k], int(EsShell.single.params.get(k, 0)))
		EsShell.REGISTER_MENU:
			var e := m.find(103, ShellMenu.T_EDIT)
			if not e.is_empty():
				m.focus = m.controls.find(e)
			shell.pending_classic = false
			m.add_button(classic_label(false), EsShell.CLASSIC_CMD, Rect2i(24, 66, 80, 11))
		EsShell.OVERWRITE_BACKUP_MENU:
			m.find(ShellBackups.NAME_TEXT_ID, ShellMenu.T_TEXT).label = shell.backups.pending_name.to_upper()
		EsShell.KILLED_MENU:
			_customize_killed(m)
		EsShell.HANGAR_HUB:
			m.find(EsShell.OK_ID).enabled = true
			MissionLaunch.ensure_campaign_state(EsShell.career)
		EsShell.BRIEFING_MENU, EsShell.SINGLE_BRIEFING_MENU:
			shell.briefing_text = shell.missions.make_briefing_with_herc(
				shell.briefing_text if m.id == EsShell.SINGLE_BRIEFING_MENU else shell.missions.make_career_briefing(), m.id == EsShell.BRIEFING_MENU)


## Label of the CLASSIC toggle on the registration menu.
static func classic_label(on: bool) -> String:
	return "CLASSIC: ON" if on else "CLASSIC: OFF"


## MULTIPLAYER sits in the original grid next to a re-centred EXIT TO DOS.
func _customize_main(m: ShellMenu) -> void:
	var ex := m.find(1003)
	if not ex.is_empty():
		ex.r = Rect2i(m.origin + Vector2i(112, 80), Vector2i(85, 13))
	m.add_button("MULTIPLAYER", EsShell.MULTIPLAYER_CMD, Rect2i(25, 80, 85, 13))
	m.find(EsShell.HANGAR_HUB).enabled = not EsShell.career.is_empty()


## Killed in action (MENU1250): REPLAY (fly the mission again from the career's restore point) right of
## DONE, in MENU1270's two-button layout.
func _customize_killed(m: ShellMenu) -> void:
	var done := m.find(EsShell.CANCEL_ID)
	if not done.is_empty():
		done.r = Rect2i(m.origin + Vector2i(26, 89), Vector2i(83, 13))
	m.add_button("REPLAY", EsShell.REPLAY_CMD, Rect2i(115, 89, 83, 13), SPACE_SCANCODE)


## OPTIONS: DEV LAUNCHER entry; the RETURN button names the screen it returns to.
func _customize_options(m: ShellMenu) -> void:
	m.add_button("DEV LAUNCHER", EsShell.LAUNCHER_CMD, Rect2i(68, 78, 86, 13))
	var ret := m.find(EsShell.OK_ID)
	var parent := int(shell.history.back()) if not shell.history.is_empty() else EsShell.MAIN_MENU
	var extra: Array = m.data.get("extra_strings", [])
	if parent == EsShell.SINGLE_MENU and extra.size() > 0:
		ret.label = extra[0]
	elif parent in [EsShell.CAREER_MENU, EsShell.HANGAR_HUB, EsShell.HANGAR_HUB_DEBRIEFED] and extra.size() > 1:
		ret.label = extra[1]
	m.find(1301).enabled = false
	m.find(1320).enabled = false


## Fills lists from providers (overridable through EsShell.list_providers).
func refresh(m: ShellMenu) -> void:
	if m == null:
		return
	for c in m.controls:
		if int(c.type) != ShellMenu.T_LIST or EsShell.PARAM_VALUES.has(int(c.id)):
			continue
		var cid := int(c.id)
		if shell.list_providers.has(cid):
			m.set_items(cid, shell.list_providers[cid].call(m, c))
		else:
			_fill_list(m, cid)


func _fill_list(m: ShellMenu, cid: int) -> void:
	match cid:
		1002:
			m.set_items(cid, [EsShell.career.get("name", "")] if not EsShell.career.is_empty() else [])
		1101:
			m.set_items(cid, EsShell.SINGLE_TYPES.map(func(t): return t[0]), int(EsShell.single.type))
		1202:
			var i := shell.careers.index_of(str(EsShell.career.get("name", "")))
			m.set_items(cid, shell.careers.names(), i if i >= 0 else ShellMenu.KEEP_SELECTION)
		ShellBackups.LIST_ID:
			m.set_items(cid, ShellBackups.make_items())
		1331:
			m.set_items(cid, ["BATTLESET 0", "BATTLESET 1", "BATTLESET 2"], 0)


## Draws gadget `c` of menu `m`: custom handlers, then the text gadgets.
func draw_gadget(m: ShellMenu, c: Dictionary, img: Image) -> void:
	var cid := int(c.id)
	if shell.gadget_handlers.has(cid):
		shell.gadget_handlers[cid].call(m, c, img)
	else:
		var text := _make_gadget_text(cid)
		if text != "":
			_draw_text_block(img, c.r, text, "NM_GREEN")


func _make_gadget_text(cid: int) -> String:
	match cid:
		1502:
			return shell.briefing_text
		1522:
			return shell.debrief_text
		1231:
			if not EsShell.career.is_empty():
				return "PILOT: %s\nCAMPAIGN: %d\nMISSIONS FLOWN: %d\nKILLS: %d" % [EsShell.career.name,
					int(EsShell.career.get("campaign", 0)) + 1, int(EsShell.career.get("missions", 0)), int(EsShell.career.get("kills", 0))]
	return ""


func _draw_text_block(img: Image, r: Rect2i, text: String, font_name: String) -> void:
	var f := ShellData.font(font_name)
	var y := r.position.y + 3
	for line in f.wrap(text, r.size.x - 6):
		if y + f.height > r.end.y:
			break
		f.draw(img, r.position.x + 3, y, line)
		y += f.height + 1
