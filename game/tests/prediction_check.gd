extends Node3D
## Client-side prediction and server reconciliation (docs/DEDICATED_SERVER_SCALING.md chunk I) without a network: a
## "server" body fed by a ServerPilotLink and a "client" body run by a Prediction stand in one physics world (far apart on
## one floor), and the packets between them go through delay lines with latency, jitter and loss. The real Infantry
## movement (Tribes running, jumping, jetting, skiing) and the real Herc drive run on both sides.
##   godot --headless --audio-driver Dummy --path game res://tests/prediction_check.tscn
## Prints "prediction_check: OK|FAILED (<n> failures)"; exit code 0 / 1.
##
## Scenarios: latency 120 ms with 5% loss and jitter converges with no snap and no visible jerk; a push the client
## did not predict is blended out below the snap distance (no snap); a teleport snaps once; a burst of heavy loss
## ends converged. (Both ends step the same dt here; a 30 Hz server against 60 Hz clients is the dedicated e2e's.)

const FLOOR_SIZE := 900.0
const STEP := 1.0 / 60.0
const ONE_WAY_S := 0.06
const JITTER_S := 0.008
const LOSS := 0.05
const RUN_SECONDS := 9.0
const SETTLE_SECONDS := 2.0
const SERVER_START := Vector3(0.0, 0.3, 0.0)
const CLIENT_START := Vector3(400.0, 0.3, 0.0)
const CONVERGED_M := 0.06
const JERK_M := 0.3
const SEED := 20261018

## Read by Infantry._apply_fell_through: a parent with bounds is not asked for the terrain below.
var bounds := RefCounted.new()

