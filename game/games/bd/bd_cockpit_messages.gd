class_name BdCockpitMessages
extends RefCounted
## A Battledrome Herc's cockpit messages and their voice (SIM.EXE MessageManager, docs/formats/battledrome.md
## section 8; tables from the user's SIM.EXE via BdVoices):
##   * post (0x149b0): a message repeats only `repeat_s` after it was last shown; within `message_spacing_s` of the
##     previous message a non-urgent one is queued (its `queued` flag, ring of 30) or dropped; otherwise its text
##     is shown and its voice (SHER*.RAW, the Herc's warning voice) plays.  SHIELDS LOW and SHIELDS DEPLETED share
##     one repeat timer (0x14ab8 / 0x14ac4).
##   * update (0x14978, every frame): once the spacing has passed, the oldest queued message is posted.
##   * shield warning (0x8057): shield * 256 / SG points (integer, 0x808c) in 1..25 -> SHIELDS DEPLETED, up to 63 ->
##     SHIELDS LOW; an empty shield (0) says nothing.  Checked while the match runs, for the local pilot's Herc.
##   * the voice ducks every other sound to half while it plays (0x2821c, Sfx.play_voice duck); with Battledrome
##     voices off (Options, the original's Preferences VOICES) only the text shows.
## Not modelled: the other messages (the remake's Battledrome Hercs carry one hull, no logical parts, and no referee
## drone).

## 0x14b16: the queue is a ring of 30 message numbers.
const QUEUE_SIZE := 30
const TEXT_SECONDS := 4.0

## Seconds since this tracker started (the sim clock).
var clock := 0.0
## Shows a message's text (Callable(text: String)); voices go to Sfx.play_voice.
var show_text: Callable
var _last_shown := {}       # message -> clock
var _last_any := -INF
var _queue: Array[int] = []


func _init(p_show_text: Callable) -> void:
	show_text = p_show_text


## Advances the clock, drains the queue and checks the shield of `herc` (the local pilot's) while `running`.
func update(herc: Herc, delta: float, running: bool) -> void:
	clock += delta
	_drain_queue()
	if running and herc != null and is_instance_valid(herc) and herc.alive and is_battledrome_herc(herc):
		var warning: Dictionary = BdVoices.table().get("shield_warning", {})
		var m := make_shield_message(make_shield_level(herc, int(warning.get("scale", 0))), warning)
		if m >= 0:
			post(m)


## Posts message `index`; true when it was shown now.
func post(index: int) -> bool:
	var m := BdVoices.message(index)
	if m.is_empty():
		return false
	if clock - float(_last_shown.get(index, -INF)) <= float(m.get("repeat_s", 0.0)):
		return false
	if clock - _last_any <= _spacing() and not bool(m.get("urgent", false)):
		if bool(m.get("queued", false)) and _queue.size() < QUEUE_SIZE:
			_queue.append(index)
		return false
	_show(index, m)
	return true


## Messages waiting for the spacing to pass (read-only copy, for tests).
func queued() -> Array[int]:
	return _queue.duplicate()


## The original's shield level: shield points * `scale` / SG points, truncated (0 without a shield).
static func make_shield_level(herc: Herc, scale: int) -> int:
	if herc.shield_max <= 0.0:
		return 0
	return int((herc.shield_front + herc.shield_rear) * scale / herc.shield_max)


## The shield message for `level` (-1 = none): `warning` is voices.json "shield_warning".
static func make_shield_message(level: int, warning: Dictionary) -> int:
	if warning.is_empty() or level <= 0:
		return -1
	if level <= int(warning.depleted_max):
		return int(warning.depleted_message)
	if level <= int(warning.low_max):
		return int(warning.low_message)
	return -1


static func is_battledrome_herc(herc: Herc) -> bool:
	return herc.vehicle_id.begins_with(BdVoices.PACK + ":")


func _show(index: int, m: Dictionary) -> void:
	_last_shown[index] = clock
	_last_any = clock
	_share_shield_timer(index)
	if show_text.is_valid():
		show_text.call(BdVoices.message_text(index))
	var voice := BdVoices.sound_name(String(m.get("voice", "")))
	if voice != "" and AudioSettings.voices_on():
		Sfx.play_voice(voice, true)


func _share_shield_timer(index: int) -> void:
	var w: Dictionary = BdVoices.table().get("shield_warning", {})
	if w.is_empty() or not bool(w.get("shared_repeat_timer", false)):
		return
	if index == int(w.low_message):
		_last_shown[int(w.depleted_message)] = clock
	elif index == int(w.depleted_message):
		_last_shown[int(w.low_message)] = clock


func _drain_queue() -> void:
	if _queue.is_empty() or clock - _last_any <= _spacing():
		return
	post(_queue.pop_front())


func _spacing() -> float:
	return float(BdVoices.table().get("message_spacing_s", 0.0))
