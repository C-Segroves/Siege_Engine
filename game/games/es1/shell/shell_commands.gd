class_name ShellCommands
extends RefCounted
## What the shell's buttons and lists do: per-screen commands first, then the DLG defaults
## (99 cancel, 100 OK, 101 / 102 list up / down, any other id that is a DLG opens that menu).

const LIST_UP := 101
const LIST_DOWN := 102
const PARAM_BUTTONS := [1111, 1112, 1113, 1114, 1115]   # MENU1110: each steps list id + 5
const PARAM_LIST_OFFSET := 5
const SCREEN_EXIT_IDS := [EsShell.CANCEL_ID, EsShell.OK_ID]
const UNARMED_MENU := 3000
const QUIT_MENU := 999
const DELETE_CAREER_MENU := 1270     # "Are you sure you want to delete this career?"
const DUPLICATE_CAREER := "A PILOT NAMED %s IS ALREADY REGISTERED. CHOOSE ANOTHER NAME."

var shell: EsShell


func _init(p_shell: EsShell) -> void:
	shell = p_shell


## Runs command `cid` of menu `m`.
func run(m: ShellMenu, cid: int) -> void:
	if _run_app_command(cid) or _run_screen_command(m, cid):
		return
	match cid:
		EsShell.CANCEL_ID:
			shell.close_popup()
		EsShell.OK_ID:
			shell.close_popup()   # a popup closes, a full screen goes back
		LIST_UP, LIST_DOWN:
			var l := m.first_list()
			m.scroll(l, -1 if cid == LIST_UP else 1)
			select(m, l)
		_:
			if ShellData.has_dlg(cid):
				shell.open_menu(cid)


func _run_app_command(cid: int) -> bool:
	if cid == EsShell.MULTIPLAYER_CMD:
		shell.open_multiplayer()
	elif cid == EsShell.LAUNCHER_CMD:
		shell.switch_scene(EsShell.LAUNCHER_SCENE)
	else:
		return false
	return true


func _run_screen_command(m: ShellMenu, cid: int) -> bool:
	match m.id:
		EsShell.MAIN_MENU:
			return _run_main(cid)
		QUIT_MENU:
			return _run_if(cid == EsShell.OK_ID, shell.sequences.play_quit)
		EsShell.OPTIONS_MENU:
			return _run_options(cid)
		EsShell.PARAMS_MENU:
			return _run_params(m, cid)
		EsShell.SINGLE_MENU:
			return _run_if(cid == EsShell.SINGLE_BRIEFING_MENU, _open_single_briefing)
		EsShell.SINGLE_BRIEFING_MENU:
			return _run_single_briefing(cid)
		EsShell.BRIEFING_MENU:
			return _run_career_briefing(cid)
		EsShell.HANGAR_HUB:
			return _run_hub(cid, EsShell.OK_ID, shell.missions.launch_current)
		EsShell.HANGAR_HUB_DEBRIEFED:
			return _run_hub(cid, 1499, _proceed_after_debriefing)
		UNARMED_MENU:
			return _run_unarmed_warning(cid)
		EsShell.CAREER_MENU:
			return _run_career_menu(cid)
		EsShell.REGISTER_MENU:
			return _run_if(cid == EsShell.OK_ID, _create_career.bind(m))
		EsShell.BACKUPS_MENU:
			return shell.backups.run(m, cid)
		EsShell.OVERWRITE_BACKUP_MENU:
			return _run_if(cid == EsShell.OK_ID, _overwrite_backup)
		DELETE_CAREER_MENU:
			return _run_if(cid == EsShell.OK_ID, _confirm_delete_career)
		EsShell.KILLED_MENU:
			return _run_if(cid == EsShell.REPLAY_CMD, shell.missions.replay_mission)
		1610:
			return _run_if(cid in SCREEN_EXIT_IDS, _return_to_hub)
	return false


## Service bay hub: ARMING / REPAIR / BUILD open the Hangar screen, CREW its Crew tab, `go_id` runs
## `go` (the mission).
func _run_hub(cid: int, go_id: int, go: Callable) -> bool:
	if cid in ShellHangar.HANGAR_COMMANDS:
		shell.hangar.open_hangar()
		return true
	if cid == ShellHangar.CREW_COMMAND:
		shell.hangar.open_hangar(HangarScreen.TAB_CREW)
		return true
	return _run_if(cid == go_id, go)


## Calls `action` when `condition` holds; returns whether it did.
static func _run_if(condition: bool, action: Callable) -> bool:
	if condition:
		action.call()
	return condition


func _run_main(cid: int) -> bool:
	match cid:
		1499:
			shell.start_instant_action()
		EsShell.HANGAR_HUB:
			if EsShell.career.is_empty():
				shell.goto_menu(EsShell.CAREER_MENU)
			elif not _refuse_finished_career():
				shell.goto_menu(EsShell.HANGAR_HUB)
		1003:
			shell.open_menu(QUIT_MENU)
		_:
			return false
	return true


