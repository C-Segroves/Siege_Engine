class_name GameReleases
extends RefCounted
## Which release of each game an installed pack was imported from, and whether the Siege Engine was tested with it
## (docs/TESTED_VERSIONS.md). The importer records the disc's release in pack.json "release"
## (tools/disc_version.py: version / build strings, the main executable's and the disc image's SHA-256); the
## tested releases are TABLE_FILE, matched by the executable's hash first, then by the disc image's.

const TABLE_FILE := "res://engine/tested_versions.json"
const TESTED := "tested"
const UNTESTED := "untested"
## A pack imported before the importer identified releases (no pack.json "release").
const UNIDENTIFIED := "unidentified"
const SHORT_HASH := 12

static var _table := {}


## The tested releases: [{game, name, version, patch, exe, exe_sha256, disc_sha256, label, mastered, result ...}].
static func tested_releases() -> Array:
	return _load_table().get("releases", [])


## The day the table's releases were last tested ("2026-10-12").
static func tested_on() -> String:
	return str(_load_table().get("tested", ""))


## The release record pack.json carries for `pack` ({} when the importer did not record one).
static func pack_release(pack: String) -> Dictionary:
	var meta: Dictionary = Packs.packs.get(pack, {})
	var rec = meta.get("release", {})
	return rec if rec is Dictionary else {}


## The tested-table entry of `release` ({} when its executable and disc are not in the table).
static func make_tested_entry(release: Dictionary) -> Dictionary:
	for key in ["exe_sha256", "disc_sha256"]:
		var digest := str(release.get(key, ""))
		if digest == "":
			continue
		for e: Dictionary in tested_releases():
			if str(e.get(key, "")) == digest:
				return e
	return {}


## TESTED, UNTESTED or UNIDENTIFIED for an installed pack.
static func make_status(pack: String) -> String:
	var release := pack_release(pack)
	if release.is_empty() or str(release.get("exe_sha256", "")) == "":
		return UNIDENTIFIED
	return TESTED if not make_tested_entry(release).is_empty() else UNTESTED


## "1.000r, build Feb 20 1999 17:09:39" from the evidence of `release` (the tested name when the disc names none).
static func make_version_text(release: Dictionary) -> String:
	var parts := []
	var version := str(release.get("version", ""))
	if version == "":
		version = str(make_tested_entry(release).get("version", ""))
	if version != "":
		parts.append(version)
	if str(release.get("build", "")) != "":
		parts.append("build %s" % release.build)
	if str(release.get("build_date", "")) != "":
		parts.append("built %s" % release.build_date)
	return ", ".join(parts) if not parts.is_empty() else "version not named on the disc"


## "Starsiege.exe 42569d340884..." (the executable and the start of its hash).
static func make_exe_text(release: Dictionary) -> String:
	return "%s  %s..." % [release.get("exe", "?"), str(release.get("exe_sha256", "")).left(SHORT_HASH)]


## One line about `pack`'s release for the library and the versions page.
static func make_status_text(pack: String) -> String:
	match make_status(pack):
		TESTED:
			return "Tested version: %s" % make_version_text(pack_release(pack))
		UNTESTED:
			return "Untested version: %s. It will probably work; if something looks wrong, please report the version." \
				% make_version_text(pack_release(pack))
	return "Version not identified (imported by an older importer). Identifying it reads only the disc's executable; " \
		+ "no new import."


## The disc image `pack` was imported from ("" when pack.json does not record its path or it is gone).
static func source_disc_path(pack: String) -> String:
	var meta: Dictionary = Packs.packs.get(pack, {})
	for d in meta.get("source_discs", []):
		if d is Dictionary and int(d.get("disc", 1)) == 1 and FileAccess.file_exists(str(d.get("path", ""))):
			return str(d.path)
	return ""


static func _load_table() -> Dictionary:
	if _table.is_empty():
		var f := FileAccess.open(TABLE_FILE, FileAccess.READ)
		var parsed = JSON.parse_string(f.get_as_text()) if f != null else null
		if not parsed is Dictionary:
			push_error("GameReleases: cannot read %s" % TABLE_FILE)
			return {}
		_table = parsed
	return _table
