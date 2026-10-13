class_name ScriptedInputs
extends RefCounted
## A timeline of SiegeInput actions for trailer shots:
##   cues  [[from s, to s, [action, ...]], ...]  actions held in that window ("action:0.4" holds it
##         at that analog strength, like a stick half over). Presses go through Input.action_press,
##         so the player's normal pilot reads them like a gamepad.
##   taps  [[at s, action], ...]  one press of a discrete action (view_toggle, vehicle_enter_exit).
##         Those are read from input events (_unhandled_input), so a tap is an InputEventAction
##         pressed at `at` and released on the next update, like a key.

var _cues: Array
var _taps: Array
var _clock := 0.0
var _running := false
var _held := {}
var _next_tap := 0
var _tapped: Array[String] = []


func _init(cues: Array, taps: Array = []) -> void:
	_cues = cues
	_taps = taps.duplicate()
	_taps.sort_custom(func(a, b): return float(a[0]) < float(b[0]))


func start() -> void:
	_running = true
	_clock = 0.0


## Advances the clock, presses exactly the actions whose window contains it and fires the taps
## that fall due.
func update(delta: float) -> void:
	if not _running:
		return
	_clock += delta
	_apply_held(make_held_actions(_clock))
	_apply_taps()


func _apply_held(want: Dictionary) -> void:
	for a in _held.keys():
		if not want.has(a):
			Input.action_release(a)
			_held.erase(a)
	for a in want:
		if _held.get(a, -1.0) != want[a]:
			Input.action_press(a, want[a])
			_held[a] = want[a]


func _apply_taps() -> void:
	for a in _tapped:
		Input.parse_input_event(make_tap_event(a, false))
	_tapped.clear()
	for a in take_due_taps(_clock):
		Input.parse_input_event(make_tap_event(a, true))
		_tapped.append(a)


## The actions held at time `t` (seconds since start): action -> strength (0..1].
func make_held_actions(t: float) -> Dictionary:
	var held := {}
	for cue in _cues:
		if t >= float(cue[0]) and t < float(cue[1]):
			for a in cue[2]:
				var parts := String(a).split(":")
				held[parts[0]] = float(parts[1]) if parts.size() > 1 else 1.0
	return held


## The taps due by time `t` that have not fired yet, in order (each fires once).
func take_due_taps(t: float) -> Array[String]:
	var due: Array[String] = []
	while _next_tap < _taps.size() and float(_taps[_next_tap][0]) <= t:
		due.append(String(_taps[_next_tap][1]))
		_next_tap += 1
	return due


static func make_tap_event(action: String, pressed: bool) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	return ev
