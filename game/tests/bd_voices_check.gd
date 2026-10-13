extends Node
## Headless check of Battledrome's in-sim voices (BdVoices, ArenaAnnouncer, BdCockpitMessages, Sfx.play_voice):
## the end-of-round announcer fires ENDRND1 / AREAN01 / AREAN11 (won) or AREAN12 (lost) at the decoded times,
## and the cockpit messages keep the original's repeat, spacing, queue and shield thresholds; a message voice halves
## every other sound while it plays (0x2821c) and the Battledrome voices switch silences both (the user's setting is
## restored).  Needs the
## Battledrome import (skipped without it).  Last, a Battledrome arena battle: a nearly empty shield makes the
## player's Herc say SHIELDS DEPLETED, and the end of the match plays the announcer with the winner's AREAN11.
## Run silent:
##   godot --headless --audio-driver Dummy --path game res://tests/bd_voices_check.tscn

const TIME_TOLERANCE := 0.15
const MSEC_PER_SECOND := 1000.0
const SHIELDS_DEPLETED := 1
const SHIELDS_LOW := 2
const INTERNAL_DAMAGE := 0
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const ARENA_HERC := "bd:THOR"
const SETTLE_FRAMES := 30
const NEARLY_EMPTY_SHIELD := 10.0 / 256.0

var _failures := 0
var _heard := []            # [seconds since start, voice name]
var _start_msec := 0
var _shown: Array[String] = []


