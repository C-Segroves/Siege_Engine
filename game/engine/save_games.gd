class_name SaveGames
extends RefCounted
## The one campaign save store (user://saves/<id>.json) of every campaign and front end: the app's
## launcher (New campaign, Save / Load, Continue) and the original Earthsiege shell (its careers and its
## CAREER BACKUPS menu) read and write the same files.
##
## Kinds of save:
##   autosave       one per campaign and pilot, rewritten after every finished mission and hangar change;
##   restore point  one per campaign and pilot, "before mission": written when a mission is launched; a
##                  killed pilot reloads it and flies the mission again (Earthsiege 2 autosaves slot 10 every
##                  time the shell hands off to the sim and its "You were killed. Replay?" reloads it,
##                  docs/formats/es2_campaign_flow.md);
##   manual         named by the player, between missions only (the originals never saved mid-mission).
## A save: {"meta": make_meta(), "pilot", "playtime" (seconds), "coop", and "saga": Saga.to_dict() or
## "pack" + "campaign" (the provider's to_dict()); the Earthsiege shell adds "shell" (its career record) and
## a restore point "launch" (the Herc the mission was flown in: {vehicle, loadout, garage}).
## The play clock counts the running campaign's playtime (reset_clock when a campaign starts or loads).

## The store's folder (UserStore: the player's, or a test store); read it each time, it is not a constant.
static var DIR: String:
	get: return UserStore.path("saves")
const EXTENSION := ".json"
const KIND_AUTOSAVE := "autosave"
const KIND_RESTORE_POINT := "restore_point"
const KIND_MANUAL := "manual"
const KIND_NAMES := {KIND_AUTOSAVE: "autosave", KIND_RESTORE_POINT: "before mission", KIND_MANUAL: "saved game"}
## The single autosave slot of earlier versions (no meta; still listed and loadable).
const LEGACY_AUTOSAVE := "autosave"
const LEGACY_NAME := "Autosave (earlier version)"
const SAGA_KEY := "saga"
const DEFAULT_PILOT := "Pilot"
const MAX_SLUG := 32
const SECONDS_PER_MINUTE := 60
const SECONDS_PER_HOUR := 3600
const MSEC := 1000.0

static var _clock_base := 0.0
static var _clock_started_msec := 0


# ------------------------------------------------------------------ files

static func make_path(id: String) -> String:
	return "%s/%s%s" % [DIR, id, EXTENSION]


static func exists(id: String) -> bool:
	return FileAccess.file_exists(make_path(id))


## Writes save `save` as `id`; false (and an error) when the file cannot be written.
static func write(id: String, save: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(DIR)
	var f := FileAccess.open(make_path(id), FileAccess.WRITE)
	if f == null:
		push_error("SaveGames: cannot write %s" % make_path(id))
		return false
	f.store_string(JSON.stringify(save))
	return true


## The save `id` ({} when there is none or it cannot be read).
static func read(id: String) -> Dictionary:
	if not exists(id):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(make_path(id)))
	if not d is Dictionary or not (d.has("saga") or d.get("campaign") is Dictionary):
		push_error("SaveGames: ignoring unreadable save %s" % make_path(id))
		return {}
	return d


static func delete(id: String) -> void:
	if exists(id):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(make_path(id)))


## Every readable save as a list entry (its meta plus "id"), newest first.
static func list_entries() -> Array:
	var out := []
	if not DirAccess.dir_exists_absolute(DIR):   # a new player has no saves folder yet
		return out
	for file in DirAccess.get_files_at(DIR):
		if not file.ends_with(EXTENSION):
			continue
		var id := file.get_basename()
		var d := read(id)
		if not d.is_empty():
			out.append(make_entry(id, d))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.saved_at) > float(b.saved_at) or (float(a.saved_at) == float(b.saved_at) and str(a.id) < str(b.id)))
	return out


## The newest save that can be continued ({} when none can).
static func find_newest_continuable() -> Dictionary:
	for e in list_entries():
		if is_continuable(e):
			return e
	return {}


## List entry of save `d` stored as `id`: its meta (made up for saves of earlier versions) plus "id".
static func make_entry(id: String, d: Dictionary) -> Dictionary:
	var meta: Dictionary = d.get("meta", {}) if d.get("meta") is Dictionary else {}
	if meta.is_empty():
		meta = _make_legacy_meta(id, d)
	var e := meta.duplicate(true)
	e["id"] = id
	return e


