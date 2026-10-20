class_name TribesMissionOutput
extends RefCounted
## What a Tribes / Tribes 2 training mission says and shows (TribesMissionRuntime.output), over the shared mission
## blocks: the MissionAnnouncer says it, TribesMissionSink puts it on the Battle, the objective lines are
## ScriptObjectives in an ObjectiveSet.
##   radio       the training lines (Tribes bottomprint, Tribes 2 doText's messageClient + alxPlay) on the
##               battle radio, speaker RADIO_SPEAKER: a step's text goes out with the voice clip played in the
##               same step (flush); a voice-only line whose clip is not installed says nothing;
##   objectives  the objective lines (Tribes' objective page, Tribes 2's objective HUD), announced on the
##               message line when a game says so;
##   waypoint    one nav point at a time (the trainers set it), labelled.
## Messages before the battle's overlay exists (scripts the mission file runs while the battle is built) are not
## shown; radio lines wait for the next flush.
## The announcer (CUT: no queue, every line goes out at once) only carries the lines to the sink; the battle's radio paces
## them, as it did before the blocks.

## The remake's label for the training voice on the radio (the originals name no speaker).
const RADIO_SPEAKER := "Training"
const MESSAGE_SECONDS := 6.0
const OBJECTIVE_ID := "line%d"

var rt: TribesMissionRuntime
var sink: TribesMissionSink
var announcer: MissionAnnouncer
## [speaker, text, voice] of every radio line posted (tests, diagnostics).
var radio_lines: Array = []
## The objective lines as shown, by index ("" = cleared).
var objectives: Array[String]:
	get:
		var out: Array[String] = []
		for i in _objective_set.get_count():
			out.append(_objective_set.get_objective(OBJECTIVE_ID % i).text)
		return out
var _objective_set := ObjectiveSet.new()
var _pending_texts: Array[String] = []
var _pending_voices: Array[String] = []


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime
	sink = TribesMissionSink.new(runtime)
	sink.voice_speaker = RADIO_SPEAKER
	announcer = MissionAnnouncer.new(sink, MissionAnnouncer.Discipline.CUT)


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
	announcer.apply_say(MissionMessage.make_message(text, 0.0, MissionMessage.CHANNEL_RADIO, RADIO_SPEAKER,
		MissionVoice.make_voice(voice) if has_clip else null))


## Objective line `index` (0-based) now reads `text` ("" clears it). Returns true when it changed.
func store_objective(index: int, text: String) -> bool:
	if index < 0:
		return false
	var clean := TribesText.make_plain(text)
	while _objective_set.get_count() <= index:
		var line := ScriptObjective.new(OBJECTIVE_ID % _objective_set.get_count())
		line.apply_state(Objective.State.PENDING)
		_objective_set.apply_add(line)
	var objective := _objective_set.get_objective(OBJECTIVE_ID % index)
	if objective.text == clean:
		return false
	(objective as ScriptObjective).apply_text(clean)
	(objective as ScriptObjective).apply_state(Objective.State.ACTIVE if clean.strip_edges() != "" else Objective.State.PENDING)
	rt.log_debug("objective %d: %s" % [index, clean])
	return true


func clear_objectives() -> void:
	_objective_set = ObjectiveSet.new()


## The objectives panel's lines {text, done}: the lines that read something, never marked done.
func make_objective_lines() -> Array:
	return _objective_set.make_lines()


## A short message on the message line (objectives, Tribes 2 message boxes).
func show_message(text: String, seconds := MESSAGE_SECONDS) -> void:
	var clean := TribesText.make_plain(text)
	if clean != "":
		announcer.apply_say(MissionMessage.make_message(clean, seconds, MissionMessage.CHANNEL_INFO))


## The mission's waypoint: a nav point at `p` (engine frame).
func set_waypoint(p: Vector3, label: String) -> void:
	sink.apply_nav_point(label, p)
	sink.apply_nav(label, true)
	rt.log_debug("waypoint %s at %s" % [label, p])


func clear_waypoint() -> void:
	sink.apply_nav("", false)
