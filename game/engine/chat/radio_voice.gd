class_name RadioVoice
extends Node
## The campaigns' radio (ChatChannels.RADIO): speaks the lines of wingmen, commanders and bases one after
## another, each with its voice clip when it has one, and announces a line (`line_started`) the moment its clip
## starts, so the chat shows the text with the voice. A line without a clip is announced as soon as no clip is
## playing. `voice` is a Sfx sound name ("pack:dir/stem", Sfx.stream).

signal line_started(speaker: String, text: String)

## Lines waiting longer than this many are dropped (oldest first) so the radio never falls far behind.
const MAX_QUEUE := 6
const VOICE_BUS := "Master"

var _queue: Array = []              # [speaker, text, voice]
var _speaker := ""                  # whose clip is playing ("" = none)
var _player: AudioStreamPlayer


func _ready() -> void:
	name = "RadioVoice"
	_player = AudioStreamPlayer.new()
	_player.bus = VOICE_BUS
	add_child(_player)
	_player.finished.connect(_play_next)


## Queues a line; it starts at once when the radio is quiet.
func say(speaker: String, text: String, voice := "") -> void:
	_queue.append([speaker, text, voice])
	while _queue.size() > MAX_QUEUE:
		_queue.pop_front()
	if not _player.playing:
		_play_next()


func is_speaking() -> bool:
	return _player.playing


## True while `speaker`'s voice clip plays (the cockpit's transmit lamps).
func is_speaker_talking(speaker: String) -> bool:
	return _player.playing and speaker != "" and speaker == _speaker


func _play_next() -> void:
	while not _queue.is_empty():
		var line: Array = _queue.pop_front()
		var s: AudioStream = Sfx.stream(str(line[2])) if str(line[2]) != "" else null
		line_started.emit(str(line[0]), str(line[1]))
		if s != null:
			_speaker = str(line[0])
			_player.stream = s
			_player.play()
			return
