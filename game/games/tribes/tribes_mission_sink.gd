class_name TribesMissionSink
extends MissionSink
## The mission blocks' output port over the Battle of a Tribes / Tribes 2 training mission:
##   radio messages   battle.radio(speaker, text, voice): a line with its voice clip in one call; a voice alone is a call
##                    with no text;
##   info messages    the message line (objectives, message boxes), once the battle's overlay exists (messages before
##                    that, from scripts that run while the battle is built, are not shown);
##   nav              one waypoint at a time: apply_nav_point(id, p) registers a point, apply_nav(id, true) shows it as
##                    a nav marker (the compass follows rt.nav_points) and apply_nav(id, false) clears it.

var rt: TribesMissionRuntime
var _points := {}               # nav id -> position (engine frame)
var _marker: Node3D
var _paired_voice: MissionVoice  # the voice that went out with the text just said
## Who says a voice that comes without text.
var voice_speaker := ""


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime


func apply_message(message: MissionMessage) -> void:
	if message.channel == MissionMessage.CHANNEL_INFO:
		if rt.battle.get("overlay") != null:
			rt.battle.fx("message", [message.text, message.seconds], true)
		return
	_paired_voice = message.voice
	rt.battle.radio(message.speaker, message.text, str(message.voice.id) if message.voice != null else "")


## A voice with no text; the voice of a message with text went out together with it.
func apply_voice(voice: MissionVoice) -> void:
	if voice == _paired_voice:
		_paired_voice = null
		return
	rt.battle.radio(voice_speaker, "", str(voice.id))


func apply_nav_point(id: String, p: Vector3) -> void:
	_points[id] = p


func apply_nav(id: String, on: bool) -> void:
	_clear_marker()
	if not on:
		return
	var p: Vector3 = _points.get(id, Vector3.ZERO)
	_marker = Marker3D.new()
	_marker.name = "Waypoint"
	_marker.position = p
	_marker.set_meta("label", id)
	_marker.add_to_group("nav_points")
	rt.battle.add_child(_marker)
	rt.nav_points = [p]
	rt.nav_index = 0


func _clear_marker() -> void:
	if is_instance_valid(_marker):
		_marker.queue_free()
	_marker = null
	rt.nav_points = []
	rt.nav_index = 0
