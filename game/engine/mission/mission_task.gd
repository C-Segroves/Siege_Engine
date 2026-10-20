class_name MissionTask
extends RefCounted
## The sequential executor of mission scripts: a script is a list of action dictionaries ({"op": name, ...}); every running
## script is a task that steps its actions in order. Built in: wait, exec (start another script, blocking or not),
## exit_script, if (the tests are the game's, see `tester`), loop, for, exit_loop. Any other op is registered by the game
## with register_op(name, callable); the callable gets (task: Task, action: Dictionary) and may set `task.wait`.
## Scripts are dictionaries {label, name, message, by, enabled, actions}; fire() starts the ones a message raises, run()
## starts one by label. Vengeance missions run on it (docs/formats/tribes_vengeance.md "Mission scripts").

## Actions one task may run in one tick, so a loop without a wait cannot hang the game.
const MAX_STEPS_PER_TICK := 2000
## A script that starts itself (the crowd chants of Regicide) must not multiply: a non-blocking call of a script already
## running is ignored, and no more than this many tasks run.
const MAX_TASKS := 400

var scripts: Array = []
var ended := false
## Who raised the message of the task being stepped (what Vengeance's "Get Message Value" reads).
var instigator := "Player"
## Callable(tests: Array) -> bool: the condition of an "if" action (the tests' meaning is the game's).
var tester := Callable()

var _by_label := {}              # script label (lower case) -> script dictionary
var _tasks: Array = []           # running Task objects
var _disabled := {}              # script name -> true
var _ops := {}                   # op name -> Callable


class Task:
	extends RefCounted
	var label := ""
	var stack: Array = []        # frames {actions, i, kind, n}
	var wait := 0.0
	var child: Task = null
	var done := false
	var instigator := "Player"


func _init(p_scripts: Array) -> void:
	scripts = p_scripts
	for s in scripts:
		var label := str(s.get("label", "")).to_lower()
		if label != "" and not _by_label.has(label):
			_by_label[label] = s
		if not bool(s.get("enabled", true)):
			_disabled[str(s.get("name", label))] = true


func register_op(name: String, handler: Callable) -> void:
	_ops[name] = handler


## Starts the scripts a message raises: every enabled script whose message class matches and that is triggered by `by`
## (an empty "by" or "all" matches any). Returns how many started.
func fire(message: String, by := "", p_instigator := "Player") -> int:
	var started := 0
	for s in scripts:
		if str(s.message) != message or _is_disabled(s):
			continue
		var wanted: Array = (s.get("by", []) as Array).map(func(b) -> String: return str(b).to_lower())
		if not wanted.is_empty() and not wanted.has("all") and not wanted.has(by.to_lower()):
			continue
		_start(s, p_instigator)
		started += 1
	return started


## Runs script `label` (a call from outside); null when there is none.
func run(label: String, p_instigator := "Player") -> Task:
	var s: Dictionary = _by_label.get(label.to_lower(), {})
	return _start(s, p_instigator) if not s.is_empty() else null


## Enables or disables the script `label` names (by label or name); false when there is none.
func apply_script_enabled(label: String, on: bool) -> bool:
	var found := false
	for s in scripts:
		if str(s.get("label", "")).to_lower() == label.to_lower() or str(s.get("name", "")) == label:
			found = true
			var key := str(s.get("name", s.label))
			if on:
				_disabled.erase(key)
			else:
				_disabled[key] = true
	return found


func is_running() -> bool:
	return not _tasks.is_empty()


func running_labels() -> Array:
	return _tasks.map(func(t: Task) -> String: return t.label)


func tick(delta: float) -> void:
	if ended:
		return
	for t in _tasks.duplicate():
		_step(t, delta)
	_tasks = _tasks.filter(func(t: Task) -> bool: return not t.done)


func _is_task_running(label: String) -> bool:
	for t in _tasks:
		if t.label == label and not t.done:
			return true
	return false


func _is_disabled(s: Dictionary) -> bool:
	return _disabled.has(str(s.get("name", s.get("label", ""))))


func _start(s: Dictionary, p_instigator: String) -> Task:
	var t := Task.new()
	t.label = str(s.get("label", ""))
	t.instigator = p_instigator
	t.stack = [_make_frame(s.get("actions", []), "seq")]
	_tasks.append(t)
	return t


static func _make_frame(actions: Array, kind: String, n := 0) -> Dictionary:
	return {"actions": actions, "i": 0, "kind": kind, "n": n}


func _step(t: Task, delta: float) -> void:
	if t.wait > 0.0:
		t.wait -= delta
		if t.wait > 0.0:
			return
	if t.child != null:
		if not t.child.done:
			return
		t.child = null
	var steps := 0
	instigator = t.instigator
	while not t.stack.is_empty() and t.wait <= 0.0 and t.child == null and not ended and steps < MAX_STEPS_PER_TICK:
		steps += 1
		var f: Dictionary = t.stack.back()
		var list: Array = f.actions
		if int(f.i) >= list.size():
			_finish_frame(t, f)
			continue
		var a: Dictionary = list[int(f.i)]
		f.i = int(f.i) + 1
		_exec(t, a)
	if t.stack.is_empty():
		t.done = true


## A frame ran out: loops start over (a loop with no actions ends), for loops count down, the rest pop.
func _finish_frame(t: Task, f: Dictionary) -> void:
	match str(f.kind):
		"loop":
			if (f.actions as Array).is_empty():
				t.stack.pop_back()
			else:
				f.i = 0
		"for":
			f.n = int(f.n) - 1
			if int(f.n) > 0 and not (f.actions as Array).is_empty():
				f.i = 0
			else:
				t.stack.pop_back()
		_:
			t.stack.pop_back()


func _exec(t: Task, a: Dictionary) -> void:
	match str(a.op):
		"wait":
			t.wait = float(a.s)
		"exec":
			_exec_call(t, a)
		"exit_script":
			_exec_exit_script(t, a)
		"if":
			var branch: Array = a.get("then", []) if _test(a.get("tests", [])) else a.get("else", [])
			if not branch.is_empty():
				t.stack.append(_make_frame(branch, "seq"))
		"loop":
			t.stack.append(_make_frame(a.get("actions", []), "loop"))
		"for":
			var n := int(float(a.get("to", 0.0)) - float(a.get("from", 0.0))) + 1
			if n > 0:
				t.stack.append(_make_frame(a.get("actions", []), "for", n))
		"exit_loop":
			while not t.stack.is_empty():
				var f: Dictionary = t.stack.pop_back()
				if str(f.kind) in ["loop", "for"]:
					break
		_:
			if _ops.has(str(a.op)):
				(_ops[str(a.op)] as Callable).call(t, a)


func _exec_call(t: Task, a: Dictionary) -> void:
	var s: Dictionary = _by_label.get(str(a.script).to_lower(), {})
	var blocking := bool(a.get("block", false))
	if s.is_empty() or _tasks.size() >= MAX_TASKS:
		return
	if blocking or not _is_task_running(str(s.get("label", ""))):
		var child := _start(s, t.instigator)
		if blocking:
			t.child = child


func _exec_exit_script(t: Task, a: Dictionary) -> void:
	for other in _tasks:
		if other.label.to_lower() == str(a.script).to_lower() and other != t:
			other.done = true
			other.stack.clear()


func _test(tests: Array) -> bool:
	return not tester.is_valid() or bool(tester.call(tests))
