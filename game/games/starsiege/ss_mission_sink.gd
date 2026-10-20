class_name SSMissionSink
extends MissionSink
## The campaign radio and the message line of a Starsiege battle: the output port of the mission's announcer.

var _rt: StarsiegeMissionRuntime


func _init(runtime: StarsiegeMissionRuntime) -> void:
	_rt = runtime


## Radio lines go to the campaign radio with their wav; info lines to the battle's message line.
func apply_message(message: MissionMessage) -> void:
	if message.channel == MissionMessage.CHANNEL_RADIO:
		var wav := "" if message.voice == null else str(message.voice.id)
		_rt.battle.radio(message.speaker, message.text, wav)
	else:
		_rt.battle.fx("message", [message.text, message.seconds], true)
