class_name ShellBackups
extends RefCounted
## CAREER BACKUPS (MENU1220) on the shared save store (SaveGames), so the shell and the app's Save / Load
## screen see the same saves. SAVE writes the current career as a named save called after its pilot (the
## original kept one backup per career); an existing one asks first (MENU1240 "You already have a backup
## of <name>", OVERWRITE). RESTORE makes the selected save the current career and its pilot's autosave.
## The list (1223) holds the Earthsiege campaigns' named saves and "before mission" restore points of
## every front end, newest first; a finished campaign's save is not restored.

const LIST_ID := 1223
const SAVE_ID := 1221
const RESTORE_ID := 1222
const NAME_TEXT_ID := 1223           # MENU1240's text line naming the backup
const NO_CAREER := "SELECT A CAREER FIRST."
const SAVED := "BACKUP OF %s SAVED."
const RESTORED := "CAREER %s RESTORED."
const FINISHED := "THAT CAMPAIGN IS OVER. CHOOSE ANOTHER BACKUP."

var shell: EsShell
## The backup name SAVE is about to write (MENU1240 shows it).
var pending_name := ""


func _init(p_shell: EsShell) -> void:
	shell = p_shell


## The Earthsiege saves the list shows: named saves and restore points, newest first.
static func entries() -> Array:
	return SaveGames.list_entries().filter(func(e: Dictionary) -> bool:
		return e.kind != SaveGames.KIND_AUTOSAVE and e.campaign_key == ShellCareers.CAMPAIGN_KEY)


static func make_items() -> Array:
	return entries().map(func(e: Dictionary) -> String: return str(e.name).to_upper())


## Runs command `cid` of CAREER BACKUPS menu `m`; returns whether it was one of its own.
func run(m: ShellMenu, cid: int) -> bool:
	match cid:
		SAVE_ID:
			ask_save()
		RESTORE_ID:
			var l := m.find(LIST_ID)
			restore(int(l.get("sel", -1)))
		_:
			return false
	return true


## SAVE: the current career as a backup named after its pilot (asks first when one exists).
func ask_save() -> void:
	if EsShell.career.is_empty():
		shell.toast(NO_CAREER)
		return
	pending_name = str(EsShell.career.name)
	if SaveGames.exists(SaveGames.make_manual_id(pending_name)):
		shell.open_menu(EsShell.OVERWRITE_BACKUP_MENU)
	else:
		save_pending()


## Writes the backup SAVE asked for.
func save_pending() -> void:
	if EsShell.career.is_empty() or pending_name == "":
		return
	SaveGames.write(SaveGames.make_manual_id(pending_name),
		ShellCareers.make_save(EsShell.career, SaveGames.KIND_MANUAL, pending_name))
	shell.toast(SAVED % pending_name.to_upper())
	shell.refresh(shell.top())


## RESTORE: list entry `sel` becomes the current career (its pilot's autosave is rewritten).
func restore(sel: int) -> void:
	var list := entries()
	if sel < 0 or sel >= list.size():
		return
	var e: Dictionary = list[sel]
	if not SaveGames.is_continuable(e):
		shell.toast(FINISHED)
		return
	var career := ShellCareers.make_career(SaveGames.read(str(e.id)))
	EsShell.career = career
	SaveGames.reset_clock(float(career.get("playtime", 0.0)))
	shell.careers.save(career)
	shell.close_popup()
	shell.toast(RESTORED % str(career.name).to_upper())
