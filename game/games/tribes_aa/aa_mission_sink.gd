class_name AAMissionSink
extends MissionSink
## The mission blocks' output port over an Aerial Assault battle: a message is a radio line, a voice prompt plays from the
## training bank (audio/training/NNN.ogg: the executable's ids are indexes of the TRAINING bank).

const PACK := "tribes_aa"
const VOICE_FILE := "audio/training/%03d.ogg"
## Sound index of a prompt id: the executable's ids carry flags above bit 24 and count in halves (id & 0xFFFFFF) / 2.
const VOICE_ID_MASK := 0xFFFFFF

## The voice channel; null where the mission plays no prompts (the fallback goals).
var player: AudioStreamPlayer
var _battle: Node3D


func _init(p_battle: Node3D, p_player: AudioStreamPlayer) -> void:
	_battle = p_battle
	player = p_player


func apply_message(message: MissionMessage) -> void:
	if message.text != "" and _battle != null and _battle.has_method("radio"):
		_battle.radio("", message.text, "")


## Plays the prompt at once, cutting the one playing; silence when the bank has no such file.
func apply_voice(voice: MissionVoice) -> void:
	if player == null:
		return
	var path := Assets.path(VOICE_FILE % ((int(voice.id) & VOICE_ID_MASK) >> 1), PACK)
	if not FileAccess.file_exists(path):
		player.stop()
		return
	var stream := AudioStreamOggVorbis.load_from_file(path)
	if stream == null:
		return
	player.stream = stream
	player.play()


func is_voice_playing() -> bool:
	return player != null and player.playing
