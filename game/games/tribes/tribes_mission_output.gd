class_name TribesMissionOutput
extends RefCounted
## What a Tribes / Tribes 2 training mission says and shows (TribesMissionRuntime.output):
##   radio       the training lines (Tribes bottomprint, Tribes 2 doText's messageClient + alxPlay) on the
##               battle radio, speaker RADIO_SPEAKER: a step's text goes out with the voice clip played in the
##               same step (flush); a voice-only line whose clip is not installed says nothing;
##   objectives  the objective lines (Tribes' objective page, Tribes 2's objective HUD), announced on the
##               message line when a game says so;
##   waypoint    one nav point at a time (the trainers set it), labelled.
## Messages before the battle's overlay exists (scripts the mission file runs while the battle is built) are not
## shown; radio lines wait for the next flush.

## The remake's label for the training voice on the radio (the originals name no speaker).
const RADIO_SPEAKER := "Training"
const MESSAGE_SECONDS := 6.0

var rt: TribesMissionRuntime
## Objective lines as shown.
var objectives: Array[String] = []
## [speaker, text, voice] of every radio line posted (tests, diagnostics).
var radio_lines: Array = []
var _pending_texts: Array[String] = []
var _pending_voices: Array[String] = []
var _waypoint: Node3D


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime


## A line of training text; it goes out with the voice clip the same script step plays, if any (flush).
func queue_text(text: String) -> void:
	var clean := TribesText.make_plain(text)
	if clean != "":
		_pending_texts.append(clean)


## A voice clip the script plays ("tribes2:training/mission1/t1_01").
func queue_voice(voice: String) -> void:
	if voice != "":
		_pending_voices.append(voice)


## Sends the queued lines to the radio: texts paired with the voices played in the same step, in order.
func flush() -> void:
	while not _pending_texts.is_empty() or not _pending_voices.is_empty():
		var text: String = _pending_texts.pop_front() if not _pending_texts.is_empty() else ""
		var voice: String = _pending_voices.pop_front() if not _pending_voices.is_empty() else ""
		post_radio(text, voice)


func post_radio(text: String, voice: String) -> void:
	var has_clip := voice != "" and Sfx.stream(voice) != null
	rt.log_debug("radio: %s [%s%s]" % [text, voice, "" if has_clip or voice == "" else " missing"])
	if text == "" and not has_clip:
		return
	radio_lines.append([RADIO_SPEAKER, text, voice if has_clip else ""])
	rt.battle.radio(RADIO_SPEAKER, text, voice if has_clip else "")


## Objective line `index` (0-based) now reads `text` ("" clears it). Returns true when it changed.
func store_objective(index: int, text: String) -> bool:
	if index < 0:
		return false
	var clean := TribesText.make_plain(text)
	while objectives.size() <= index:
		objectives.append("")
	if objectives[index] == clean:
		return false
	objectives[index] = clean
	rt.log_debug("objective %d: %s" % [index, clean])
	return true


func clear_objectives() -> void:
	objectives.clear()


## A short message on the message line (objectives, Tribes 2 message boxes).
func show_message(text: String, seconds := MESSAGE_SECONDS) -> void:
	var clean := TribesText.make_plain(text)
	if clean != "" and rt.battle.get("overlay") != null:
		rt.battle.fx("message", [clean, seconds], true)


## The mission's waypoint: a nav point at `p` (engine frame).
func set_waypoint(p: Vector3, label: String) -> void:
	clear_waypoint()
	_waypoint = Marker3D.new()
	_waypoint.name = "Waypoint"
	_waypoint.position = p
	_waypoint.set_meta("label", label)
	_waypoint.add_to_group("nav_points")
	rt.battle.add_child(_waypoint)
	rt.nav_points = [p]
	rt.nav_index = 0
	rt.log_debug("waypoint %s at %s" % [label, p])


func clear_waypoint() -> void:
	if is_instance_valid(_waypoint):
		_waypoint.queue_free()
	_waypoint = null
	rt.nav_points = []
	rt.nav_index = 0
