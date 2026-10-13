class_name ShellTalkPanel
extends VBoxContainer
## The original shell's talking heads on a launcher screen (briefing, debriefing): the 320x200 shell display
## (ShellScreen) showing the speaker's room and lip-synced head (TalkingHead), the subtitle under it. Any click or
## key skips the line being spoken.
## A talk: {speaker: "C0".., line, region: shell region (3000 commander rooms, 5000 debriefing rooms), campaign}.

## Shell rooms of the speakers (EsShell.set_region: REGN<region>, the palette of REGN<region + campaign>).
const ROOM_DIR := "RES32"
const BRIEFING_REGION := 3000
const DEBRIEFING_REGION := 5000
## Ambient TTMs of each room (ShellSequences: the commander's room door and lights, the officer's blink).
const AMBIENT_BY_REGION := {BRIEFING_REGION: ["C%d_BRD", "C%d_BRJ"], DEBRIEFING_REGION: ["C%d_BLNK"]}
## Display size on the launcher page (twice the original resolution).
const DISPLAY_SIZE := Vector2(640, 400)

var screen: ShellScreen
var voice: AudioStreamPlayer
var subtitle: Label
var _scene: TTMScene
var _skip := false


func _ready() -> void:
	var holder := Control.new()
	holder.custom_minimum_size = DISPLAY_SIZE
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	add_child(holder)
	screen = ShellScreen.new()
	holder.add_child(screen)
	screen.cursor_visible = false
	voice = AudioStreamPlayer.new()
	add_child(voice)
	subtitle = Widgets.paragraph("")
	add_child(subtitle)


## Adds a panel speaking `talks` to `parent` at child `index` (-1: last); null (nothing added) when there are none.
static func add_to(parent: Control, talks: Array, index := -1) -> ShellTalkPanel:
	if talks.is_empty():
		return null
	var panel := ShellTalkPanel.new()
	parent.add_child(panel)
	if index >= 0:
		parent.move_child(panel, index)
	panel.play(talks)
	return panel


## Speaks `talks` one after another; awaitable.
func play(talks: Array) -> void:
	for t in talks:
		if not is_inside_tree():
			return
		await _play_one(t)
	subtitle.text = ""


func _play_one(t: Dictionary) -> void:
	var region := int(t.get("region", BRIEFING_REGION))
	var campaign := int(t.get("campaign", 0))
	screen.set_palette(ShellData.palette("REGN%d" % (region + campaign), ROOM_DIR), false)
	_scene = TTMScene.new(screen)
	var bg := ShellData.background("REGN%d" % (region if region == BRIEFING_REGION else region + campaign), ROOM_DIR)
	if bg:
		_scene.set_background(bg)
	var ambient := []
	for pattern in AMBIENT_BY_REGION.get(region, []):
		var n := str(pattern) % campaign
		if not ShellData.ttm(n).is_empty():
			ambient.append(n)
	subtitle.text = TalkingHead.make_subtitle(str(t.speaker), int(t.line))
	_skip = false
	await TalkingHead.new(_scene, voice, self, func() -> bool: return _skip).play(str(t.speaker), int(t.line), ambient)


func _process(delta: float) -> void:
	if _scene:
		_scene.update(delta)
		screen.image.copy_from(_scene.scr)


func _gui_input(event: InputEvent) -> void:
	if event.is_pressed() and not event.is_echo():
		_skip = true
