class_name TalkingHead
extends RefCounted
## One Earthsiege talking head, lip-synced (docs/formats/shell.md: the SYNC TTMs): speaker "C0".."C3" (commanders),
## "D0".."D3" (debriefing officers), "G0" (the general), "T1" (the hangar chief); `line` indexes
## <speaker>_FILES.DAT / <speaker>_TEXT.BIN. Plays the line's voice clip and drives the SYNC TTM's mouth from the
## speech's sync frames on a TTMScene the caller draws. Used by the original shell (ShellSequences) and the
## launcher's briefings (ShellTalkPanel), so both show the same heads.

const TALK_BASE_SECONDS := 0.6      # silent talk length: base + per character
const TALK_SECONDS_PER_CHAR := 0.06
const TALK_TAIL := 0.6              # seconds the head keeps still after the speech
const MOUTH_CLOSED := 1             # SYNC tag of the resting mouth
const PACK := "es1"
## The shell speeches' folder in the pack's voice clips (audio/voice/shell).
const VOICE_DIR := "shell"

var scene: TTMScene
var voice: AudioStreamPlayer
var host: Node                      # whose frames and delta time the talk runs on
var is_skipped: Callable            # () -> bool: the viewer skipped the talk


func _init(p_scene: TTMScene, p_voice: AudioStreamPlayer, p_host: Node, p_is_skipped: Callable) -> void:
	scene = p_scene
	voice = p_voice
	host = p_host
	is_skipped = p_is_skipped


## The subtitle of `speaker`'s line `line` ("" when there is none).
static func make_subtitle(speaker: String, line: int) -> String:
	var texts := ShellData.strings("%s_TEXT" % speaker)
	return texts[line] if line >= 0 and line < texts.size() else ""


## Plays the line: the ambient TTMs, the head (on screen from the first frame), the voice and the mouth; awaitable.
func play(speaker: String, line: int, ambient := []) -> void:
	var files: Dictionary = ShellData.meta().get("snc_files", {}).get(speaker, {})
	var speech := _speech_file(files, line)
	for a in ambient:
		scene.add(a, false)
	var head := scene.add(files.get("ttm", "%s_SYNC.TTM" % speaker), false, true)
	scene.drive(head, MOUTH_CLOSED)
	var subtitle := make_subtitle(speaker, line)
	var length := _start_voice(speech, TALK_BASE_SECONDS + subtitle.length() * TALK_SECONDS_PER_CHAR)
	await host.get_tree().process_frame
	await _drive_mouth(head, _load_mouth_frames(speech), length)
	voice.stop()


static func _speech_file(files: Dictionary, line: int) -> String:
	var entries: Array = files.get("entries", [])
	if line >= 0 and line < entries.size() and not entries[line].is_empty():
		return ShellData.base_name(str(entries[line][-1])).to_lower()
	return ""


static func _load_mouth_frames(speech: String) -> Array:
	var sj = Assets.load_json("audio/voice/shell_sync/%s.json" % speech, "es1") if speech != "" else null
	return sj.get("frames", []) if sj is Dictionary else []


## Starts the voice clip if it exists; returns the talk length (the clip's, else `silent_length`). The clip is named
## and loaded like every radio voice (RadioLine, Sfx: es1 audio/voice/shell/<speech>.wav).
func _start_voice(speech: String, silent_length: float) -> float:
	var clip := RadioLine.make_voice_name(PACK, "%s/%s" % [VOICE_DIR, speech]) if speech != "" else ""
	voice.stream = Sfx.stream(clip) if clip != "" else null
	if voice.stream == null:
		return silent_length
	voice.play()
	return voice.stream.get_length()


## Drives the SYNC TTM's mouth from the speech's sync frames until the talk ends or is skipped.
func _drive_mouth(head: TTMScene.TTMThread, frames: Array, length: float) -> void:
	var t := 0.0
	while t < length + TALK_TAIL and not is_skipped.call() and host.is_inside_tree():
		var pos := voice.get_playback_position() if voice.playing else t
		var tag := MOUTH_CLOSED
		for f in frames:
			if float(f.start) <= pos:
				tag = int(f.tag)
		scene.drive(head, MOUTH_CLOSED if t >= length else tag)
		await host.get_tree().process_frame
		t += host.get_process_delta_time()
