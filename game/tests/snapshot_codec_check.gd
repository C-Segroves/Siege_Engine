extends Node
## Headless check of SnapshotCodec + ClientBaseline (docs/DEDICATED_SERVER_SCALING.md chunk E): quantization error,
## encode/decode round trip, delta against the acknowledged baseline (an unchanged group costs nothing), the
## same-cell shortcut, packets under the MTU, a client that loses 30% of the packets and acknowledgements still
## converging, and the full-state fallback of a client that never acknowledges.
##   godot --headless --audio-driver Dummy --path game res://tests/snapshot_codec_check.tscn

const ENTITIES := 300
const TICKS := 120
const LOSS := 0.3
const POSITION_TOLERANCE_M := 0.03   # 5 cm height step + 1 cm horizontal rounding
const ANGLE_TOLERANCE := TAU / 65536.0 + 1e-6
const MOVING_SOLDIER_MAX_BYTES := 20
const SPEED_MPS := 8.0

var _fails := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 12345
	_check_round_trip()
	_check_delta_and_budget()
	_check_loss_converges()
	_check_fallback()
	print("snapshot_codec_check: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


static func _make_state(id: int, at: Vector3, yaw: float) -> Array:
	return [id, at, yaw, 0.5, 0.25, 3.5, true, 1750.0, 900.0, 0.6, 480.0, 7, 2, 5, PackedByteArray([1, 2, 3]),
		[true, 2, false, PackedInt32Array([30, 4]), ["frag", "", false, {"frag": 2}]], Vector2(0.5, -1.0)]


func _check_round_trip() -> void:
	var at := Vector3(-1234.567, 87.65, 2999.999)
	var state := _make_state(42, at, 3.0)
	var record := SnapshotCodec.make_record(42, SnapshotCodec.ALL_GROUPS, SnapshotCodec.encode_groups(state))
	var packet := SnapshotCodec.decode_packet(SnapshotCodec.make_packets(9, 30, PackedInt32Array(), [record])[0], {})
	_expect(not packet.is_empty() and packet.tick == 9 and packet.tick_hz == 30, "packet header")
	if packet.is_empty():
		return
	var r: Dictionary = packet.records[0]
	var f: Dictionary = r.fields
	_expect((f[SnapshotCodec.IDX_POS] as Vector3).distance_to(at) < POSITION_TOLERANCE_M, "position within the quantization step")
	_expect(absf(f[SnapshotCodec.IDX_YAW] - 3.0) < ANGLE_TOLERANCE, "yaw within 16 bit")
	_expect(absf(f[SnapshotCodec.IDX_TORSO] - 0.5) < ANGLE_TOLERANCE, "torso within 16 bit")
	_expect(f[SnapshotCodec.IDX_ALIVE] == true and absf(f[SnapshotCodec.IDX_INTEGRITY] - 0.6) < 0.003, "alive bit and health byte")
	_expect(absf(f[SnapshotCodec.IDX_SHIELD_FRONT] - 1750.0) < 1.0 and f[SnapshotCodec.IDX_KILLS] == 7, "resources")
	_expect(f[SnapshotCodec.IDX_TRIGGERS] == 5 and f[SnapshotCodec.IDX_DAMAGE] == PackedByteArray([1, 2, 3]), "triggers and damage block")
	_expect(r.extra.slot == 2 and r.extra.jetting == true and r.extra.rounds == PackedInt32Array([30, 4]), "soldier extra")
	_expect(r.kit is Array and r.kit[3].frag == 2, "kit state")
	_expect((f[SnapshotCodec.IDX_STEER] as Vector2).distance_to(Vector2(0.5, -1.0)) < 0.01, "missile stick")
	_expect(SnapshotCodec.decode_packet(PackedByteArray([1, 2, 3]), {}).is_empty(), "a truncated packet is refused")


func _check_delta_and_budget() -> void:
	var base := ClientBaseline.new()
	var state := _make_state(7, Vector3(100, 5, 100), 1.0)
	var groups := SnapshotCodec.encode_groups(state)
	var first := base.make_changed_groups(7, groups, SnapshotCodec.ALL_GROUPS)
	_expect(first.size() == groups.size(), "no baseline: full state")
	base.record_sent(1, {7: first}, PackedInt32Array())
	base.acknowledge(1)
	_expect(base.make_changed_groups(7, groups, SnapshotCodec.ALL_GROUPS).is_empty(), "unchanged and acknowledged: nothing to send")
	state[SnapshotCodec.IDX_POS] = Vector3(100.5, 5, 100.2)
	var moved := base.make_changed_groups(7, SnapshotCodec.encode_groups(state), SnapshotCodec.ALL_GROUPS)
	_expect(moved.keys() == [SnapshotCodec.GROUP_POSE], "only the pose group changed")
	var cell_bytes: PackedByteArray = moved[SnapshotCodec.GROUP_POSE].slice(0, SnapshotCodec.CELL_BYTES)
	_expect(base.can_omit_cell(7, cell_bytes), "same cell as the acknowledged pose: cell bytes omitted")
	var record := SnapshotCodec.make_record(7, SnapshotCodec.GROUP_POSE | SnapshotCodec.FLAG_SAME_CELL, moved)
	_expect(record.size() <= MOVING_SOLDIER_MAX_BYTES, "a moving soldier costs %d bytes" % record.size())
	var packet := SnapshotCodec.decode_packet(SnapshotCodec.make_packets(2, 30, PackedInt32Array(), [record])[0], {7: Vector2i(0, 0)})
	_expect(not packet.is_empty() and (packet.records[0].fields[SnapshotCodec.IDX_POS] as Vector3).distance_to(Vector3(100.5, 5, 100.2)) < 0.02,
		"same-cell record decodes")


## A server sends deltas to a client that loses 30% of the packets and of its acknowledgements: it still ends on
## the exact (quantized) state, and no packet exceeds the MTU.
func _check_loss_converges() -> void:
	var truth := {}
	for id in ENTITIES:
		truth[id] = Vector3(_rng.randf_range(-900.0, 900.0), _rng.randf_range(0.0, 60.0), _rng.randf_range(-900.0, 900.0))
	var base := ClientBaseline.new()
	var client_pos := {}
	var client_cells := {}
	var parts_seen := {}
	var biggest := 0
	var total_bytes := 0
	for tick in range(1, TICKS + 1):
		var lossy := tick <= TICKS - 10
		for id in ENTITIES:
			if id % 3 != 0:
				truth[id] += Vector3(_rng.randf_range(-1, 1), 0.0, _rng.randf_range(-1, 1)) * SPEED_MPS / 15.0
		var records := []
		var sent := {}
		for id in ENTITIES:
			var groups := SnapshotCodec.encode_groups(_make_state(id, truth[id], 0.0))
			var changed := base.make_changed_groups(id, groups, SnapshotCodec.ALL_GROUPS)
			if changed.is_empty():
				continue
			var mask := 0
			for bit: int in changed:
				mask |= bit
			if changed.has(SnapshotCodec.GROUP_POSE) and base.can_omit_cell(id, changed[SnapshotCodec.GROUP_POSE].slice(0, SnapshotCodec.CELL_BYTES)):
				mask |= SnapshotCodec.FLAG_SAME_CELL
			sent[id] = changed
			records.append(SnapshotCodec.make_record(id, mask, changed))
		var packets := SnapshotCodec.make_packets(tick, 30, PackedInt32Array(), records)
		if not packets.is_empty():
			base.record_sent(tick, sent, PackedInt32Array())
		for packet in packets:
			biggest = maxi(biggest, packet.size())
			total_bytes += packet.size()
			if lossy and _rng.randf() < LOSS:
				continue
			_client_receive(packet, client_pos, client_cells, parts_seen)
		for acked_tick: int in parts_seen.keys():
			var seen: Dictionary = parts_seen[acked_tick]
			if seen.count == seen.parts and (not lossy or _rng.randf() >= LOSS):
				base.acknowledge(acked_tick)
				parts_seen.erase(acked_tick)
	_expect(biggest <= SnapshotCodec.MAX_PAYLOAD_BYTES, "largest packet %d bytes is under the MTU budget" % biggest)
	var worst := 0.0
	for id in ENTITIES:
		worst = maxf(worst, (client_pos.get(id, Vector3.INF) as Vector3).distance_to(truth[id]))
	_expect(worst < POSITION_TOLERANCE_M, "client converged after loss (worst error %.3f m)" % worst)
	print("  lossy stream: %d bytes over %d ticks for %d entities, biggest packet %d" % [total_bytes, TICKS, ENTITIES, biggest])


func _client_receive(packet: PackedByteArray, positions: Dictionary, cells: Dictionary, parts_seen: Dictionary) -> void:
	var decoded := SnapshotCodec.decode_packet(packet, cells)
	if decoded.is_empty():
		_expect(false, "a good packet failed to decode")
		return
	for record: Dictionary in decoded.records:
		cells[record.id] = record.cell
		if record.fields.has(SnapshotCodec.IDX_POS):
			positions[record.id] = record.fields[SnapshotCodec.IDX_POS]
	var seen: Dictionary = parts_seen.get(decoded.tick, {"parts": decoded.parts, "count": 0, "mask": 0})
	seen.mask |= 1 << decoded.part
	seen.count = _count_bits(seen.mask)
	parts_seen[decoded.tick] = seen


static func _count_bits(mask: int) -> int:
	var n := 0
	while mask != 0:
		n += mask & 1
		mask >>= 1
	return n


func _check_fallback() -> void:
	var base := ClientBaseline.new()
	var groups := SnapshotCodec.encode_groups(_make_state(1, Vector3.ZERO, 0.0))
	for tick in ClientBaseline.FALLBACK_SNAPSHOTS + 2:
		base.record_sent(tick, {1: base.make_changed_groups(1, groups, SnapshotCodec.ALL_GROUPS)}, PackedInt32Array())
	_expect(base.is_stale(), "no acknowledgement for %d snapshots: stale" % ClientBaseline.FALLBACK_SNAPSHOTS)
	base.reset_to_full_state()
	_expect(not base.is_stale() and base.make_changed_groups(1, groups, SnapshotCodec.ALL_GROUPS).size() == groups.size(),
		"after the fallback the next snapshot is full state")
	base.record_sent(900, {}, PackedInt32Array([1]))
	base.acknowledge(900)
	_expect(not base.known.has(1), "an acknowledged forget removes the entity from the client's known set")
