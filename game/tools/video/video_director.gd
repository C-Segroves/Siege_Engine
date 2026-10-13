extends Node
## Cinematic capture for trailers: plays one scripted shot from VideoShots, then quits. Meant to run
## under Movie Maker, which renders picture and sound into the file (nothing reaches the speakers):
##   godot --audio-driver Dummy --path game --write-movie <clip>.avi --fixed-fps 30 \
##         res://tools/video/video_director.tscn -- --shot=<name> [--seconds=<s>]
## The clip size is the project viewport size (set it with an override.cfg while recording).
## Prints "video_director: action_frame=<n>" when the action starts; the frames before it are
## warm-up (loading, Hercs settling) and get trimmed by the editing script.

const SHOT_FLAG := "--shot="
const SECONDS_FLAG := "--seconds="
const ACTION_MARKER := "video_director: action_frame=%d"
## Game seconds a shot may take to prepare before the director gives up (a broken shot must not
## record for ever).
const PREPARE_LIMIT := 30.0

var _shot: Node


func _ready() -> void:
	process_priority = VideoShots.DIRECTOR_PRIORITY
	var args := _make_args()
	var spec := VideoShots.make_spec(String(args.shot))
	if spec.is_empty():
		push_error("video_director: unknown shot '%s' (known: %s)" % [args.shot, ", ".join(VideoShots.names())])
		get_tree().quit(1)
		return
	_shot = _build_shot(spec)
	add_child(_shot)
	get_tree().create_timer(PREPARE_LIMIT + float(spec.get("seconds", VideoShots.DEFAULT_SECONDS))).timeout.connect(_abort)
	await _shot.prepare()
	print(ACTION_MARKER % Engine.get_process_frames())
	_shot.play()
	var seconds := float(args.get("seconds", spec.get("seconds", VideoShots.DEFAULT_SECONDS)))
	await get_tree().create_timer(seconds).timeout
	get_tree().quit()


func _abort() -> void:
	push_error("video_director: shot did not finish in time")
	get_tree().quit(1)


static func _make_args() -> Dictionary:
	var args := {"shot": ""}
	for a in OS.get_cmdline_user_args():
		if a.begins_with(SHOT_FLAG):
			args.shot = a.substr(SHOT_FLAG.length())
		elif a.begins_with(SECONDS_FLAG):
			args.seconds = float(a.substr(SECONDS_FLAG.length()))
	return args


static func _build_shot(spec: Dictionary) -> Node:
	var shot: Node
	match String(spec.kind):
		"hangar":
			shot = HangarTurntableShot.new()
		"lineup":
			shot = LineupPanShot.new()
		"duel":
			shot = WeaponDuelShot.new()
		_:
			shot = BattleShot.new()
	shot.spec = spec
	return shot
