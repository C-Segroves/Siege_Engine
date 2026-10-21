class_name BriefingPane
extends VBoxContainer
## Option B of the lobby's right pane: the campaign briefing (docs/design/lobby_loadout_economy.md section 5.1). From the
## top: the mission heading, the leader video in a MediaBox (at most half the screen high, only while the campaign has
## clips to play, once per mission), the mission map (a note when
## BriefingSource has no picture), the briefing text and the objectives.
##   show_briefing(BriefingSource.make_briefing(settings))

var heading: Label
var map_view: TextureRect
var map_note: Label
var text_label: Label
var objectives_label: Label
var media: MediaBox
var _objectives_title: Label
var _shown_key := ""


func _init() -> void:
	heading = Widgets.section("")
	add_child(heading)
	map_view = TextureRect.new()
	map_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_view.custom_minimum_size = Vector2(0, Widgets.metric("row_height") * 8)
	map_view.visible = false
	add_child(map_view)
	map_note = Widgets.label(BriefingMap.NO_TERRAIN_NOTE, "DimLabel")
	map_note.visible = false
	add_child(map_note)
	text_label = Widgets.paragraph("")
	add_child(text_label)
	_objectives_title = Widgets.section("Objectives")
	add_child(_objectives_title)
	objectives_label = Widgets.paragraph("")
	add_child(objectives_label)


## Shows `b` (BriefingSource.make_briefing); the video and talks start the first time a mission is shown.
func show_briefing(b: Dictionary) -> void:
	var key := JSON.stringify([b.heading, b.text, b.objectives])
	if key == _shown_key:
		return
	_shown_key = key
	heading.text = str(b.heading)
	text_label.text = str(b.text)
	var objectives: Array = b.objectives
	_objectives_title.visible = not objectives.is_empty()
	objectives_label.visible = not objectives.is_empty()
	objectives_label.text = "- " + "\n- ".join(PackedStringArray(objectives)) if not objectives.is_empty() else ""
	map_view.texture = b.map
	map_view.visible = b.map != null
	map_note.visible = b.map == null and not str(b.heading).is_empty()
	if not (b.movies as Array).is_empty() or not (b.talks as Array).is_empty():
		_present(b)


## The movies, then the talking heads, below the heading, once per mission.
func _present(b: Dictionary) -> void:
	if not CampaignPresentation.take_first_showing(CampaignPresentation.MOMENT_BRIEFING, str(b.heading)):
		return
	if not (b.movies as Array).is_empty():
		media = MediaBox.new()
		add_child(media)
		move_child(media, heading.get_index() + 1)
		await MoviePlayer.play_all_in(media, b.movies)
		if is_instance_valid(media):
			media.queue_free()
			media = null
	if is_inside_tree():
		ShellTalkPanel.add_to(self, b.talks, heading.get_index() + 1)
