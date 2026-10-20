extends RefCounted
## Ablation probe for the server bench (`--probe`): where does a dedicated server's frame go? Counts nodes by script,
## reads Godot's time monitors, then switches whole groups of nodes off (physics step, scripts by file) and prints
## the time per frame each one was worth. Prints "PROBE ..." lines.
const SAMPLE_SECONDS := 4.0
const STALE_USEC := 200000
const SPIKE_MS := 70.0
const TOP_SCRIPTS := 40

var _tree: SceneTree
var _root: Node


func _init(p_tree: SceneTree, p_root: Node) -> void:
	_tree = p_tree
	_root = p_root


## Frames above `SPIKE_MS`: which monitor holds the time (script process, physics step + scripts, navigation).
func run_spikes(seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	var last := Time.get_ticks_usec()
	var n := 0
	var worst := 0
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		await _tree.process_frame
		var now := Time.get_ticks_usec()
		var ms := float(now - last) / 1000.0
		last = now
		n += 1
		if ms > SPIKE_MS and worst < 40:
			worst += 1
			print("PROBE spike frame=%.0f ms process=%.1f physics=%.1f nav=%.1f physics_ticks=%d" % [ms,
				Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
				Performance.get_monitor(Performance.TIME_NAVIGATION_PROCESS) * 1000.0, Engine.get_physics_frames()])


## Self time of every scripted node's _physics_process / _process, by script: marker nodes are put in front of each
## scripted node (processing runs in tree order) and the gap between two markers is the node between them.
func run_markers(seconds: float) -> void:
	var targets := []
	var stack := [_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var kids := n.get_children()
		kids.reverse()
		stack.append_array(kids)
		if n != _root and n.get_script() != null and n.get_parent() != null:
			targets.append(n)
	var marks := []
	for n in targets:
		var m := Mark.new(marks.size(), n.get_script().resource_path.get_file())
		n.get_parent().add_child(m)
		n.get_parent().move_child(m, n.get_index())
		marks.append(m)
	var tail := Mark.new(marks.size(), "<tail>")
	tail.process_priority = 10000
	tail.process_physics_priority = 10000
	tail.is_tail = true
	_tree.root.add_child(tail)
	marks.append(tail)
	Mark.stamps_p.resize(marks.size())
	Mark.stamps_f.resize(marks.size())
	Mark.labels = marks.map(func(m) -> String: return m.label)
	Mark.reset()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		await _tree.process_frame
	print("PROBE markers=%d physics_ticks=%d frames=%d" % [marks.size(), Mark.ticks, Mark.frames])
	_print_marks("physics", Mark.sum_p, Mark.ticks)
	_print_marks("process", Mark.sum_f, Mark.frames)
	var keys := Mark.max_p.keys()
	keys.sort_custom(func(a, b) -> bool: return Mark.max_p[a] > Mark.max_p[b])
	for i in mini(8, keys.size()):
		print("PROBE worst-single-tick  %-30s %.1f ms" % [keys[i], Mark.max_p[keys[i]] / 1000.0])
	# the markers stay (freeing them at exit upset the engine's shutdown)


func _print_marks(kind: String, sums: Dictionary, count: int) -> void:
	var keys := sums.keys()
	keys.sort_custom(func(a, b) -> bool: return sums[a] > sums[b])
	var total := 0.0
	for k in keys:
		total += sums[k]
	print("PROBE %s_process total_ms_per_%s=%.2f" % [kind, "tick" if kind == "physics" else "frame", total / 1000.0 / maxi(count, 1)])
	for i in mini(18, keys.size()):
		print("PROBE %s  %-34s %.3f ms" % [kind, keys[i], sums[keys[i]] / 1000.0 / maxi(count, 1)])


class Mark extends Node:
	static var stamps_p := PackedInt64Array()
	static var stamps_f := PackedInt64Array()
	static var labels := []
	static var sum_p := {}
	static var max_p := {}
	static var sum_f := {}
	static var ticks := 0
	static var frames := 0
	var idx := 0
	var label := ""
	var is_tail := false

	static func reset() -> void:
		sum_p.clear()
		sum_f.clear()
		ticks = 0
		frames = 0

	func _init(p_idx: int, p_label: String) -> void:
		idx = p_idx
		label = p_label
		name = "ZMark"
		process_priority = -10000 if p_idx == 0 else 0
		process_physics_priority = process_priority

	func _physics_process(_d: float) -> void:
		stamps_p[idx] = Time.get_ticks_usec()
		if is_tail:
			_fold(stamps_p, sum_p)
			ticks += 1

	func _process(_d: float) -> void:
		stamps_f[idx] = Time.get_ticks_usec()
		if is_tail:
			_fold(stamps_f, sum_f)
			frames += 1

	static func _fold(stamps: PackedInt64Array, sums: Dictionary) -> void:
		for i in stamps.size() - 1:
			var k: String = labels[i]
			if stamps[i + 1] - stamps[i] > STALE_USEC or stamps[i + 1] < stamps[i] or stamps[i] < stamps[0]:
				continue   # a freed node's marker keeps an old stamp
			sums[k] = float(sums.get(k, 0.0)) + float(stamps[i + 1] - stamps[i])
			if sums == sum_p:
				max_p[k] = maxf(float(max_p.get(k, 0.0)), float(stamps[i + 1] - stamps[i]))


## Cost of the radar helpers the bot director calls per unit and viewer (microseconds per call).
func run_radar() -> void:
	var battle: Battle = _root as Battle
	var viewers: Array = battle.bot_sleep._find_human_nodes()
	var units := battle.vehicles.values().filter(func(u) -> bool: return is_instance_valid(u) and not viewers.has(u))
	var v: Node = viewers[0]
	var calls := {
		"is_on_scope": func(u) -> void: RadarContacts.is_on_scope(v, u),
		"is_shown": func(u) -> void: RadarContacts.is_shown(v, u),
		"is_revealed_by": func(u) -> void: SensorTowers.is_revealed_by(v, u),
		"is_turret": func(u) -> void: SensorTowers.is_turret(u),
		"is_com_tower": func(u) -> void: SensorTowers.is_com_tower(u),
		"TribesBase.is_on_radar": func(u) -> void: TribesBase.is_on_radar(v, u),
		"TribesBase.of": func(u) -> void: TribesBase.of(v.get_parent()),
		"battle_of": func(u) -> void: SensorLink.battle_of(v),
		"make_range": func(u) -> void: RadarContacts.make_range(v),
		"can_see": func(u) -> void: RadarMode.can_see(v, u, 100.0, 1200.0),
		"nothing": func(u) -> void: pass,
	}
	for name in calls:
		var t0 := Time.get_ticks_usec()
		var n := 0
		for rep in 5:
			for u in units:
				calls[name].call(u)
				n += 1
		print("PROBE radar %-24s %.1f us/call (%d calls)" % [name, float(Time.get_ticks_usec() - t0) / n, n])


## Where one packed snapshot goes (milliseconds per snapshot, averaged over a few): the stream's phases timed by hand.
func run_stream() -> void:
	var battle: Battle = _root as Battle
	var sync: BattleNetSync = battle.get_node("NetSync")
	var stream: BattleSnapshotStream = sync.stream
	var peers := Array(battle.multiplayer.get_peers())
	var tick: int = sync.clock.tick
	var acc := {}
	var reps := 8
	for r in reps:
		var no: int = stream._snapshot_no + 1
		stream._snapshot_no = no
		_lap(acc, "sync+units_by_peer", func() -> void:
			stream._sync_peers(peers)
			stream._rebuild_units_by_peer())
		_lap(acc, "refresh_interest (staggered)", func() -> void: stream._refresh_interest(peers, peers))
		_lap(acc, "encode all units", func() -> void: stream._encode_units())
		var states := []
		_lap(acc, "  of which make_state()", func() -> void:
			for id in battle.vehicles:
				if int(id) <= SnapshotCodec.MAX_ID and not BotSleep.is_asleep(battle.vehicles[id]):
					states.append(BattleSnapshotStream.make_state(battle.vehicles[id])))
		_lap(acc, "  of which encode_groups()", func() -> void:
			for st in states:
				SnapshotCodec.encode_groups(st))
		var held := {}
		_lap(acc, "build (threads)", func() -> void: held.built = stream._build_for_all(peers, tick + r, 30))
		var built: Array = held.built
		_lap(acc, "deliver: record_sent only", func() -> void:
			for i in peers.size():
				if not built[i].packets.is_empty():
					built[i].baseline.record_sent_shared(tick + r, built[i].sent, built[i].forgets))
		_lap(acc, "deliver: rpc only", func() -> void:
			for i in peers.size():
				for packet in built[i].packets:
					stream.send_packet.call(peers[i], packet))
		_lap(acc, "deliver: emit only", func() -> void:
			for i in peers.size():
				stream.snapshot_sent.emit(peers[i], tick + r))
		var g: InterestGrid = stream.grid
		_lap(acc, "evaluate ALL clients once", func() -> void:
			for peer in peers:
				g.evaluate_client(peer))
		stream.use_threads = false
		_lap(acc, "build (single thread)", func() -> void: stream._build_for_all(peers, tick + r, 30))
		stream.use_threads = true
		var collected := []
		_lap(acc, "build: collect records only", func() -> void:
			for peer in peers:
				collected.append(stream._collect_for(peer)))
		_lap(acc, "build: make_packets only", func() -> void:
			for one in collected:
				SnapshotCodec.make_packets(tick + r, 30, one.forgets, one.records))
		await _tree.process_frame
	var gate := 0
	var changed_n := 0
	var visible := 0
	var peer0: int = peers[0]
	var tiers: Dictionary = stream.grid.get_tier_map(peer0)
	var baseline: ClientBaseline = stream._baselines[peer0]
	var tier_counts := [0, 0, 0]
	for id in tiers:
		visible += 1
		tier_counts[tiers[id]] += 1
		if not baseline.known.has(id) or (baseline.serves + id) % maxi(1, stream.grid.tier_interval[tiers[id]]) == 0:
			gate += 1
			if stream._make_shared_record(id, stream._states[id], tiers[id], baseline.confirmed_versions.get(id, {})).mask != 0:
				changed_n += 1
	print("PROBE peer0 visible=%d tiers(near,mid,far)=%s pass_gate=%d with_changes=%d unacked_sent=%d" % [visible, tier_counts, gate, changed_n, baseline._sent_shared.size()])
	print("PROBE shared records built=%d reused=%d" % [stream.shared_built, stream.shared_reused])
	print("PROBE stream peers=%d entities=%d visible(first)=%d" % [peers.size(), battle.entities.size(), stream.grid.make_visible_ids(peers[0]).size()])
	for k in acc:
		print("PROBE stream %-32s %.2f ms" % [k, float(acc[k]) / reps / 1000.0])


func _lap(acc: Dictionary, key: String, body: Callable) -> void:
	var t := Time.get_ticks_usec()
	body.call()
	acc[key] = acc.get(key, 0) + Time.get_ticks_usec() - t


## Time of BattleNetSync._on_tick as the live server runs it (per tick and per snapshot tick).
func run_ticked(seconds: float) -> void:
	var battle: Battle = _root as Battle
	var sync: BattleNetSync = battle.get_node("NetSync")
	var clock: ServerClock = sync.clock
	var acc := {"all": 0, "snap": 0, "n": 0, "nsnap": 0, "worst": 0}
	clock.ticked.disconnect(sync._on_tick)
	clock.ticked.connect(func(tick: int) -> void:
		var t := Time.get_ticks_usec()
		sync._on_tick(tick)
		var dt := Time.get_ticks_usec() - t
		acc.all += dt
		acc.n += 1
		if tick % sync.snapshot_interval == 0:
			acc.snap += dt
			acc.nsnap += 1
			acc.worst = maxi(acc.worst, dt))
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		await _tree.process_frame
	print("PROBE ticked ticks=%d avg=%.2f ms snapshot_ticks=%d avg_snapshot=%.2f ms worst=%.2f ms" % [acc.n, acc.all / 1000.0 / maxi(acc.n, 1),
		acc.nsnap, acc.snap / 1000.0 / maxi(acc.nsnap, 1), acc.worst / 1000.0])


func run() -> void:
	if OS.get_cmdline_user_args().has("--ticked"):
		await run_ticked(8.0)
		return
	if OS.get_cmdline_user_args().has("--stream"):
		await run_stream()
		return
	if OS.get_cmdline_user_args().has("--radar"):
		await run_radar()
		return
	if OS.get_cmdline_user_args().has("--markers"):
		await run_markers(20.0)
		return
	if OS.get_cmdline_user_args().has("--spikes"):
		await run_spikes(20.0)
		return
	_print_census()
	var base := await _sample()
	print("PROBE base tick_p50_ms=%.2f p95=%.2f ticks_per_s=%.1f" % [base.total, base.p95, base.pps])
	PhysicsServer3D.set_active(false)
	var nophys := await _sample()
	PhysicsServer3D.set_active(true)
	print("PROBE physics_step_off p50=%.2f (saves %.2f)" % [nophys.total, base.total - nophys.total])
	var by_script := _collect_by_script()
	var rows := []
	for path in by_script:
		rows.append([path, by_script[path]])
	rows.sort_custom(func(a, b) -> bool: return a[1].size() > b[1].size())
	for i in mini(TOP_SCRIPTS, rows.size()):
		var nodes: Array = rows[i][1]
		_set_enabled(nodes, false)
		var s := await _sample()
		_set_enabled(nodes, true)
		print("PROBE script=%s nodes=%d off p50=%.2f saves=%.2f p95=%.2f" % [rows[i][0], nodes.size(), s.total, base.total - s.total, s.p95])


func _print_census() -> void:
	var counts := {}
	var total := 0
	var stack := [_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		total += 1
		var key := n.get_class()
		var sc: Script = n.get_script()
		if sc:
			key += " " + sc.resource_path.get_file()
		counts[key] = int(counts.get(key, 0)) + 1
		stack.append_array(n.get_children())
	var keys := counts.keys()
	keys.sort_custom(func(a, b) -> bool: return counts[a] > counts[b])
	print("PROBE nodes=%d physics_active=%d collision_pairs=%d islands=%d" % [total,
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS),
		Performance.get_monitor(Performance.PHYSICS_3D_ISLAND_COUNT)])
	for i in mini(60, keys.size()):
		print("PROBE census %s x%d" % [keys[i], counts[keys[i]]])


func _collect_by_script() -> Dictionary:
	var out := {}
	var stack := [_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		var sc: Script = n.get_script()
		if sc and (n.is_processing() or n.is_physics_processing()):
			var p := sc.resource_path
			if not out.has(p):
				out[p] = []
			out[p].append(n)
	return out


func _set_enabled(nodes: Array, on: bool) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.set_process(on)
			n.set_physics_process(on)


func _sample() -> Dictionary:
	var metrics := ServerMetrics.new(_root)
	metrics.budget_ms = 33.3
	_root.add_child(metrics)
	await _tree.process_frame
	metrics.reset_window()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < SAMPLE_SECONDS * 1000.0:
		await _tree.process_frame
	var r := metrics.make_report()
	metrics.queue_free()
	var p50 := 0.0
	for v in metrics._tick_ms:
		p50 += v
	p50 /= maxi(metrics._tick_ms.size(), 1)   # the mean tick (steadier than the median for an ablation)
	return {"process": 0.0, "physics": 0.0, "total": p50, "p95": float(r.tick_ms_p95), "pps": float(r.ticks) / float(r.seconds)}
