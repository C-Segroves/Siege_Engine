class_name ShellCareers
extends RefCounted
## The registered pilots' careers. A career is its pilot's Earthsiege campaign autosave in the shared save
## store (SaveGames): the app's Earthsiege campaigns and the shell's careers are the same files, so a
## pilot started in either front end goes on in the other. A career dictionary is the shell's record
## {name, campaign, slot, missions, kills, new, next_mission, over, victory, debriefed, playtime, registered}
## plus "campaign_state" (Campaign.to_dict(), with the garage); its save keeps the record under "shell".
## Careers of earlier versions (user://es1_careers.json) are moved into the store once.

## In the current store (UserStore).
static var LEGACY_FILE: String:
	get: return UserStore.path("es1_careers.json")
static var LEGACY_MOVED_FILE: String:
	get: return UserStore.path("es1_careers.moved.json")
const FIRST_MISSION := "B0_C0_0A"
const CAMPAIGN_KEY := "es1"
const STATE := "campaign_state"
const RESTORE_POINT_NAME := "%s - before mission %s"

var list: Array = []


## Reads every Earthsiege pilot's autosave, in registration order.
func load_all() -> void:
	move_legacy_file()
	list = []
	for e in SaveGames.list_entries():
		if e.kind == SaveGames.KIND_AUTOSAVE and e.campaign_key == CAMPAIGN_KEY:
			var d := SaveGames.read(str(e.id))
			if not d.is_empty():
				list.append(make_career(d))
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("registered", 0.0)) < float(b.get("registered", 0.0)))


## Writes `current` as its pilot's autosave (and keeps it in the list). The current career carries the
## play clock's time.
func save(current: Dictionary) -> void:
	if current.is_empty():
		return
	if is_same(current, EsShell.career):
		current["playtime"] = SaveGames.clock_seconds()
	var i := index_of(str(current.get("name", "")))
	if i >= 0:
		list[i] = current
	else:
		list.append(current)
	SaveGames.write(autosave_id(str(current.name)), make_save(current, SaveGames.KIND_AUTOSAVE, str(current.name)))


func names() -> Array:
	return list.map(func(c): return c.name)


## Index of the career called `career_name` (-1 if none; case does not matter, see has_name).
func index_of(career_name: String) -> int:
	for i in list.size():
		if str(list[i].name).to_upper() == career_name.to_upper():
			return i
	return -1


## True when a career is already registered as `career_name` (case does not matter: the shell's
## edit box types capitals, older career files may not).
func has_name(career_name: String) -> bool:
	return index_of(career_name) >= 0


## A new pilot's career (first campaign, first mission), appended to the list.
func make_new(pilot_name: String) -> Dictionary:
	var c := {"name": pilot_name, "campaign": 0, "slot": 0, "missions": 0, "kills": 0, "new": true,
		"next_mission": FIRST_MISSION, "registered": Time.get_unix_time_from_system(), "playtime": 0.0}
	list.append(c)
	return c


## Throw-away TEST career for the --shell=menu:<hangar screen> test targets (never in the list).
static func make_test() -> Dictionary:
	return {"name": "TEST", "campaign": 0, "slot": 0, "missions": 0, "kills": 0, "next_mission": FIRST_MISSION}


## Deletes career `i`: its autosave and restore point (named backups stay).
func remove_at(i: int) -> Dictionary:
	var gone: Dictionary = list[i]
	list.remove_at(i)
	SaveGames.delete(autosave_id(str(gone.name)))
	SaveGames.delete(SaveGames.make_restore_point_id(CAMPAIGN_KEY, str(gone.name)))
	return gone


# ------------------------------------------------------------------ saves

static func autosave_id(pilot: String) -> String:
	return SaveGames.make_autosave_id(CAMPAIGN_KEY, pilot)


## The "before mission" restore point of `career` (written when its mission is launched).
static func save_restore_point(career: Dictionary) -> void:
	if is_same(career, EsShell.career):
		career["playtime"] = SaveGames.clock_seconds()
	var save_name := RESTORE_POINT_NAME % [str(career.name), str(career.get("next_mission", ""))]
	SaveGames.write(SaveGames.make_restore_point_id(CAMPAIGN_KEY, str(career.name)),
		make_save(career, SaveGames.KIND_RESTORE_POINT, save_name))


## The career as its restore point left it ({} when there is none).
static func load_restore_point(pilot: String) -> Dictionary:
	var d := SaveGames.read(SaveGames.make_restore_point_id(CAMPAIGN_KEY, pilot))
	return make_career(d) if not d.is_empty() else {}


## The save of `career` (kind `kind`, called `save_name`): its campaign plus the shell's record.
static func make_save(career: Dictionary, kind: String, save_name: String) -> Dictionary:
	MissionLaunch.ensure_campaign_state(career)
	var record := career.duplicate(true)
	record.erase(STATE)
	var info := {"pilot": str(career.name), "playtime": float(career.get("playtime", 0.0)), "coop": false,
		"kind": kind, "name": save_name, "classic": bool(career.get("classic", false))}
	var d := SaveGames.make_save(Campaign.from_dict(career[STATE]), null, info)
	d["shell"] = record
	return d


## The career a save holds (an app campaign's save gets a fresh record).
static func make_career(d: Dictionary) -> Dictionary:
	var career: Dictionary = (d.get("shell", {}) as Dictionary).duplicate(true) if d.get("shell") is Dictionary else {}
	var state: Dictionary = d.get("campaign", {})
	career["name"] = str(d.get("pilot", SaveGames.DEFAULT_PILOT))
	career[STATE] = state.duplicate(true)
	career["campaign"] = int(state.get("campaign", 0))
	career["slot"] = int(state.get("slot", 0))
	career["next_mission"] = str(state.get("mission", FIRST_MISSION))
	career["over"] = str(state.get("state", Campaign.STATE_PLAYING)) != Campaign.STATE_PLAYING
	career["victory"] = str(state.get("state", "")) == Campaign.STATE_VICTORY
	career["playtime"] = float(d.get("playtime", 0.0))
	return career


## Earlier versions kept every career in one file: each becomes its pilot's autosave (unless the store
## already has one), and the file is renamed so it is moved only once.
static func move_legacy_file() -> void:
	if not FileAccess.file_exists(LEGACY_FILE):
		return
	var j = JSON.parse_string(FileAccess.get_file_as_string(LEGACY_FILE))
	if not j is Array:
		push_error("ShellCareers: ignoring unreadable %s" % LEGACY_FILE)
		return
	for i in (j as Array).size():
		var c = j[i]
		if c is Dictionary and str(c.get("name", "")) != "" and not SaveGames.exists(autosave_id(str(c.name))):
			c["registered"] = float(c.get("registered", i))
			SaveGames.write(autosave_id(str(c.name)), make_save(c, SaveGames.KIND_AUTOSAVE, str(c.name)))
	DirAccess.rename_absolute(ProjectSettings.globalize_path(LEGACY_FILE), ProjectSettings.globalize_path(LEGACY_MOVED_FILE))
