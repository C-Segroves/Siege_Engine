class_name ScanObjective
extends Objective
## Hold the target in range and in the view cone for the scan stages (datalink, recon, scan). `stages` is a list of
## {seconds, text}: the scan runs the sum of the seconds, the text of the stage it is in goes out as an info message
## when the stage begins. Losing the target aborts the scan: it starts over and `abort_text` is announced once.
## Original values (stage lists, range, cone) come from the game adapter.

const DEFAULT_CONE_DEGREES := 45.0       # Earthsiege 1 datalink and Earthsiege 2 scan cone

var target := ""
var scan_range := 0.0
var cone_degrees := DEFAULT_CONE_DEGREES
var stages: Array = []
var abort_text := ""
## Optional "scanning N%" lines (a `%d` format) every `progress_every` rules ticks, each up for `progress_seconds`, and a line
## when the scan completes (Earthsiege 2: "Scanning target... 25%", "Scan complete."). A stage with no text says nothing.
var progress_format := ""
var progress_every := 0
var progress_seconds := 1.0
var complete_text := ""
var complete_seconds := 4.0
var _elapsed := 0.0
var _stage := -1


func _init(p_id := "", p_text := "", p_target := "", p_range := 0.0, p_stages: Array = []) -> void:
	super(p_id, p_text)
	target = p_target
	scan_range = p_range
	stages = p_stages


func make_total_seconds() -> float:
	var total := 0.0
	for s in stages:
		total += float(s.seconds)
	return total


func _make_state(world: MissionWorld, dt: float) -> State:
	if not _is_target_in_view(world):
		_apply_abort(world)
		return state
	_elapsed += dt
	_announce_stage(world)
	_announce_progress(world, dt)
	if _elapsed < make_total_seconds():
		return state
	if complete_text != "":
		_announce_line(world, complete_text, complete_seconds)
	return State.DONE


func _is_target_in_view(world: MissionWorld) -> bool:
	return world.is_target_in_view(target, scan_range, cone_degrees)


func _apply_abort(world: MissionWorld) -> void:
	if _stage >= 0 and abort_text != "":
		_announce_line(world, abort_text, 0.0)
	_elapsed = 0.0
	_stage = -1


func _announce_stage(world: MissionWorld) -> void:
	var at := 0.0
	for i in stages.size():
		at += float(stages[i].seconds)
		if _elapsed < at or i == stages.size() - 1:
			if i != _stage:
				_stage = i
				if str(stages[i].text) != "":
					_announce_line(world, str(stages[i].text), float(stages[i].seconds))
			return


func _announce_progress(world: MissionWorld, dt: float) -> void:
	if dt > 0.0 and progress_every > 0 and progress_format != "" and int(_elapsed / dt) % progress_every == 1:
		_announce_line(world, progress_format % mini(100, int(_elapsed * 100.0 / make_total_seconds())), progress_seconds)


func _announce_line(world: MissionWorld, line: String, seconds: float) -> void:
	world.sink.apply_message(MissionMessage.make_message(line, seconds, MissionMessage.CHANNEL_INFO))
