extends Node
## Headless check of the shared snapshot records and the overrun governor (docs/DEDICATED_SERVER_SCALING.md section 8.5):
## clients that acknowledged the same group versions have the same signature (so they share one delta record), a
## different history that ends in the same versions converges to the same signature, the cell shortcut works on cell
## codes, a forget drops the signature, and the governor sheds load in steps and gives it back after a hold-down.
##   godot --headless --audio-driver Dummy --path game res://tests/snapshot_share_check.tscn

var _fails := 0


func _ready() -> void:
	_check_signatures()
	_check_cell_codes()
	_check_governor()
	print("snapshot_share_check: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


static func _make_entry(versions: Dictionary, cell := -1) -> ClientBaseline.SharedRecord:
	var entry := ClientBaseline.SharedRecord.new()
	entry.versions = versions
	entry.cell = cell
	entry.mask = 1
	return entry


func _check_signatures() -> void:
	var pose := SnapshotCodec.GROUP_POSE
	var status := SnapshotCodec.GROUP_STATUS
	var a := ClientBaseline.new()
	var b := ClientBaseline.new()
	var c := ClientBaseline.new()
	# a and b acknowledge the same two snapshots; c loses the first one and gets the pose again in the second
	a.record_sent_shared(1, {7: _make_entry({pose: 1, status: 2})}, PackedInt32Array())
	b.record_sent_shared(1, {7: _make_entry({pose: 1, status: 2})}, PackedInt32Array())
	c.record_sent_shared(1, {7: _make_entry({pose: 1, status: 2})}, PackedInt32Array())
	a.record_sent_shared(2, {7: _make_entry({pose: 3})}, PackedInt32Array())
	b.record_sent_shared(2, {7: _make_entry({pose: 3})}, PackedInt32Array())
	c.record_sent_shared(2, {7: _make_entry({pose: 3, status: 2})}, PackedInt32Array())
	a.acknowledge(1)
	b.acknowledge(1)
	_expect(a.signatures[7] == b.signatures[7], "same acknowledged versions: same signature")
	a.acknowledge(2)
	b.acknowledge(2)
	c.acknowledge(2)
	_expect(a.signatures[7] == b.signatures[7] and a.confirmed_versions[7] == {pose: 3, status: 2}, "after both: pose 3, status 2")
	_expect(c.signatures[7] == a.signatures[7], "a client that missed an acknowledgement converges to the same signature")
	_expect(a.has_confirmed() and not ClientBaseline.new().has_confirmed(), "has_confirmed")
	a.record_sent_shared(3, {}, PackedInt32Array([7]))
	a.acknowledge(3)
	_expect(not a.signatures.has(7) and not a.known.has(7), "an acknowledged forget drops the signature and the entity")
	a.reset_to_full_state()
	_expect(a.signatures.is_empty() and a.confirmed_versions.is_empty(), "the full state fallback clears the shared state")


func _check_cell_codes() -> void:
	var base := ClientBaseline.new()
	var cell_a := 100
	var cell_b := 200
	_expect(not base.can_omit_cell_code(1, cell_a), "no acknowledged pose: the cell goes with it")
	base.record_sent_shared(1, {1: _make_entry({SnapshotCodec.GROUP_POSE: 1}, cell_a)}, PackedInt32Array())
	_expect(not base.can_omit_cell_code(1, cell_a), "sent but not acknowledged: the cell goes with it")
	base.acknowledge(1)
	_expect(base.can_omit_cell_code(1, cell_a), "acknowledged cell: omitted")
	_expect(not base.can_omit_cell_code(1, cell_b), "another cell: sent")
	base.record_sent_shared(2, {1: _make_entry({SnapshotCodec.GROUP_POSE: 2}, cell_b)}, PackedInt32Array())
	_expect(not base.can_omit_cell_code(1, cell_a), "a packet with another cell in flight: the cell goes with it")


func _check_governor() -> void:
	var g := SnapshotGovernor.new()
	g.enabled = true
	for i in 100:
		g.observe(5.0, 33.3, 64)
	_expect(g.level == 0 and g.make_far_factor() == 1 and g.serves(3, 10), "a calm server sheds nothing")
	for i in 400:
		g.observe(60.0, 33.3, 64)
	_expect(g.level == SnapshotGovernor.MAX_LEVEL, "an overrun climbs to the top level")
	_expect(g.make_far_factor() == 3 and g.make_skip_every() == 3, "FAR slowed, clients served every 3rd snapshot")
	var served := 0
	for index in 12:
		served += 1 if g.serves(index, 5) else 0
	_expect(served == 4, "every 3rd client in turn (%d of 12)" % served)
	var seen := {}
	for snapshot in 3:
		for index in 12:
			if g.serves(index, snapshot):
				seen[index] = true
	_expect(seen.size() == 12, "over 3 snapshots every client is served once")
	for i in SnapshotGovernor.FIRST_HOLD - 20:
		g.observe(5.0, 33.3, 64)
	_expect(g.level == SnapshotGovernor.MAX_LEVEL - 1, "after the hold-down the level comes back one step (level %d)" % g.level)
	g.observe(60.0, 33.3, 4)
	_expect(g.level == 0, "fewer clients than the minimum: nothing to shed")
	var off := SnapshotGovernor.new()
	for i in 100:
		off.observe(100.0, 33.3, 64)
	_expect(off.level == 0, "disabled: no level")
