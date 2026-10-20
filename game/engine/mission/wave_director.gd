class_name WaveDirector
extends RefCounted
## Brings the waves in. The spawning itself stays game-specific: the director calls `spawn.call(group, count)` and asks
## `count_alive.call(group)` how many of a group live. Triggers are plain names; the game calls apply_trigger("region:3")
## when its region fires, apply_trigger("start") at the mission start, and so on.

var _spawn: Callable
var _count_alive: Callable
var _waves: Array[SpawnWave] = []
var _timers := MissionTimers.new()
var _spawned := {}                  # group -> true once any of it came


func _init(p_spawn: Callable, p_count_alive: Callable) -> void:
	_spawn = p_spawn
	_count_alive = p_count_alive


func apply_add(wave: SpawnWave) -> void:
	_waves.append(wave)


## Starts every wave listening to `trigger`.
func apply_trigger(trigger: String) -> void:
	for w in _waves:
		if w.trigger == trigger:
			_schedule(w)


func apply_tick(dt: float) -> void:
	for payload in _timers.apply_tick(dt):
		_arrive(payload as SpawnWave)


## The group came and none of it lives any more.
func is_group_wiped_out(group: String) -> bool:
	return _spawned.has(group) and int(_count_alive.call(group)) <= 0


func _schedule(w: SpawnWave) -> void:
	if w.arrival <= 0.0:
		_arrive(w)
	else:
		_timers.apply_add(w, MissionTimer.make_timer(w.arrival, MissionTimer.Mode.ONE_SHOT, w))


func _arrive(w: SpawnWave) -> void:
	_spawned[w.group] = true
	_spawn.call(w.group, w.count)
	if w.repeat_every > 0.0:
		_timers.apply_add(w, MissionTimer.make_timer(w.repeat_every, MissionTimer.Mode.REPEATING, w))