func _run_options(cid: int) -> bool:
	match cid:
		1302:
			shell.sequences.play_credits()
		EsShell.OK_ID:
			shell.close_popup()
		_:
			return false
	return true


## MISSION PARAMETERS: the buttons step their value lists; OK keeps the values.
func _run_params(m: ShellMenu, cid: int) -> bool:
	if cid in PARAM_BUTTONS:
		var l := m.find(cid + PARAM_LIST_OFFSET)
		if not l.is_empty() and not l.items.is_empty():
			l.sel = (l.sel + 1) % l.items.size()
			EsShell.single.params[cid + PARAM_LIST_OFFSET] = l.sel
		return true
	if cid == EsShell.OK_ID:
		for k in EsShell.PARAM_VALUES:
			EsShell.single.params[k] = m.find(k).sel
		shell.close_popup()
		return true
	return false


func _open_single_briefing() -> void:
	shell.briefing_text = shell.missions.make_single_briefing()
	shell.goto_menu(EsShell.SINGLE_BRIEFING_MENU)


func _run_single_briefing(cid: int) -> bool:
	match cid:
		EsShell.OK_ID:
			shell.missions.launch_current()
		EsShell.CANCEL_ID:
			shell.goto_menu(EsShell.SINGLE_MENU)
		_:
			return false
	return true


func _run_career_briefing(cid: int) -> bool:
	match cid:
		EsShell.OK_ID:
			shell.missions.launch_current()
		EsShell.CANCEL_ID:
			_return_to_hub()
		EsShell.HANGAR_HUB:
			shell.goto_menu(EsShell.HANGAR_HUB)
		_:
			return false
	return true


func _run_unarmed_warning(cid: int) -> bool:
	match cid:
		EsShell.OK_ID:
			shell.stack.pop_back()
			shell.missions.launch_current_anyway()
		EsShell.CANCEL_ID:
			shell.close_popup()
		_:
			return false
	return true


func _run_career_menu(cid: int) -> bool:
	match cid:
		EsShell.HANGAR_HUB:
			if EsShell.career.is_empty():
				shell.open_menu(EsShell.REGISTER_MENU)
			elif not _refuse_finished_career():
				shell.missions.career_proceed()
		1201:
			shell.open_menu(DELETE_CAREER_MENU)
		_:
			return false
	return true


## A finished career (won or lost) is not flown on: CAREER OVER "Please restore a backup to replay this
## career." (MENU1260). Returns whether it refused.
func _refuse_finished_career() -> bool:
	if not bool(EsShell.career.get("over", false)):
		return false
	shell.open_menu(EsShell.CAREER_OVER_MENU)
	return true


## OVERWRITE on "You already have a backup of <name>".
func _overwrite_backup() -> void:
	shell.close_popup()
	shell.backups.save_pending()


func _proceed_after_debriefing() -> void:
	EsShell.career["debriefed"] = false
	shell.missions.career_proceed()


func _return_to_hub() -> void:
	shell.goto_menu(EsShell.HANGAR_HUB_DEBRIEFED if EsShell.career.get("debriefed", false) else EsShell.HANGAR_HUB)


# ------------------------------------------------------------------ lists and gadgets

## A list selection or gadget click `c` on menu `m`.
func select(_m: ShellMenu, c: Dictionary) -> void:
	var cid := int(c.id)
	match cid:
		1101:
			EsShell.single.type = c.sel
		1202:
			if c.sel >= 0 and c.sel < shell.careers.list.size():
				EsShell.career = shell.careers.list[c.sel]
				SaveGames.reset_clock(float(EsShell.career.get("playtime", 0.0)))
		_:
			if EsShell.PARAM_VALUES.has(cid):
				EsShell.single.params[cid] = c.sel


# ------------------------------------------------------------------ careers

func _create_career(m: ShellMenu) -> void:
	var e := m.find(103, ShellMenu.T_EDIT)
	var n: String = e.text.strip_edges() if not e.is_empty() else ""
	if n == "":
		return
	if shell.careers.has_name(n):
		shell.toast(DUPLICATE_CAREER % n)
		return
	EsShell.career = shell.careers.make_new(n)
	SaveGames.reset_clock(0.0)
	MissionLaunch.ensure_campaign_state(EsShell.career)
	shell.careers.save(EsShell.career)
	shell.close_popup()


func _confirm_delete_career() -> void:
	shell.close_popup()
	_delete_career()


func _delete_career() -> void:
	var l := shell.top().find(1202)
	if l.is_empty() or l.sel < 0 or l.sel >= shell.careers.list.size():
		return
	var gone := shell.careers.remove_at(l.sel)
	if EsShell.career.get("name", "") == gone.name:
		EsShell.career = {}
	shell.refresh(shell.top())