var _failures := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = SEED
	_build_floor()
	await get_tree().process_frame
	if InfantryCatalog.make_default_pack() == "":
		print("prediction_check: no infantry pack installed, soldier scenarios skipped")
	else:
		await _run_soldier_scenarios()
	await _run_herc_scenario()
	_check_wire_formats()
	print("prediction_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(FLOOR_SIZE, 2.0, FLOOR_SIZE)
	shape.shape = box
	shape.position = Vector3(FLOOR_SIZE * 0.25, -1.0, 0.0)
	floor_body.add_child(shape)
	add_child(floor_body)


# ------------------------------------------------------------------ scenarios

func _run_soldier_scenarios() -> void:
	print("soldier, 120 ms round trip, 5% loss, jitter:")
	var base := await _run_rig(_make_soldier, {})
	_expect(base.snaps == 0, "no snap (%d)" % base.snaps)
	_expect(base.max_step_correction <= JERK_M, "no visible jerk (largest correction in one step %.3f m)" % base.max_step_correction)
	_expect(base.gap <= CONVERGED_M, "client and server end together (%.3f m apart)" % base.gap)
	_expect(base.moved > 20.0, "the soldier ran and jetted (%.0f m)" % base.moved)
	_expect(base.input_packets > 300 and base.state_packets > 300, "frames and echoes flowed (%d / %d packets)" % [base.input_packets, base.state_packets])
	print("soldier, a push the client did not predict:")
	var pushed := await _run_rig(_make_soldier, {"push_at": 3.0, "push": Vector3(3.0, 0.0, 0.0)})
	_expect(pushed.corrections >= 1, "the push is noticed (%d corrections, largest error %.2f m)" % [pushed.corrections, pushed.max_error])
	_expect(pushed.snaps == 0, "a small push is blended, not snapped (%d snaps)" % pushed.snaps)
	_expect(pushed.max_step_correction <= JERK_M, "blended without a visible jerk (%.3f m in one step)" % pushed.max_step_correction)
	_expect(pushed.gap <= CONVERGED_M, "converged afterwards (%.3f m apart)" % pushed.gap)
	print("soldier, teleported by the server:")
	var moved := await _run_rig(_make_soldier, {"teleport_at": 5.0, "teleport": Vector3(0.0, 0.0, -25.0)})
	_expect(moved.snaps == 1, "one snap (%d)" % moved.snaps)
	_expect(moved.gap <= CONVERGED_M, "converged afterwards (%.3f m apart)" % moved.gap)
	print("soldier, 70% loss for a second:")
	var lossy := await _run_rig(_make_soldier, {"burst_from": 2.0, "burst_to": 3.0, "burst_loss": 0.7})
	_expect(lossy.gap <= CONVERGED_M, "converged after the burst (%.3f m apart)" % lossy.gap)
	_expect(lossy.max_step_correction <= JERK_M or lossy.snaps > 0, "corrections stay smooth unless snapped")


func _run_herc_scenario() -> void:
	if Packs.vehicle("es1:RAPTOR").is_empty():
		print("prediction_check: no es1:RAPTOR, the Herc scenario is skipped")
		return
	print("Herc (es1:RAPTOR), 120 ms round trip, 5% loss, jitter:")
	var herc := await _run_rig(_make_herc, {})
	_expect(herc.snaps == 0, "no snap (%d)" % herc.snaps)
	_expect(herc.max_step_correction <= JERK_M, "no visible jerk (%.3f m)" % herc.max_step_correction)
	_expect(herc.gap <= CONVERGED_M, "client and server end together (%.3f m apart)" % herc.gap)
	_expect(herc.moved > 15.0, "the Herc drove (%.0f m)" % herc.moved)


func _check_wire_formats() -> void:
	print("wire formats:")
	_expect(Prediction.make_steps_per_frame(60, 60) == 1 and Prediction.make_steps_per_frame(60, 30) == 2
		and Prediction.make_steps_per_frame(60, 20) == 3 and Prediction.make_steps_per_frame(30, 60) == 1,
		"input frames follow the server tick: 60 Hz physics against 60 / 30 / 20 Hz ticks makes 1 / 2 / 3 steps a frame")
	var controls := {"seq": 77, "throttle": 0.5, "turn": -1.0, "torso": 3.0, "pitch": -0.4, "triggers": 5, "target": 12,
		"infantry": [true, false, 2], "missile_steer": Vector2(0.5, -0.25)}
	var packet := InputFrame.make_packet(9, 1234, [controls, controls])
	var back := InputFrame.decode_packet(packet)
	_expect(packet.size() == InputFrame.HEADER_BYTES + 2 * InputFrame.FRAME_BYTES, "two frames in %d bytes" % packet.size())
	_expect(int(back.body) == 9 and int(back.echo) == 1234 and back.frames.size() == 2, "header")
	var f: Dictionary = back.frames[0]
	_expect(int(f.seq) == 77 and absf(float(f.throttle) - 0.5) < 1e-4 and float(f.turn) == -1.0, "seq and analog controls")
	_expect(absf(float(f.torso) - wrapf(3.0, -PI, PI)) < 1e-3 and absf(float(f.pitch) + 0.4) < 1e-3, "aim angles")
	_expect(int(f.triggers) == 5 and int(f.target) == 12 and f.infantry == [true, false, 2], "triggers, target, jet / jump / slot")
	_expect((f.missile_steer as Vector2).distance_to(Vector2(0.5, -0.25)) < 0.01, "missile stick")
	_expect(InputFrame.decode_packet(packet.slice(0, packet.size() - 3)).is_empty(), "a cut packet is refused")
	var queue := InputQueue.new()
	queue.push_frames([{"seq": 3}, {"seq": 4}])
	queue.push_frames([{"seq": 2}, {"seq": 3}, {"seq": 4}, {"seq": 5}])
	_expect(queue.size() == 4, "redundant frames are kept once, a late older one is slotted in (%d)" % queue.size())
	var order := []
	for i in 4:
		order.append(int(queue.take_next().seq))
	_expect(order == [2, 3, 4, 5], "frames are consumed in order %s" % str(order))


# ------------------------------------------------------------------ the rig

## One run of `options` over RUN_SECONDS + SETTLE_SECONDS; returns the figures of the client's Prediction.
func _run_rig(make_body: Callable, options: Dictionary) -> Dictionary:
	var rig := Rig.new(self, make_body, options)
	await rig.run()
	var result := rig.make_result()
	rig.free_bodies()
	return result


func _make_soldier(at: Vector3) -> Herc:
	var s := Infantry.new()
	s.armor_id = InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())
	s.position = at
	add_child(s)
	return s


func _make_herc(at: Vector3) -> Herc:
	var h := Herc.new()
	h.vehicle_id = "es1:RAPTOR"
	h.position = at
	add_child(h)
	return h