func _ready() -> void:
	if BdVoices.table().is_empty():
		print("bd_voices_check: skipped (Battledrome not imported)")
		get_tree().quit(0)
		return
	_check_end_sequence_data()
	_check_voices_on_disk()
	_check_shield_thresholds()
	_check_message_gating()
	await _check_announcer_timing()
	await _check_ducking()
	_check_voices_switch()
	await _check_arena_battle()
	print("bd_voices_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _check_end_sequence_data() -> void:
	var won := ArenaAnnouncer.make_end_sequence(true)
	var lost := ArenaAnnouncer.make_end_sequence(false)
	_expect(won.map(func(s): return s[1]) == ["bd:endrnd1", "bd:arean01", "bd:arean11"], "won: ENDRND1, AREAN01, AREAN11")
	_expect(String(lost[-1][1]) == "bd:arean12", "lost: AREAN12 last")
	_expect(won.map(func(s): return snappedf(s[0], 0.001)) == [0.0, 2.048, 4.096], "0x200 units (2.048 s) between voices")


func _check_voices_on_disk() -> void:
	for stem in ["endrnd1", "arean01", "arean11", "arean12", "sher03", "sher04", "sher05"]:
		_expect(Sfx.stream(BdVoices.sound_name(stem)) != null, "voice %s imported" % stem)
	_expect(BdVoices.message_text(SHIELDS_LOW) == "SHIELDS LOW", "message 2 is SHIELDS LOW")
	_expect(String(BdVoices.message(SHIELDS_LOW).voice) == "sher03", "SHIELDS LOW says SHER03")


func _check_shield_thresholds() -> void:
	var w: Dictionary = BdVoices.table().shield_warning
	_expect(BdCockpitMessages.make_shield_message(0, w) == -1, "an empty shield says nothing (0x803d)")
	_expect(BdCockpitMessages.make_shield_message(25, w) == SHIELDS_DEPLETED, "25/256 -> SHIELDS DEPLETED")
	_expect(BdCockpitMessages.make_shield_message(26, w) == SHIELDS_LOW, "26/256 -> SHIELDS LOW")
	_expect(BdCockpitMessages.make_shield_message(63, w) == SHIELDS_LOW, "63/256 -> SHIELDS LOW")
	_expect(BdCockpitMessages.make_shield_message(64, w) == -1, "64/256 -> no warning")
	var h := Herc.new()
	h.shield_max = 4000.0
	h.shield_front = 150.0
	h.shield_rear = 100.0
	_expect(BdCockpitMessages.make_shield_level(h, int(w.scale)) == 16, "level = shield * 256 / SG points, truncated")
	h.free()


func _check_message_gating() -> void:
	var m := BdCockpitMessages.new(func(t: String) -> void: _shown.append(t))
	var spacing := float(BdVoices.table().message_spacing_s)
	_expect(m.post(SHIELDS_LOW), "first SHIELDS LOW is shown")
	_expect(_shown == ["SHIELDS LOW"], "its text is shown")
	m.clock += spacing + 0.1
	_expect(not m.post(SHIELDS_DEPLETED), "SHIELDS DEPLETED shares SHIELDS LOW's 10.24 s timer")
	m.clock += float(BdVoices.message(SHIELDS_DEPLETED).repeat_s)
	_expect(m.post(SHIELDS_DEPLETED), "... and is shown once it has passed")
	_expect(not m.post(INTERNAL_DAMAGE), "INTERNAL DAMAGE within 2.048 s of a message waits")
	_expect(m.queued() == [INTERNAL_DAMAGE], "... in the queue (its queued flag)")
	m.update(null, spacing * 0.5, false)
	_expect(_shown.size() == 2, "not before the spacing has passed")
	m.update(null, spacing, false)
	_expect(_shown.size() == 3 and _shown[-1] == "INTERNAL DAMAGE", "then the queue posts it")
	m.clock += 0.1
	_expect(not m.post(SHIELDS_LOW) and m.queued().is_empty(), "a message without the queued flag is dropped")


func _check_ducking() -> void:
	var bus := AudioServer.get_bus_index(Sfx.DUCKED_BUS)
	var m := BdCockpitMessages.new(func(_t: String) -> void: pass)
	m.post(SHIELDS_LOW)
	_expect(Sfx.is_ducked() and is_equal_approx(AudioServer.get_bus_volume_db(bus), Sfx.DUCK_DB),
		"a message voice halves every other sound")
	_expect(Sfx.music_player.bus == Sfx.DUCKED_BUS, "the music is among the halved sounds")
	await get_tree().create_timer(Sfx.stream("bd:sher03").get_length() + 0.3).timeout
	_expect(not Sfx.is_ducked() and is_equal_approx(AudioServer.get_bus_volume_db(bus), 0.0),
		"full volume again once the voice has ended")


func _check_voices_switch() -> void:
	var had := Assets.settings.has(AudioSettings.VOICES_KEY)
	var saved = Assets.settings.get(AudioSettings.VOICES_KEY)
	_expect(AudioSettings.DEFAULT_VOICES, "voices are on by default (Preferences VOICES)")
	Assets.settings[AudioSettings.VOICES_KEY] = false
	_heard.clear()
	Sfx.voice_started.connect(_on_voice)
	ArenaAnnouncer.play_end_of_round(true)
	var shown: Array[String] = []
	BdCockpitMessages.new(func(t: String) -> void: shown.append(t)).post(SHIELDS_LOW)
	Sfx.voice_started.disconnect(_on_voice)
	_expect(_heard.is_empty(), "voices off: no announcer, no warning voice")
	_expect(shown == ["SHIELDS LOW"], "voices off: the warning text still shows")
	if had:
		Assets.settings[AudioSettings.VOICES_KEY] = saved
	else:
		Assets.settings.erase(AudioSettings.VOICES_KEY)


func _check_announcer_timing() -> void:
	await get_tree().process_frame   # the loading frame's long delta would count toward the timers
	await get_tree().process_frame
	Sfx.voice_started.connect(_on_voice)
	_start_msec = Time.get_ticks_msec()
	ArenaAnnouncer.play_end_of_round(false)
	var expected := ArenaAnnouncer.make_end_sequence(false)
	await get_tree().create_timer(float(expected[-1][0]) + 0.5).timeout
	_expect(_heard.size() == expected.size(), "%d voices fired" % expected.size())
	for i in mini(_heard.size(), expected.size()):
		var ok: bool = _heard[i][1] == expected[i][1] and absf(_heard[i][0] - float(expected[i][0])) <= TIME_TOLERANCE
		_expect(ok, "%s at %.3f s (heard at %.3f s)" % [expected[i][1], expected[i][0], _heard[i][0]])
	Sfx.voice_started.disconnect(_on_voice)


func _on_voice(name: String) -> void:
	_heard.append([(Time.get_ticks_msec() - _start_msec) / MSEC_PER_SECOND, name])


func _check_arena_battle() -> void:
	var battle: Battle = load(BATTLE_SCENE).instantiate()
	var config := BattleSetup.make_default_config(ARENA_HERC)
	config.merge({"mode": "vs", "respawn": true, "ai": [], "arena": {"size": 1, "obstacles": "FEW", "turrets": "NONE",
		"lighting": "BRIGHT"}}, true)
	battle.config = config
	get_tree().root.add_child(battle)
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	var player := battle.player
	_expect(player != null and player.vehicle_id == ARENA_HERC, "the arena battle runs with a Battledrome Herc")
	if player == null:
		battle.queue_free()
		return
	_heard.clear()
	Sfx.voice_started.connect(_on_voice)
	_start_msec = Time.get_ticks_msec()
	player.shield_front = player.shield_max * NEARLY_EMPTY_SHIELD * 0.5
	player.shield_rear = player.shield_front
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(_heard.map(func(h): return h[1]).has("bd:sher04"), "a nearly empty shield says SHIELDS DEPLETED (SHER04)")
	_heard.clear()
	_start_msec = Time.get_ticks_msec()
	battle.end_match("%s wins the match!" % player.display_name, {}, player.display_name)
	var expected := ArenaAnnouncer.make_end_sequence(true)
	await get_tree().create_timer(float(expected[-1][0]) + 0.5).timeout
	var names := _heard.map(func(h): return h[1])
	_expect(names == expected.map(func(s): return s[1]), "the match end plays ENDRND1, AREAN01, AREAN11 (heard %s)" % str(names))
	Sfx.voice_started.disconnect(_on_voice)
	battle.queue_free()
