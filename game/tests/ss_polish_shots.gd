extends Node
## Screenshots of the Starsiege polish features (needs a window, not --headless):
##   godot --audio-driver Dummy --path game res://tests/ss_polish_shots.tscn
## Writes renders/ss_polish_snow.png (CC1 snowfall), ss_polish_rain.png (CD1 rain),
## ss_polish_dominant.png (HA4 setDominantCamera: turret over the player), ss_polish_flyby.png (HA4
## setFlybyCamera on the player) and ss_polish_fire.png (HA4 turret burning under its fire threshold).

const SHOTS := [
	{"mission": "CC1", "file": "ss_polish_snow.png", "at": 5.0, "stage": "chase"},
	{"mission": "CD1", "file": "ss_polish_rain.png", "at": 5.0, "stage": "chase"},
	{"mission": "HA4", "file": "ss_polish_dominant.png", "at": 4.0, "stage": "dominant"},
	{"mission": "HA4", "file": "ss_polish_flyby.png", "at": 4.0, "stage": "flyby"},
	{"mission": "HA4", "file": "ss_polish_fire.png", "at": 4.0, "stage": "fire"},
]
const TURRET := "MissionGroup/base/Turrets/turret1"
const TURRET_DISTANCE := 120.0
## Seconds after loading before the stage is set (the script's own intro cameras run first).
const STAGE_DELAY := 1.5

var index := -1
var battle: Node
var ms: StarsiegeMissionRuntime
var t := 0.0
var _staged := false
var _pin := Vector3.INF
var _cam: Camera3D


func _ready() -> void:
	process_priority = 200   # after Battle._process and SSCutscene, which make their cameras current
	_next()


func _next() -> void:
	if battle:
		battle.queue_free()
	battle = null
	ms = null
	_cam = null
	_staged = false
	_pin = Vector3.INF
	t = 0.0
	index += 1
	if index >= SHOTS.size():
		get_tree().quit()
		return
	battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "mission_name": "starsiege:" + SHOTS[index].mission, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "starsiege:pi_eman", "team": 0, "loadout": []}}}
	get_tree().root.add_child.call_deferred(battle)


func _physics_process(delta: float) -> void:
	if battle == null:
		return
	t += delta
	if ms == null:
		ms = battle.get("mission") as StarsiegeMissionRuntime
		return
	if _pin != Vector3.INF and is_instance_valid(battle.player):
		battle.player.global_position = _pin
		battle.player.velocity = Vector3.ZERO
	if not _staged and t >= STAGE_DELAY:
		_staged = true
		_stage(String(SHOTS[index].stage))
	if t >= float(SHOTS[index].at):
		_save()


func _stage(stage: String) -> void:
	if ms.cutscene.is_running():
		ms.cutscene.end_camera()
		ms.cutscene.lock_input(false)
	if stage == "chase":
		_place_camera_behind_player()
		return
	var turret := ms.tree.node_of(ms.ss_resolve(TURRET)) as SSTurret
	var p := turret.global_position + turret.global_basis.z * -TURRET_DISTANCE
	p.y = ms.ground_height_at(p) + 0.5
	_pin = p
	battle.player.global_position = p
	var player_id: int = ms.tree.player_objs.keys()[0]
	match stage:
		"dominant":
			ms.ss_builtin("setdominantcamera", [player_id, ms.ss_resolve(TURRET)])
		"flyby":
			ms.ss_builtin("setflybycamera", [player_id, -6, 40, 20])
		"fire":
			turret.hp = turret.fire_threshold * 0.9
			ms.ss_builtin("settowercamera", [ms.ss_resolve(TURRET)] + _tower_point(turret))
			_pin = turret.global_position + Vector3(2000, 0, 0)


## A mission point (original frame) 60 m beside the turret, 25 m up.
func _tower_point(turret: Node3D) -> Array:
	var o := StarsiegeMissionRuntime.eng_to_orig(turret.global_position + Vector3(60, 25, 40))
	return [o.x, o.y, o.z]


func _place_camera_behind_player() -> void:
	var h: Node3D = battle.player
	_cam = Camera3D.new()
	_cam.far = 4000.0
	battle.add_child(_cam)
	_cam.global_position = h.global_position + h.global_basis.z * 25.0 + Vector3.UP * 9.0
	_cam.look_at(h.global_position - h.global_basis.z * 40.0 + Vector3.UP * 4.0)


func _process(_d: float) -> void:
	if _cam:
		_cam.make_current()


func _save() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://").path_join("../renders/" + String(SHOTS[index].file))
	img.save_png(path)
	print("saved ", path)
	_next()
