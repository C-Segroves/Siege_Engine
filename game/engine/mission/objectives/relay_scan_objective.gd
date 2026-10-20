class_name RelayScanObjective
extends ScanObjective
## A scan whose stages relay on one countdown (Earthsiege 1 datalink, DBSIM 0x15f80). While the target is in view the
## countdown runs; when it is out the next stage's text shows and the countdown loads that stage's `seconds` (a negative
## value is out on the next tick). The scan is done when the last stage has shown. Losing the target starts it over and
## announces `abort_text` once, when a stage had shown. Differs from ScanObjective, whose stages span the held time.

## Seconds every text stays up (the abort text too).
var message_seconds := 4.0
var _fired := 0
var _countdown := 0.0


func _init(p_id := "", p_text := "", p_target := "", p_range := 0.0, p_stages: Array = []) -> void:
	super(p_id, p_text, p_target, p_range, p_stages)


## How many stages have shown since the scan (re)started.
func get_fired_count() -> int:
	return _fired


func _make_state(world: MissionWorld, dt: float) -> State:
	if not _is_target_in_view(world):
		_apply_relay_abort(world)
		return state
	_countdown = maxf(_countdown - dt, 0.0)
	if _countdown > 0.0:
		return state
	_say(world, str(stages[_fired].text))
	_countdown = float(stages[_fired].seconds)
	_fired += 1
	return State.DONE if _fired == stages.size() else state


func _apply_relay_abort(world: MissionWorld) -> void:
	if _fired != 0 and abort_text != "":
		_say(world, abort_text)
	_fired = 0
	_countdown = 0.0


func _say(world: MissionWorld, text: String) -> void:
	world.sink.apply_message(MissionMessage.make_message(text, message_seconds, MissionMessage.CHANNEL_INFO))