static func _make_legacy_meta(id: String, d: Dictionary) -> Dictionary:
	var pack := ""
	var title := "Saga"
	if not d.has("saga"):
		pack = str(d.get("pack", Session.guess_pack(d.campaign)))
		title = make_campaign_title(pack, str(d.campaign.get("variant", "")))
	return {"name": LEGACY_NAME if id == LEGACY_AUTOSAVE else id, "kind": KIND_AUTOSAVE,
		"pilot": str(d.get("pilot", DEFAULT_PILOT)), "campaign_key": SAGA_KEY if pack == "" else pack,
		"title": title, "mission": "", "packs": [pack] if pack != "" else [],
		"saved_at": float(FileAccess.get_modified_time(make_path(id))), "playtime": 0.0, "finished": false,
		"victory": false}


# ------------------------------------------------------------------ profiles (extraction mode)

## Mode profiles live beside the campaign saves in their own folder, so the save lists never show them:
## user://saves/profiles/<id>.json (ExtractionProfile).
static var PROFILE_DIR: String:
	get: return UserStore.path("saves/profiles")


static func make_profile_path(id: String) -> String:
	return "%s/%s%s" % [PROFILE_DIR, id, EXTENSION]


## Writes profile `data` as `id`; false (and an error) when the file cannot be written.
static func write_profile(id: String, data: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(PROFILE_DIR)
	var f := FileAccess.open(make_profile_path(id), FileAccess.WRITE)
	if f == null:
		push_error("SaveGames: cannot write %s" % make_profile_path(id))
		return false
	f.store_string(JSON.stringify(data))
	return true


## Profile `id` ({} when there is none or it cannot be read).
static func read_profile(id: String) -> Dictionary:
	if not FileAccess.file_exists(make_profile_path(id)):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(make_profile_path(id)))
	if not d is Dictionary:
		push_error("SaveGames: ignoring unreadable profile %s" % make_profile_path(id))
		return {}
	return d


# ------------------------------------------------------------------ what a save may do

## The games a save needs are installed and have a campaign provider.
static func is_available(entry: Dictionary) -> bool:
	for pack in entry.get("packs", []):
		if not Saga.PROVIDERS.has(pack) or not Assets.has_pack(pack):
			return false
	return true


## Not finished (won or lost) and playable here.
static func is_continuable(entry: Dictionary) -> bool:
	return not bool(entry.get("finished", false)) and is_available(entry)


## Why `entry` cannot be loaded ("" when it can).
static func make_block_reason(entry: Dictionary) -> String:
	if bool(entry.get("finished", false)):
		return "finished"
	if not is_available(entry):
		var names := (entry.get("packs", []) as Array).map(func(p) -> String: return Packs.pack_name(str(p)))
		return "unavailable: %s not installed" % ", ".join(PackedStringArray(names))
	return ""


# ------------------------------------------------------------------ slot ids

## "saga", "es1", "es2", "starsiege_human" ...
static func make_campaign_key(pack: String, variant: String, is_saga: bool) -> String:
	if is_saga:
		return SAGA_KEY
	return pack if variant == "" else "%s_%s" % [pack, variant]


static func make_autosave_id(campaign_key: String, pilot: String) -> String:
	return "auto_%s_%s" % [campaign_key, make_slug(pilot)]


static func make_restore_point_id(campaign_key: String, pilot: String) -> String:
	return "restore_%s_%s" % [campaign_key, make_slug(pilot)]


static func make_manual_id(save_name: String) -> String:
	return "save_%s" % make_slug(save_name)


## Lower-case letters, digits and "_" (names differing only in case share a slot, as shell careers do).
static func make_slug(text: String) -> String:
	var out := ""
	for ch in text.strip_edges().to_lower():
		out += ch if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") else "_"
	out = out.left(MAX_SLUG)
	return out if out.strip_edges() != "" else "pilot"


# ------------------------------------------------------------------ making saves