## Server body, client body, the delay lines between them and the scripted pilot.
class Rig extends RefCounted:
	var host: Node
	var options: Dictionary
	var server_body: Herc
	var client_body: Herc
	var link: ServerPilotLink
	var prediction: Prediction
	var input_line: Array[Dictionary] = []   # {due, packet}
	var state_line: Array[Dictionary] = []
	var now := 0.0
	var tick := 0
	var input_packets := 0
	var state_packets := 0
	var start_server := Vector3.ZERO
	var rng: RandomNumberGenerator
	var _pushed := false
	var _teleported := false

	func _init(p_host: Node, make_body: Callable, p_options: Dictionary) -> void:
		host = p_host
		options = p_options
		rng = (p_host as Node3D).get("_rng")
		server_body = make_body.call(SERVER_START)
		client_body = make_body.call(CLIENT_START)
		start_server = SERVER_START
		client_body.is_puppet = true
		prediction = Prediction.new(BattleNetSync.make_controls, STEP, 1, Prediction.make_snap_distance(client_body))
		client_body.pilot_link = prediction
		link = ServerPilotLink.new(2, server_body, func(h: Herc, f: Dictionary) -> void: InputFrame.apply_movement(h, f), 0)
		server_body.pilot_link = link

	func run() -> void:
		var steps := int((RUN_SECONDS + SETTLE_SECONDS) / STEP)
		for i in steps:
			await host.get_tree().physics_frame
			_step()

	func _step() -> void:
		now += STEP
		tick += 1
		_deliver()
		_script_pilot(now)
		_apply_events()
		_collect()

	## The scripted pilot: run, strafe, aim around, jump, jet and ski, then let go.
	func _script_pilot(t: float) -> void:
		var h := client_body
		var holding := t < RUN_SECONDS
		h.throttle = 1.0 if holding and t < 8.0 else 0.0
		h.turn = (1.0 if int(t * 2.0) % 2 == 0 else -0.5) if holding and t > 1.0 and t < 3.0 else 0.0
		h.torso_target = 0.6 * sin(t * 0.8) if holding else h.torso_target
		h.pitch_target = 0.1
		if h is Infantry:
			var s := h as Infantry
			s.jump_input = holding and ((t > 2.0 and t < 2.1) or (t > 5.0 and t < 6.0))
			s.jet_input = holding and t > 3.2 and t < 4.6
		else:
			h.throttle = 0.8 if holding and t < 7.0 else 0.0
			h.turn = 0.3 if holding and t > 2.0 and t < 4.0 else 0.0

	func _deliver() -> void:
		while not input_line.is_empty() and input_line[0].due <= now:
			var decoded := InputFrame.decode_packet(input_line.pop_front().packet)
			link.receive_frames(decoded.frames, int(decoded.echo), int(now * 1000.0))
		while not state_line.is_empty() and state_line[0].due <= now:
			var decoded := PilotState.decode_packet(state_line.pop_front().packet)
			var echo: PilotState = decoded.state
			echo.position += CLIENT_START - SERVER_START   # the two bodies stand far apart in one world
			prediction.receive_state(echo)

	func _apply_events() -> void:
		if options.has("push_at") and not _pushed and now >= float(options.push_at):
			_pushed = true
			server_body.velocity += options.push
		if options.has("teleport_at") and not _teleported and now >= float(options.teleport_at):
			_teleported = true
			server_body.global_position += options.teleport

	## Packets that left the bodies this step go onto the lines (or get lost).
	func _collect() -> void:
		if prediction.has_new_frame:
			var frames := prediction.take_outgoing()
			_send(input_line, InputFrame.make_packet(1, 0, frames))
			input_packets += 1
		if link.fresh:
			link.fresh = false
			_send(state_line, link.state.make_packet(1, tick, 60))
			state_packets += 1

	func _send(line: Array[Dictionary], packet: PackedByteArray) -> void:
		var loss := LOSS
		if options.has("burst_from") and now >= float(options.burst_from) and now < float(options.burst_to):
			loss = float(options.burst_loss)
		if rng.randf() < loss:
			return
		var due := now + ONE_WAY_S + rng.randf_range(-JITTER_S, JITTER_S)
		var at := line.size()
		while at > 0 and line[at - 1].due > due:
			at -= 1
		line.insert(at, {"due": due, "packet": packet})

	func make_result() -> Dictionary:
		var gap := server_body.global_position.distance_to(client_body.global_position - (CLIENT_START - SERVER_START))
		return {"snaps": prediction.snaps, "corrections": prediction.corrections, "replays": prediction.replays,
			"max_error": prediction.max_error, "max_step_correction": prediction.max_step_correction, "gap": gap,
			"moved": (server_body.global_position - start_server).length(), "input_packets": input_packets,
			"state_packets": state_packets}

	func free_bodies() -> void:
		server_body.pilot_link = null
		client_body.pilot_link = null
		server_body.queue_free()
		client_body.queue_free()
