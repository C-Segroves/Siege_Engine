class_name ES2CommandRadio
extends RefCounted
## Earthsiege 2 command radio (host; docs/formats/es2.md section 11):
## - training missions (header word 4 = lesson 1..4, VSHELL 0x4aa7ac): a firing region with message word
##   w39 > 0 posts message w39 - 1 to the comm object, which plays TM<lesson>_00<w39>.WAV (DBSIM 0x423430,
##   0x4368fb) [H]; the line's text is message w39 - 1 of COMMAND<lesson>.STR (all its variants) [H].
## - base under attack: COMMAND0.STR's three lines (no voice clips). Their trigger is not traced; the remake
##   calls one, once per mission, when a hostile unit first hits a friendly (team 0) structure [L].

const FIRST_LESSON := 1
const LAST_LESSON := 4
## COMMAND0.STR: the base's own lines.
const BASE_TABLE := "command0"
const LESSON_TABLE := "command%d"
## Speaker names shown with the lines (remake labels: the instructor signs off as training command in
## COMMAND1.STR; COMMAND0 is spoken by the base command).
const INSTRUCTOR_SPEAKER := "Training Command"
const BASE_SPEAKER := "Base Command"
const PACK := "es2"
## Team of the player's side.
const PLAYER_TEAM := 0

var rt: MissionRuntime
var lesson := 0
var _lesson_table: RadioTable = null
var _base_table: RadioTable
var _base_warned := false


func _init(runtime: MissionRuntime) -> void:
	rt = runtime
	lesson = training_lesson(rt.m)
	if lesson >= FIRST_LESSON and lesson <= LAST_LESSON:
		_lesson_table = RadioTable.load_table(PACK, LESSON_TABLE % lesson)
	_base_table = RadioTable.load_table(PACK, BASE_TABLE)


## The mission's training lesson (header word 4; 0 = not a training mission).
static func training_lesson(mission: Dictionary) -> int:
	var header = mission.get("header", {})
	return int(header.get("h4", 0)) if header is Dictionary and header.get("h4") != null else 0


func is_training() -> bool:
	return _lesson_table != null and not _lesson_table.is_empty()


## A fired region's training message (its "message" = w39; 0 = none).
func announce_region(region: Dictionary) -> void:
	var w39 := int(region.get("message", 0))
	if w39 <= 0 or not is_training():
		return
	var line := _lesson_table.make_joined_line(w39 - 1)
	if not line.is_empty():
		rt.battle.radio(INSTRUCTOR_SPEAKER, str(line.text), str(line.voice))


## Listens to a friendly structure for the base-under-attack call.
func watch_structure(st: Structure) -> void:
	if st.team == PLAYER_TEAM and not _base_table.is_empty():
		st.damaged.connect(_on_base_damaged)


func _on_base_damaged(st: Structure, attacker: Node) -> void:
	if _base_warned or attacker == null or not "team" in attacker or int(attacker.team) == st.team:
		return
	_base_warned = true
	var rows := _base_table.message_numbers()
	var line := _base_table.make_random_line(int(rows[randi() % rows.size()]))
	rt.battle.radio(BASE_SPEAKER, str(line.text), str(line.voice))
