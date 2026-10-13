class_name Tribes2Functions
extends DarkstarFunctionTable
## The engine functions the Tribes 2 training scripts (TrainingN.cs, SinglePlayerGame.cs, spDialog.cs) call, by
## lower-case name: Tribes 2's function table of the shared Darkstar script runtime (docs/formats/tribes2.md
## section 8), with the engine methods (Tribes2Methods) and the shared string / math / vector functions.
## Presentation-only calls (TribesPresentation) are accepted and ignored; anything else is unknown.

## nameToId of a missing object.
const NONE := -1
const MS_PER_SECOND := 1000.0
## The profile Torque plays the training voice with (alxCreateSource(AudioChat, file) in processText).
const VOICE_FOLDER := "voice/"
## A voice clip's length when the clip is not installed: about this many milliseconds per character of text.
const FALLBACK_WAVE_MS := 3000

var rt: Tribes2MissionRuntime
var sim: TribesSimObjects
var actors: TribesActors
var _message_callbacks := {}     # lower tag -> [function names]
var _search: Array = []          # containerSearchNext results


func _init(runtime: Tribes2MissionRuntime) -> void:
	rt = runtime
	sim = runtime.sim
	actors = runtime.actors
	include(DarkstarStdLib.new())
	include(Tribes2Methods.new(runtime))
	_register_objects()
	_register_messages()
	_register_audio()
	_register_game()
	for n in TribesPresentation.TRIBES2_FUNCTIONS:
		_on([n], _no_op)


func _register_objects() -> void:
	_on(["nametoid"], func(_n, a): var id := sim.resolve(_arg(a, 0)); return id if id > 0 else NONE)
	_on(["isobject"], func(_n, a): return 1 if sim.resolve(_arg(a, 0)) > 0 else 0)
	_on(["exec"], func(_n, a): rt.exec_script(_s(a, 0)); return "")
	_on(["schedule"], _schedule)
	_on(["cancel"], func(_n, a): rt.schedules.cancel(int(_f(a, 0))); return "")
	_on(["iseventpending"], func(_n, a): return 1 if rt.schedules.is_pending(int(_f(a, 0))) else 0)
	_on(["getsimtime"], func(_n, _a): return int(rt.sim_time * MS_PER_SECOND))
	_on(["containerraycast"], func(_n, a): return rt.ray_cast(DarkstarStdLib.make_vector(_s(a, 0)), DarkstarStdLib.make_vector(_s(a, 1))))
	_on(["initcontainerradiussearch"], _radius_search)
	_on(["containersearchnext"], func(_n, _a): return _search.pop_front() if not _search.is_empty() else 0)
	_on(["addtaggedstring", "gettaggedstring", "detag", "gettag"], func(_n, a): return _s(a, 0))
	_on(["getmapdisplayname"], func(_n, a): return _s(a, 1))


func _register_messages() -> void:
	_on(["messageclient"], func(_n, a): return _message(sim.resolve(_arg(a, 0)), a.slice(1)))
	_on(["messageall"], func(_n, a): return _message(actors.human_client, a))
	_on(["addmessagecallback"], _add_message_callback)
	_on(["messageboxok"], func(_n, a): rt.message_box(_s(a, 0), _s(a, 1), _s(a, 2)); return "")
	_on(["messageboxyesno"], func(_n, a): rt.message_box(_s(a, 0), _s(a, 1), _s(a, 3)); return "")
	_on(["centerprint", "bottomprint"], func(_n, a): rt.output.queue_text(_s(a, 1)); return "")


func _register_audio() -> void:
	_on(["alxcreatesource"], func(_n, a): return sim.create("AudioSource", "", 0, {"profile": _s(a, 0), "filename": _s(a, 1)}))
	_on(["alxplay"], _play)
	_on(["alxgetwavelen"], func(_n, a): return _wave_length(_s(a, 0)))
	_on(["alxstop", "alxsourcef", "alxsourcei", "alxlistenerf"], _no_op)