## The save of campaign `c` (a stage campaign, or the saga's current stage when `saga` is set).
## `info`: {pilot, playtime, coop, kind, name}.
static func make_save(c: Object, saga: Saga, info: Dictionary) -> Dictionary:
	var d := {"pilot": str(info.get("pilot", DEFAULT_PILOT)), "playtime": float(info.get("playtime", 0.0)),
		"coop": bool(info.get("coop", false)), "meta": make_meta(c, saga, info)}
	if saga != null:
		d["saga"] = saga.to_dict()
	else:
		d["pack"] = Session.campaign_pack(c)
		d["campaign"] = c.to_dict()
	return d


## What the Save / Load lists show without loading the campaign.
static func make_meta(c: Object, saga: Saga, info: Dictionary) -> Dictionary:
	var pack := Session.campaign_pack(c) if c != null else ""
	var variant := str(c.get("variant")) if c != null and c.get("variant") != null else ""
	var finished := _is_finished(c, saga)
	return {"name": str(info.get("name", "")), "kind": str(info.get("kind", KIND_MANUAL)),
		"pilot": str(info.get("pilot", DEFAULT_PILOT)), "campaign_key": make_campaign_key(pack, variant, saga != null),
		"title": _make_title(pack, variant, saga), "mission": _make_progress_text(c, saga),
		"packs": [pack] if pack != "" else [], "saved_at": Time.get_unix_time_from_system(),
		"playtime": float(info.get("playtime", 0.0)), "finished": finished,
		"victory": finished and c != null and c.is_victory()}


## A finished campaign cannot be continued: a stage won or lost, the saga complete or lost.
static func _is_finished(c: Object, saga: Saga) -> bool:
	if saga != null:
		return saga.is_complete() or (c != null and c.is_over() and not c.is_victory())
	return c == null or c.is_over()


static func _make_title(pack: String, variant: String, saga: Saga) -> String:
	if saga != null:
		return "Saga  -  %s" % saga.stage_name()
	return make_campaign_title(pack, variant)


static func _make_progress_text(c: Object, saga: Saga) -> String:
	if saga != null and saga.is_complete():
		return "Saga complete"
	if c == null:
		return "Starsiege: choosing a side" if saga != null else ""
	if c.is_over():
		return "Campaign won" if c.is_victory() else "Campaign lost"
	if c.get("campaign") == null:
		return "mission %s" % c.current_mission()   # the title already names the Starsiege side
	return Session.make_mission_heading(c)


## "Metaltech: Earthsiege", "Starsiege: Human campaign" ... (Saga.STAGES names).
static func make_campaign_title(pack: String, variant: String) -> String:
	for s in Saga.STAGES:
		if s.pack == pack:
			return str(s.name) if variant == "" else "%s: %s campaign" % [s.name, variant.capitalize()]
	for s in Saga.STANDALONE:
		if s.pack == pack:
			return str(s.name)
	return pack


# ------------------------------------------------------------------ texts

## "IRONSIDE  (autosave)\nMetaltech: Earthsiege  -  Campaign 1 - mission ...  -  2026-10-10 17:06  -  1h 05m".
static func make_row_text(entry: Dictionary) -> String:
	var head := "%s  (%s)" % [str(entry.get("name", "")), KIND_NAMES.get(str(entry.get("kind", "")), "save")]
	var parts := [str(entry.get("title", "")), str(entry.get("mission", "")),
		make_date_text(float(entry.get("saved_at", 0.0))), make_playtime_text(float(entry.get("playtime", 0.0)))]
	var line := "  -  ".join(PackedStringArray(parts.filter(func(p: String) -> bool: return p != "")))
	return "%s\n%s" % [head, line]


## Local date and time "2026-10-10 17:06".
static func make_date_text(unix: float) -> String:
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * SECONDS_PER_MINUTE
	var t := Time.get_datetime_dict_from_unix_time(int(unix) + bias)
	return "%04d-%02d-%02d %02d:%02d" % [t.year, t.month, t.day, t.hour, t.minute]


## "0h 42m" playtime.
static func make_playtime_text(seconds: float) -> String:
	var s := int(seconds)
	return "%dh %02dm" % [s / SECONDS_PER_HOUR, (s % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE]


# ------------------------------------------------------------------ play clock

## Starts counting the running campaign's playtime from `seconds`.
static func reset_clock(seconds: float) -> void:
	_clock_base = seconds
	_clock_started_msec = Time.get_ticks_msec()


## The running campaign's playtime so far (seconds).
static func clock_seconds() -> float:
	return _clock_base + (Time.get_ticks_msec() - _clock_started_msec) / MSEC
