extends Node
## MissionMessage, MissionVoice, MissionAnnouncer (the three disciplines) and MissionEnder (engine/mission/).
##   godot --headless --audio-driver Dummy --path game res://tests/mission_messages_check.tscn

const WATCHDOG_SECONDS := 30.0

var _fails := 0


class RecordingSink:
	extends MissionSink
	var log: Array = []
	var voice_playing := false
	func apply_message(m: MissionMessage) -> void:
		log.append("text:" + m.text)
	func apply_voice(v: MissionVoice) -> void:
		log.append("voice:" + str(v.id))
	func is_voice_playing() -> bool:
		return voice_playing


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void:
		print("FAIL  watchdog: the check hung")
		get_tree().quit(2))
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_fails += 1


func _run() -> void:
	_check_message()
	_check_replace_waiting()
	_check_fifo()
	_check_cut()
	_check_sink_busy()
	_check_ender()
	print("mission_messages_check: %d failures" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _say(a: MissionAnnouncer, text: String, voice_id: Variant = null, seconds := 2.0, interrupt := false) -> void:
	var v: MissionVoice = null if voice_id == null else MissionVoice.make_voice(voice_id, seconds, interrupt)
	a.apply_say(MissionMessage.make_message(text, seconds, MissionMessage.CHANNEL_RADIO, "", v))


func _check_message() -> void:
	var m := MissionMessage.make_message("hello", 4.0, MissionMessage.CHANNEL_INFO, "base", MissionVoice.make_voice(9, 6.0))
	_expect(m.make_busy_seconds() == 6.0, "a voice of known length sets how long the radio is busy")
	_expect(MissionMessage.make_message("x", 3.0).make_busy_seconds() == 3.0, "else the text time does")
	_expect(MissionMessage.make_voice_only(MissionVoice.make_voice(1)).text == "", "a voice alone has no text")
	var list: Array[MissionMessage] = [MissionMessage.make_voice_only(MissionVoice.make_voice(1, 2.0)),
		MissionMessage.make_voice_only(MissionVoice.make_voice(2, 3.0)), MissionMessage.make_voice_only(MissionVoice.make_voice(3))]
	_expect(Array(MissionAnnouncer.make_start_times(list, 1.0)) == [1.0, 3.0, 6.0], "start times of a FIFO list: each waits for the one before")


func _check_replace_waiting() -> void:
	var s := RecordingSink.new()
	var a := MissionAnnouncer.new(s, MissionAnnouncer.Discipline.REPLACE_WAITING)
	_say(a, "one", 1)
	_say(a, "two", 2)
	_say(a, "three", 3)
	_expect(s.log == ["text:one", "voice:1"] and a.make_waiting_count() == 1, "one waits behind the one playing; a newer one replaces it (%s)" % str(s.log))
	a.apply_tick(1.0)
	_expect(s.log.size() == 2, "nothing plays before the first ends")
	a.apply_tick(1.5)
	_expect(s.log == ["text:one", "voice:1", "text:three", "voice:3"], "the newest waiting one plays next (%s)" % str(s.log))
	_say(a, "closing", 99, 2.0, true)
	_expect(s.log.slice(4) == ["text:closing", "voice:99"], "an interrupting voice cuts at once")
	a.apply_tick(5.0)
	_expect(a.is_idle(), "the radio falls idle")


func _check_fifo() -> void:
	var s := RecordingSink.new()
	var a := MissionAnnouncer.new(s, MissionAnnouncer.Discipline.FIFO, 3.0)
	_say(a, "first")
	_say(a, "second")
	_expect(s.log.is_empty() and a.is_busy(), "the first message waits for the first delay")
	a.apply_tick(2.9)
	_expect(s.log.is_empty(), "still waiting")
	a.apply_tick(0.2)
	_expect(s.log == ["text:first"], "then the first plays (%s)" % str(s.log))
	a.apply_tick(2.1)
	_expect(s.log == ["text:first", "text:second"], "every message plays in turn (%s)" % str(s.log))
	_say(a, "third")
	_expect(is_equal_approx(a.make_busy_seconds(), 4.0), "make_busy_seconds counts what plays and what waits (%f)" % a.make_busy_seconds())


func _check_cut() -> void:
	var s := RecordingSink.new()
	var a := MissionAnnouncer.new(s, MissionAnnouncer.Discipline.CUT)
	_say(a, "a", 1)
	_say(a, "b", 2)
	_expect(s.log == ["text:a", "voice:1", "text:b", "voice:2"] and a.make_waiting_count() == 0, "a new message cuts what plays")


func _check_sink_busy() -> void:
	var s := RecordingSink.new()
	var a := MissionAnnouncer.new(s)
	_say(a, "first", null, 0.0)
	s.voice_playing = true
	a.apply_say(MissionMessage.make_message("second"))
	_expect(a.is_busy() and s.log.size() == 1, "a voice the sink says is playing keeps the radio busy")
	s.voice_playing = false
	a.apply_tick(0.1)
	_expect(a.is_idle(), "and frees it when it ends")


func _check_ender() -> void:
	var ended := []
	var s := RecordingSink.new()
	var e := MissionEnder.new(func(ok: bool, code: int, text: String) -> void: ended.append([ok, code, text]), s.is_voice_playing)
	e.apply_tick(1.0)
	_expect(ended.is_empty(), "no verdict, no end")
	e.apply_verdict(MissionVerdict.make_win(5, "won", 4.9))
	e.apply_verdict(MissionVerdict.make_loss(6, "lost"))
	_expect(e.has_verdict(), "a verdict is held")
	e.apply_tick(4.0)
	_expect(ended.is_empty(), "the grace delays the end")
	e.apply_tick(1.0)
	e.apply_tick(1.0)
	_expect(ended == [[true, 5, "won"]], "the first verdict wins and the end is called once (%s)" % str(ended))
	_expect(e.is_ended(), "the ender is spent")
	# waiting for the voice, at most VOICE_WAIT_MAX seconds
	ended.clear()
	s.voice_playing = true
	var w := MissionEnder.new(func(ok: bool, code: int, text: String) -> void: ended.append([ok, code, text]), s.is_voice_playing)
	w.apply_verdict(MissionVerdict.make_loss(1, "x", 0.0, true))
	for _i in 10:
		w.apply_tick(1.0)
	_expect(ended.is_empty(), "the end waits while the voice plays")
	for _i in 6:
		w.apply_tick(1.0)
	_expect(ended.size() == 1, "but not for more than %d s" % int(MissionEnder.VOICE_WAIT_MAX))
	ended.clear()
	s.voice_playing = false
	var n := MissionEnder.new(func(ok: bool, code: int, text: String) -> void: ended.append([ok, code, text]), s.is_voice_playing)
	n.apply_verdict(MissionVerdict.make_loss(1, "x", 0.0, true))
	n.apply_tick(0.1)
	_expect(ended.size() == 1, "a finished voice ends it at once")
	ended.clear()
	var o := MissionEnder.new(func(ok: bool, code: int, text: String) -> void: ended.append([ok, code, text]), s.is_voice_playing)
	o.apply_verdict(MissionVerdict.make_loss(6, "death", 8.0))
	o.apply_override(MissionVerdict.make_win(1, "script"))
	o.apply_tick(0.0)
	o.apply_override(MissionVerdict.make_loss(6, "late"))
	_expect(ended == [[true, 1, "script"]], "an override takes over the held verdict, and not after the end (%s)" % str(ended))
	# the grace after the voice (Aerial Assault: the closing prompt plays, then 2 s)
	ended.clear()
	s.voice_playing = true
	var g := MissionEnder.new(func(ok: bool, code: int, text: String) -> void: ended.append([ok, code, text]), s.is_voice_playing)
	g.apply_verdict(MissionVerdict.make_win(1, "aa", 2.0, true).apply_grace_after_voice())
	for _i in 5:
		g.apply_tick(1.0)
	_expect(ended.is_empty(), "the grace does not run while the voice plays")
	s.voice_playing = false
	g.apply_tick(1.0)
	_expect(ended.is_empty(), "and starts when it has played")
	g.apply_tick(1.0)
	_expect(ended == [[true, 1, "aa"]], "the end follows the grace (%s)" % str(ended))
