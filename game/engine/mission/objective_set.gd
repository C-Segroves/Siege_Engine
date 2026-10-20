class_name ObjectiveSet
extends RefCounted
## The objectives of a mission, in the order the panel lists them (primary ones first).

var _objectives: Array[Objective] = []


func apply_add(objective: Objective) -> void:
	_objectives.append(objective)


## Drops objective `id` from the panel; false when there is none.
func apply_remove(id: String) -> bool:
	for i in _objectives.size():
		if _objectives[i].id == id:
			_objectives.remove_at(i)
			return true
	return false


## The objectives in the order they were added.
func get_objectives() -> Array[Objective]:
	return _objectives


func get_objective(id: String) -> Objective:
	for o in _objectives:
		if o.id == id:
			return o
	return null


func get_count() -> int:
	return _objectives.size()


## Ticks every objective; tells the sink when any line changed. Returns true then.
func apply_tick(world: MissionWorld, dt: float) -> bool:
	var changed := false
	for o in _objectives:
		var before := o.state
		var text_before := o.text
		o.apply_tick(world, dt)
		changed = changed or o.state != before or o.text != text_before
	if changed:
		world.sink.apply_objectives_changed()
	return changed


## Every required objective is done (and there is at least one).
func is_complete() -> bool:
	var any := false
	for o in _objectives:
		if o.required:
			any = true
			if not o.is_done():
				return false
	return any


func has_failed() -> bool:
	for o in _objectives:
		if o.required and o.is_failed():
			return true
	return false


## The panel lines {text, done} of the objectives that have started, primary first.
func make_lines() -> Array:
	var lines := []
	for primary in [true, false]:
		for o in _objectives:
			if o.primary == primary and o.state != Objective.State.PENDING:
				lines.append(o.make_line())
	return lines
