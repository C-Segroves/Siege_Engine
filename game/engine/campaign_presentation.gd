class_name CampaignPresentation
extends RefCounted
## How a campaign's end-of-mission pages read, per game, through one contract on the saga providers
## (engine/saga.gd): a provider may answer make_presentation() -> Dictionary with any of
##   killed_prompt   the killed-in-action page's question (each game's own wording of "replay the mission?")
##   victory_text    the campaign-won page
##   defeat_text     the campaign-lost page (the war is lost)
## and may answer make_movies(moment, context) -> Array of movie files (absolute paths of imported .ogv clips, played in
## order) for the moments MOMENTS name; the screens play them (MoviePlayer) before they show their page.
## and may answer make_talks(moment, context) -> Array of talking-head lines for the same moments (Earthsiege: the
## original shell's commanders and debriefing officers; ShellTalkPanel shows them).
## Keys a provider leaves out fall back to DEFAULTS. The shared screens (KilledScreen, EndScreen via MatchFlow)
## never branch on the game. Original wording comes from the pack's imported string tables (make_dialog_text,
## make_table_text); the remake's own wording is only the fallback when a pack lacks the table.

## Movie moments: the briefing (context {mission}), the debriefing (context {result}), a killed pilot, the war won,
## the war lost.
const MOMENT_BRIEFING := "briefing"
const MOMENT_DEBRIEF := "debrief"
const MOMENT_KILLED := "killed"
const MOMENT_VICTORY := "victory"
const MOMENT_DEFEAT := "defeat"
## A pack's converted cinematics (tools/export_movies.py): video/<stem>.ogv and video/clips.json.
const VIDEO_DIR := "video"
const CLIPS_FILE := "video/clips.json"

## Moments already presented this run, "<moment>|<key>" (take_first_showing).
static var _played := {}

const DEFAULTS := {
	"killed_prompt": "You were killed in action. Replay the mission?",
	"victory_text": "VICTORY",
	"defeat_text": "GAME OVER",
}


## The presentation of campaign `c` (DEFAULTS when there is no campaign or it has none of its own).
static func of(c: Object) -> Dictionary:
	var out := DEFAULTS.duplicate()
	if c != null and c.has_method("make_presentation"):
		out.merge(c.call("make_presentation"), true)
	return out


## The lines of an original dialog's imported string list (`rel` in `pack`, {"strings": [...]}) from line `first`
## to before line `end` (-1: to the last but one, dropping the button label), joined by `separator`; "" when the
## pack does not have it.
static func make_dialog_text(pack: String, rel: String, first: int, end := -1, separator := " ") -> String:
	var j = Assets.load_json(rel, pack)
	var lines: Array = j.get("strings", []) if j is Dictionary else []
	var last := lines.size() + end if end < 0 else mini(end, lines.size())
	if first >= last:
		return ""
	return separator.join(PackedStringArray(lines.slice(first, last)))


## An entry of a pack's imported id -> text table (`rel`), first line only, trimmed; "" when missing.
static func make_table_text(pack: String, rel: String, id: String) -> String:
	var j = Assets.load_json(rel, pack)
	var text := str(j.get(id, "")) if j is Dictionary else ""
	for line in text.split("\n", false):
		if line.strip_edges() != "":
			return line.strip_edges()
	return ""


## `text` unless it is empty, else `fallback` (the remake's wording when a table is not installed).
static func make_or(text: String, fallback: String) -> String:
	return text if text != "" else fallback


## The movies campaign `c` plays at `moment` (existing files only; [] when it has none or the pack lacks them).
static func make_movies(c: Object, moment: String, context := {}) -> Array:
	if c == null or not c.has_method("make_movies"):
		return []
	return (c.call("make_movies", moment, context) as Array).filter(func(f): return FileAccess.file_exists(str(f)))


## The movie file of clip `index` of `pack`'s clip table ("" when out of range or not imported).
static func make_clip_file(pack: String, index: int) -> String:
	var j = Assets.load_json(CLIPS_FILE, pack)
	var clips: Array = j.get("clips", []) if j is Dictionary else []
	if index < 0 or index >= clips.size():
		return ""
	return make_movie_file(pack, str(clips[index]))


## The movie file of `stem` in `pack` (video/<stem>.ogv).
static func make_movie_file(pack: String, stem: String) -> String:
	return Assets.path("%s/%s.ogv" % [VIDEO_DIR, stem], pack)


## True the first time `moment` is presented for `key` (the mission) in this run, false after: a briefing reopened
## from the hangar or the saves does not replay its movies and talking heads.
static func take_first_showing(moment: String, key: String) -> bool:
	var tag := "%s|%s" % [moment, key]
	if _played.has(tag):
		return false
	_played[tag] = true
	return true


## The talking-head lines campaign `c` speaks at `moment` ([] when it has none).
static func make_talks(c: Object, moment: String, context := {}) -> Array:
	if c == null or not c.has_method("make_talks"):
		return []
	return c.call("make_talks", moment, context)
