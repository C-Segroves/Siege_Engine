extends RoutedScreen
## Jukebox: plays soundtrack tracks. args: {"pack": pack id} for one game; without a pack (Options & tools > Music)
## every game's tracks, grouped by game, plus "Shuffle all" (MusicShuffle over everything installed).

const SECONDS_PER_MINUTE := 60


var _shuffle := MusicShuffle.new()


func open(args: Dictionary) -> void:
	var pack := str(args.get("pack", ""))
	var all := Soundtracks.all()
	set_back("Back to library", _leave)
	set_primary("Stop", _stop)
	if pack != "":
		var st: Dictionary = all.get(pack, {"name": pack, "tracks": []})
		set_page_title("jukebox  -  %s" % st.name)
		_add_tracks(st.tracks)
		return
	set_page_title("music")
	if all.is_empty():
		content.add_child(Widgets.label("No music yet - import a disc or add a soundtrack folder in Your library.", "DimLabel"))
		return
	content.add_child(Widgets.button("Shuffle all", _shuffle_all, Widgets.PRIMARY))
	for p in all:
		content.add_child(Widgets.section(str(all[p].name)))
		_add_tracks(all[p].tracks)


func _add_tracks(tracks: Array) -> void:
	if tracks.is_empty():
		content.add_child(Widgets.label("No tracks.", "DimLabel"))
	for t in tracks:
		var b := Widgets.button(_make_track_text(t), func() -> void: _play(t))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		content.add_child(b)


static func _make_track_text(t: Dictionary) -> String:
	var secs := int(t.seconds)
	var length := "   %d:%02d" % [secs / SECONDS_PER_MINUTE, secs % SECONDS_PER_MINUTE] if secs > 0 else ""
	return "%s%s   [%s]" % [t.title, length, t.source]


func _play(t: Dictionary) -> void:
	_shuffle.stop()
	Sfx.play_file(t.file)
	set_status("Now playing: " + str(t.title))


func _shuffle_all() -> void:
	_shuffle.stop()
	if _shuffle.start():
		set_status("Shuffling all music")


func _stop() -> void:
	_shuffle.stop()
	Sfx.music_player.stop()
	set_status("")


func _leave() -> void:
	_shuffle.stop()
	Sfx.music_player.stop()
	router.back()
