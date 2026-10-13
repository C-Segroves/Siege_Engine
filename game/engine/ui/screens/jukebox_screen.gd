extends RoutedScreen
## Jukebox: plays one game's soundtrack tracks. args: {"pack": pack id}.

const SECONDS_PER_MINUTE := 60


func open(args: Dictionary) -> void:
	var pack := str(args.get("pack", ""))
	var st: Dictionary = Soundtracks.all().get(pack, {"name": pack, "tracks": []})
	set_page_title("jukebox  -  %s" % st.name)
	set_back("Back to library", _leave)
	set_primary("Stop", _stop)
	if st.tracks.is_empty():
		content.add_child(Widgets.label("No tracks.", "DimLabel"))
	for t in st.tracks:
		var b := Widgets.button(_make_track_text(t), func() -> void: _play(t))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		content.add_child(b)


static func _make_track_text(t: Dictionary) -> String:
	var secs := int(t.seconds)
	var length := "   %d:%02d" % [secs / SECONDS_PER_MINUTE, secs % SECONDS_PER_MINUTE] if secs > 0 else ""
	return "%s%s   [%s]" % [t.title, length, t.source]


func _play(t: Dictionary) -> void:
	Sfx.play_file(t.file)
	set_status("Now playing: " + str(t.title))


func _stop() -> void:
	Sfx.music_player.stop()
	set_status("")


func _leave() -> void:
	Sfx.music_player.stop()
	router.back()
