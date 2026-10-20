class_name SSCutscene
extends Node
## The in-mission cut-scenes of Starsiege scripts, on the host's screen:
##   focusCamera(splineCamera, <path>)  flies the mission's camera path (SSCameraPath) and raises
##                                      <path>::camera::waypoint<k> as each waypoint is reached;
##   setDominantCamera / setFlybyCamera / setTowerCamera / setOrbitCamera
##                                      an object camera (SSObjectCamera) follows / watches mission objects
##                                      until setPlayerCamera or the next camera call;
##   setPlayerCamera()                  returns to the player's cockpit / chase view;
##   lockUserInput(true / false)        the player's vehicle ignores the controls (as in the original,
##                                      the intro of HE1 locks them until its last camera path is done).
## While a cut-scene runs ui_accept / menu_back skips it: a camera path flight or locked input is
## fast-forwarded (script timers and flight) until the script hands control back; an object camera on
## its own (the game keeps running under it) just returns to the player's view.

## Fast-forward step and limit of a skip (seconds of script time).
const SKIP_STEP := 0.05
const MAX_SKIP_SECONDS := 180.0
## Runs after Battle._process, which makes its own camera current every frame.
const AFTER_BATTLE_PRIORITY := 100
const LETTERBOX_FRACTION := 0.12
const SKIP_HINT := "Enter / Esc: skip"
## A path the mission has no data for: its waypoint callbacks fire this many seconds apart
## (the earlier approximation, kept as a fallback).
const FALLBACK_WAYPOINT_INTERVAL := 3.0
const MAX_FALLBACK_WAYPOINTS := 11

var rt: StarsiegeMissionRuntime
var camera: Camera3D
var path: SSCameraPath
var object_camera: SSObjectCamera
var input_locked := false
var _flying := false
var _paths := {}            # lower path name -> definition
var _screen: CanvasLayer
var _overlay_was_visible := true


static func make(runtime: StarsiegeMissionRuntime) -> SSCutscene:
	var c := SSCutscene.new()
	c.rt = runtime
	c.name = "SSCutscene"
	c.process_priority = AFTER_BATTLE_PRIORITY
	c.process_physics_priority = AFTER_BATTLE_PRIORITY
	var defs = runtime.m.get("camera_paths")
	if defs is Dictionary:
		for k in defs:
			c._paths[String(k).to_lower()] = defs[k]
	return c


## True while the camera flies a path or follows an object, or the player's input is locked.
func is_running() -> bool:
	return is_scripted_sequence() or is_following()


## A camera path flight or locked input: what a skip fast-forwards.
func is_scripted_sequence() -> bool:
	return is_flying() or input_locked


func is_flying() -> bool:
	return _flying


func is_following() -> bool:
	return object_camera != null


## focusCamera(splineCamera, path): starts the flight of `path_name` (a name or a script path).
func focus_path(path_name: String) -> void:
	var key := path_name.replace("\\", "/").get_file().to_lower()
	if not _paths.has(key):
		_schedule_fallback_callbacks(key)
		return
	path = SSCameraPath.from_def(key, _paths[key])
	if path.is_empty():
		return
	object_camera = null
	_flying = true
	_show_camera()
	camera.global_transform = path.make_transform()
	_raise_waypoint(0)


## Object camera (setDominantCamera and the like): replaces a running flight.
func follow(cam: SSObjectCamera) -> void:
	path = null
	object_camera = cam
	_flying = false
	_show_camera()
	camera.global_transform = cam.make_transform(camera.global_transform)


## setPlayerCamera(): back to the battle's own camera.
func end_camera() -> void:
	path = null
	object_camera = null
	_flying = false
	if camera:
		camera.current = false
	_apply_screen()


## lockUserInput(on).
func lock_input(on: bool) -> void:
	input_locked = on
	var pilot: Node = rt.battle.get("pilot")
	if pilot == null:
		return
	pilot.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT
	var h: Herc = rt.battle.get("player")
	if on and h != null and is_instance_valid(h):
		h.throttle = 0.0
		h.turn = 0.0
		for w in h.weapons:
			w.trigger = false
	_apply_screen()


## Fast-forwards the script and the flight until the cut-scene hands control back.
func skip() -> void:
	var spent := 0.0
	while is_scripted_sequence() and spent < MAX_SKIP_SECONDS and not rt.is_mission_over():
		rt.advance_timers(SKIP_STEP)
		_advance_flight(SKIP_STEP)
		spent += SKIP_STEP
	if is_running():
		end_camera()
		lock_input(false)


func _input(event: InputEvent) -> void:
	if not is_running():
		return
	if event.is_action_pressed("ui_accept") or event.is_action_pressed("menu_back"):
		get_viewport().set_input_as_handled()
		skip()


func _process(_delta: float) -> void:
	if is_following():
		camera.global_transform = object_camera.make_transform(camera.global_transform)
	if is_flying() or is_following():
		camera.make_current()


func _physics_process(delta: float) -> void:
	if is_flying():
		_advance_flight(delta)


func _advance_flight(delta: float) -> void:
	if path == null or camera == null:
		return
	var current := path
	for i in path.advance(delta):
		_raise_waypoint(i)
	if path == current:
		camera.global_transform = path.make_transform()


## Waypoint callbacks run from the script timers (next frame), never inside a script call.
func _raise_waypoint(index: int) -> void:
	var fn := "%s::camera::waypoint%d" % [path.path_name, index + 1]
	rt.log_debug("camera %s" % fn)
	if rt.vm and rt.vm.has_function(fn):
		rt.schedule(fn + "();", 0.0)


func _schedule_fallback_callbacks(key: String) -> void:
	push_warning("SSCutscene: no camera path data for %s" % key)
	for k in range(1, MAX_FALLBACK_WAYPOINTS + 1):
		var fn := "%s::camera::waypoint%d" % [key, k]
		if rt.vm and rt.vm.has_function(fn):
			rt.schedule(fn + "();", FALLBACK_WAYPOINT_INTERVAL * k)


func _show_camera() -> void:
	if camera == null:
		camera = Camera3D.new()
		camera.name = "CutsceneCamera"
		var chase: Camera3D = rt.battle.cameras.chase_cam if rt.battle.get("cameras") else null
		if chase:
			camera.far = chase.far
			camera.fov = chase.fov
		rt.battle.add_child(camera)
	camera.make_current()
	_apply_screen()


## Letterbox and skip hint while the cut-scene runs; the battle HUD is hidden meanwhile.
func _apply_screen() -> void:
	var on := is_running()
	if _screen == null and on:
		_screen = _build_screen()
		add_child(_screen)
	if _screen:
		_screen.visible = on
	var overlay = rt.battle.get("overlay")
	if overlay is CanvasLayer:
		if on and overlay.visible:
			_overlay_was_visible = true
			overlay.visible = false
		elif not on:
			overlay.visible = _overlay_was_visible


func _build_screen() -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.layer = 50
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.anchor_left = 0.0
		bar.anchor_right = 1.0
		bar.anchor_top = 0.0 if top else 1.0 - LETTERBOX_FRACTION
		bar.anchor_bottom = LETTERBOX_FRACTION if top else 1.0
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(bar)
	var hint := Label.new()
	hint.text = SKIP_HINT
	hint.theme_type_variation = "DimLabel"
	hint.anchor_left = 1.0
	hint.anchor_right = 1.0
	hint.anchor_top = 1.0
	hint.anchor_bottom = 1.0
	hint.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	layer.add_child(hint)
	return layer
