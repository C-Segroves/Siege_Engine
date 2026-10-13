extends Node
## Screenshots of the Starsiege campaign features (needs a window, not --headless):
##   godot --audio-driver Dummy --path game res://tests/ss_campaign_shots.tscn
## Writes renders/ss_campaign_turret.png (HA4 turrets firing at the player), ss_campaign_interior.png
## (HA0 mole tunnel interior around the player) and ss_campaign_cutscene.png (HE1 intro camera path).

const SHOTS := [
	{"mission": "HA4", "file": "ss_campaign_turret.png", "at": 6.0},
	{"mission": "HA0", "file": "ss_campaign_interior.png", "at": 3.0},
	{"mission": "HE1", "file": "ss_campaign_cutscene.png", "at": 4.0},
]
const TURRET := "MissionGroup/base/Turrets/turret1"
const TURRET_DISTANCE := 250.0

var index := -1
var battle: Node
var ms: StarsiegeMissionRuntime
var t := 0.0
var _cam: Camera3D
var _pin := Vector3.INF


func _ready() -> void:
	process_priority = 200   # after Battle._process, which makes its own camera current
	_next()


func _next() -> void:
	if battle:
		battle.queue_free()
	battle = null
	ms = null
	_cam = null
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
		if ms:
			_stage()
		return
	if _pin != Vector3.INF:
		battle.player.global_position = _pin
	if t >= float(SHOTS[index].at):
		_save()


func _stage() -> void:
	match SHOTS[index].mission:
		"HA4":
			var tur := ms.tree.node_of(ms.ss_resolve(TURRET)) as SSTurret
			var p := tur.global_position + Vector3(TURRET_DISTANCE, 0, 0)
			p.y = ms.ground_height_at(p) + 0.5
			_pin = p
			_place_camera(p + Vector3(60, 25, 50), tur.global_position.lerp(p, 0.5) + Vector3.UP * 8.0)
		"HA0":
			var drop: Vector3 = SSObjectTree.position_of_def(ms.m.drop_points[0])
			_place_camera(drop + Vector3(0, 6, 25), drop + Vector3(0, 3, -40))


func _place_camera(from: Vector3, look: Vector3) -> void:
	_cam = Camera3D.new()
	_cam.far = 4000.0
	battle.add_child(_cam)
	_cam.global_position = from
	_cam.look_at(look)


func _process(_d: float) -> void:
	if _cam:
		_cam.make_current()


func _save() -> void:
	var img := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://").path_join("../renders/" + String(SHOTS[index].file))
	img.save_png(path)
	print("saved ", path)
	_next()