func _register_game() -> void:
	_on(["aiconnect"], _ai_connect)
	_on(["disconnect"], func(_n, _a): rt.end_session(); return "")
	_on(["isdemo"], _zero)


# ------------------------------------------------------------------ helpers

static func _s(a: Array, i: int) -> String:
	return DarkstarStdLib._s(a, i)


static func _f(a: Array, i: int, default := 0.0) -> float:
	return DarkstarStdLib._f(a, i, default)


## schedule(ms, object, function, args...): the call later (dropped if the object is gone by then).
func _schedule(_n: String, a: Array):
	var object := sim.resolve(_arg(a, 1))
	return rt.schedules.add_call(rt.sim_time + _f(a, 0) / MS_PER_SECOND, object, _s(a, 2), a.slice(3))


## initContainerRadiusSearch(position, radius, mask): the soldiers within the radius, nearest first.
func _radius_search(_n: String, a: Array):
	var c := TribesSimObjects.to_engine(DarkstarStdLib.make_vector(_s(a, 0)))
	var r := _f(a, 1)
	_search = rt.make_players_within(c, r)
	return ""


# ------------------------------------------------------------------ messages

## messageClient(client, tag, text, args...): an objective line of the training HUD, a message callback, or a
## training line for the player (queued for the radio with the voice played in the same step).
func _message(client: int, a: Array):
	var tag := _s(a, 0).to_lower()
	var text := TribesText.make_formatted(_s(a, 1), a.slice(2))
	for fn in _message_callbacks.get(tag, []):
		rt.vm.call_fn(fn, [tag, text] + a.slice(2))
	if rt.apply_message_tag(tag, a.slice(2)):
		return ""
	if client == actors.human_client and text != "":
		rt.output.queue_text(text)
	return ""


func _add_message_callback(_n: String, a: Array):
	var tag := _s(a, 0).to_lower()
	if not _message_callbacks.has(tag):
		_message_callbacks[tag] = []
	(_message_callbacks[tag] as Array).append(_s(a, 1))
	return ""


# ------------------------------------------------------------------ audio

## alxPlay(source): a training voice clip goes to the radio with the step's text; other sounds are presentation.
func _play(_n: String, a: Array):
	var src := sim.get_record(sim.resolve(_arg(a, 0)))
	var file := DarkstarScript.to_str(src.get("fields", {}).get("filename", ""))
	if file.to_lower().begins_with(VOICE_FOLDER):
		rt.output.queue_voice(make_voice_name(file))
	return ""


## "voice/Training/Mission1/T1_01.wav" -> "tribes2:training/mission1/t1_01" (Sfx name of the exported clip).
static func make_voice_name(file: String) -> String:
	return RadioLine.make_voice_name("tribes2", file.to_lower().trim_prefix(VOICE_FOLDER).trim_prefix("="))


## alxGetWaveLen(file): the clip's length in milliseconds.
func _wave_length(file: String):
	if not file.to_lower().begins_with(VOICE_FOLDER):
		return FALLBACK_WAVE_MS
	var s := Sfx.stream(make_voice_name(file))
	return int(s.get_length() * MS_PER_SECOND) if s != null else FALLBACK_WAVE_MS


# ------------------------------------------------------------------ AI

## AIConnect(name, team, skill, offense, voice, pitch): an AI client, spawned at once by the game
## (game.spawnPlayer(client, false) -> pickPlayerSpawn -> createPlayer).
func _ai_connect(_n: String, a: Array):
	var client := actors.make_client(_s(a, 0), int(_f(a, 1)), true)
	var f: Dictionary = sim.objects[client].fields
	f["skill"] = _f(a, 2, 0.5)
	f["offense"] = 1 if DarkstarScript.truthy(_arg(a, 3, 0)) else 0
	f["voice"] = _s(a, 4)
	rt.vm.call_method(rt.game_id, "spawnplayer", [client, 0])
	return client
