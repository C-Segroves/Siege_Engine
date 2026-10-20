class_name BattleMissionSink
extends MissionSink
## The mission blocks' output port over the Earthsiege Battle: a mission message is the battle's message line on every
## peer (or a campaign radio line when it has a speaker), and a nav change moves every peer's compass and objectives
## to the nav point (battle.fx "message" / "nav_index", Battle.radio).

var _battle: Node3D


func _init(p_battle: Node3D) -> void:
	_battle = p_battle


func apply_message(message: MissionMessage) -> void:
	if message.speaker != "":
		_battle.radio(message.speaker, message.text, str(message.voice.id) if message.voice != null else "")
		return
	_battle.fx("message", [message.text, message.seconds], true)


## `id` is the index of the nav point now current (co-op: the clients' compass and objectives follow).
func apply_nav(id: String, on: bool) -> void:
	if on:
		_battle.fx("nav_index", [int(id)], true)
