class_name BattleSnapshotStream
extends RefCounted
## The server half of the packed snapshot path (docs/DEDICATED_SERVER_SCALING.md chunk E): per client, the
## entities its InterestGrid marks relevant, at the send interval of each one's tier, as SnapshotCodec deltas
## against the last snapshot that client acknowledged. Entities that left a client's interest are announced as
## forgotten until the client acknowledges that. With the grid disabled (a LAN host) every client sees everything
## at the NEAR rate and the same code runs.
##
## The transport is injected (`send_packet(peer, bytes)`) so a test can capture the packets; BattleNetSync wires
## the unreliable RPC. A snapshot number counts the sent snapshots; tier intervals are in snapshots.

signal snapshot_sent(peer: int, tick: int)

## An interest evaluation per client every this many snapshots, staggered over clients (visibility at 4 Hz).
const EVALUATE_EVERY := 4
const REFERENCE_SNAPSHOT_HZ := 15.0
const PURGE_EVERY := 64
## From this many clients on, the packets are built on the worker threads.
const THREAD_MIN_CLIENTS := 6
const NEAR_GROUPS := SnapshotCodec.ALL_GROUPS
const MID_GROUPS := SnapshotCodec.ALL_GROUPS & ~(SnapshotCodec.GROUP_RESOURCES | SnapshotCodec.GROUP_KIT | SnapshotCodec.GROUP_STEER)
const FAR_GROUPS := SnapshotCodec.GROUP_POSE | SnapshotCodec.GROUP_STATUS

var battle: Battle
var grid := InterestGrid.new()
var probes: InterestProbes
var send_packet := Callable()
## Build the clients' packets on worker threads (off: one after the other on the main thread).
var use_threads := true
## Counters for the benchmark and tests.
var packets_sent := 0
var records_sent := 0
var full_state_resets := 0
## Sheds snapshot work when the server frame overruns its tick budget (off unless the owner enables it).
var governor := SnapshotGovernor.new()
## The cost of the last server frame in ms (replaceable in tests).
var frame_cost_ms := make_frame_cost_ms
var tick_budget_ms := 33.3
## Clients served by the last snapshot (the rest were skipped by the governor).
var clients_served := 0
## Delta records built / reused from another client with the same acknowledged state (the sharing's hit rate).
var shared_built := 0
## The cost of each send_snapshot in ms, when `keep_costs` is on (the benchmark's attribution of the tick).
var keep_costs := false
var costs_ms := PackedFloat32Array()
var phase_ms := {}
var shared_reused := 0

var _baselines := {}                        # peer -> ClientBaseline
var _interest := {}                         # peer -> [own entity id, team] the grid was told
var _units_by_peer := {}                    # peer -> the unit it controls (rebuilt every snapshot)
var _states := {}                           # entity id -> {groups: {bit: bytes}, versions: {bit: int}, cell: int, asleep: bool}
var _shared := {}                           # entity id -> {signature * 4 + tier: SharedRecord} built this snapshot
var _version_counter := 0
var _no_versions := {}
var _snapshot_no := 0
var _last_tick := -1
var _snapshot_hz := REFERENCE_SNAPSHOT_HZ
var _now_ms := 0


func _init(p_battle: Battle, interest_enabled: bool) -> void:
	battle = p_battle
	grid.enabled = interest_enabled
	probes = InterestProbes.new(func(peer: int) -> Node3D: return _units_by_peer.get(peer),
		func(id: int) -> Node3D: return battle.vehicles.get(id), func() -> int: return _now_ms)
	grid.radar_probe = probes.is_on_radar
	grid.radar_batch_probe = probes.make_radar_hits
	grid.occlusion_probe = probes.is_occluded


## The state array of a unit as BattleNetSync snapshots carry it: Herc.snapshot() + damage block + soldier extra +
## missile stick + cloak flag (SnapshotCodec.IDX_*).
static func make_state(h: Herc) -> Array:
	var s := h.snapshot()
	s.append(HercSnapshots.make_damage_block(h))
	var infantry := h as Infantry
	s.append(infantry.make_snapshot_extra() if infantry else null)
	s.append(h.missile_steering.stick)
	s.append(h.cloak.make_flag())   # SnapshotCodec.IDX_CLOAKED
	return s


## Server frame cost so far: the last process and physics-process frames, in ms.
static func make_frame_cost_ms() -> float:
	return (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0


## Builds and sends this snapshot to `peers` (connected client peer ids). `tick` is the ServerClock tick.
func send_snapshot(tick: int, tick_hz: int, now_ms: int, peers: Array) -> void:
	var started := Time.get_ticks_usec()
	_snapshot_no += 1
	_now_ms = now_ms
	if _last_tick >= 0 and tick > _last_tick:
		_snapshot_hz = float(tick_hz) / float(tick - _last_tick)
	_last_tick = tick
	tick_budget_ms = 1000.0 / float(maxi(tick_hz, 1))
	_sync_peers(peers)
	if governor.enabled:
		governor.observe(frame_cost_ms.call(), tick_budget_ms, peers.size())
	_rebuild_units_by_peer()
	var served := _pick_served(peers)
	clients_served = served.size()
	var t1 := Time.get_ticks_usec()
	_encode_units()
	var t2 := Time.get_ticks_usec()
	_refresh_interest(peers, served)
	var t3 := Time.get_ticks_usec()
	var built := _build_for_all(served, tick, tick_hz)
	var t4 := Time.get_ticks_usec()
	for i in served.size():
		_deliver(served[i], tick, built[i])
	if _snapshot_no % PURGE_EVERY == 0:
		probes.purge_expired()
	if keep_costs:
		var done := Time.get_ticks_usec()
		costs_ms.append(float(done - started) / 1000.0)
		for pair in [["encode", t2 - t1], ["interest", t3 - t2], ["build", t4 - t3], ["deliver", done - t4]]:
			phase_ms[pair[0]] = phase_ms.get(pair[0], 0.0) + float(pair[1]) / 1000.0


## The client `peer` received every part of snapshot `tick`.
func acknowledge(peer: int, tick: int) -> void:
	if _baselines.has(peer):
		_baselines[peer].acknowledge(tick)


func make_baseline(peer: int) -> ClientBaseline:
	return _baselines.get(peer)


# ------------------------------------------------------------------ clients and interest

func _sync_peers(peers: Array) -> void:
	for peer in peers:
		if not _baselines.has(peer):
			_baselines[peer] = ClientBaseline.new()
	for peer: int in _baselines.keys():
		if not peers.has(peer):
			_baselines.erase(peer)
			_interest.erase(peer)
			grid.remove_client(peer)
			probes.forget_client(peer)


## The clients this snapshot is built for: all of them, or (the governor on duty) every n-th one in turn.
func _pick_served(peers: Array) -> Array:
	if not governor.enabled or governor.make_skip_every() <= 1:
		return peers
	var served := []
	for i in peers.size():
		if governor.serves(i, _snapshot_no):
			served.append(peers[i])
	return served


## The first live non-AI unit each peer pilots (the one BattleNetSync routes that peer's input to).
func _rebuild_units_by_peer() -> void:
	_units_by_peer.clear()
	for h: Herc in battle.vehicles.values():
		if is_instance_valid(h) and not h.has_meta("ai") and not _units_by_peer.has(h.owner_peer):
			_units_by_peer[h.owner_peer] = h


## Servings between one client's interest evaluations: EVALUATE_EVERY at the 15 Hz the number was chosen for, fewer or
## more at other snapshot rates so the evaluations stay about 4 a second; a client the governor serves every n-th
## snapshot is evaluated every n-th as many servings.
func _make_evaluate_every() -> int:
	var every := roundi(_snapshot_hz * float(EVALUATE_EVERY) / REFERENCE_SNAPSHOT_HZ)
	return maxi(1, ceili(float(every) / float(governor.make_skip_every())))


func _refresh_interest(peers: Array, served: Array) -> void:
	grid.rebuild(battle.entities)
	SensorTowers.begin_cache(battle.get_tree())   # the radar probes of this refresh see the same towers (end_cache below)
	var every := _make_evaluate_every() if grid.enabled else 1
	for peer: int in served:
		var is_new := not grid.has_client(peer)
		_register_with_grid(peer)
		if is_new or (_baselines[peer].serves + peers.find(peer)) % every == 0:   # staggered by position in the peer list
			grid.evaluate_client(peer)
	SensorTowers.end_cache()


func _register_with_grid(peer: int) -> void:
	var unit: Herc = _units_by_peer.get(peer)
	var own := [unit.net_id if unit else InterestGrid.NO_ENTITY, unit.team if unit else InterestGrid.NO_TEAM]
	if not grid.has_client(peer) or _interest.get(peer) != own:
		_interest[peer] = own
		grid.add_client(peer, own[0], own[1])
	grid.apply_target(peer, unit.target.net_id if unit and unit.target is Herc else InterestGrid.NO_ENTITY)


# ------------------------------------------------------------------ encoding, once per entity

## Encodes every unit once. A group whose bytes equal last snapshot's keeps its version number, a changed one gets a new
## one: clients are compared by version (an int) instead of by bytes, and the delta record for "what changed since
## the versions this client acknowledged" is built once and shared (_make_shared_record).
func _encode_units() -> void:
	var previous := _states
	_states = {}
	_shared.clear()
	for id in battle.vehicles:
		if int(id) > SnapshotCodec.MAX_ID:
			continue
		var unit: Herc = battle.vehicles[id]
		var asleep := BotSleep.is_asleep(unit)
		var old: Dictionary = previous.get(id, {})
		if asleep and old.get("asleep", false):   # a sleeping bot's body is switched off: its last encoding still holds (damage wakes it)
			_states[id] = old
			continue
		_states[id] = _make_state(SnapshotCodec.encode_groups(make_state(unit)), old, asleep)


func _make_state(groups: Dictionary, old: Dictionary, asleep: bool) -> Dictionary:
	var old_groups: Dictionary = old.get("groups", _no_versions)
	var old_versions: Dictionary = old.get("versions", _no_versions)
	var versions := {}
	for bit: int in groups:
		if old_groups.get(bit) == groups[bit]:
			versions[bit] = old_versions[bit]
		else:
			_version_counter += 1
			versions[bit] = _version_counter
	var pose: PackedByteArray = groups[SnapshotCodec.GROUP_POSE]
	return {"groups": groups, "versions": versions, "cell": pose.decode_u32(0), "asleep": asleep}


## The entity's encoded groups of this snapshot.
func _make_groups(id: int) -> Dictionary:
	return _states[id].groups if _states.has(id) else {}


# ------------------------------------------------------------------ per client packets

## Every served client's records, forgets and packets. The records are collected on the main thread (they share the
## per-entity delta records, a cache written as it is asked); building the packets from them touches only that client's
## own list, so with enough clients that part is spread over the worker threads. Nothing is sent from here (RPCs stay
## on the main thread: _deliver).
func _build_for_all(peers: Array, tick: int, tick_hz: int) -> Array:
	var built := []
	built.resize(peers.size())
	for i in peers.size():
		built[i] = _collect_for(peers[i])
	var make_packets := func(i: int) -> void:
		var one: Dictionary = built[i]
		one.packets = SnapshotCodec.make_packets(tick, tick_hz, one.forgets, one.records)
		one.records = one.records.size()
	if use_threads and peers.size() >= THREAD_MIN_CLIENTS:
		var task := WorkerThreadPool.add_group_task(make_packets, peers.size(), -1, true, "snapshot packets")
		WorkerThreadPool.wait_for_group_task_completion(task)
	else:
		for i in peers.size():
			make_packets.call(i)
	return built


## One client's {baseline, sent (id -> SharedRecord), forgets, records (the record bytes), reset, packets}.
func _collect_for(peer: int) -> Dictionary:
	var baseline: ClientBaseline = _baselines[peer]
	var reset := baseline.is_stale()
	if reset:
		baseline.reset_to_full_state()
	var sent := {}
	var tiers := grid.get_tier_map(peer)   # walked once: the per-entity lookups of should_send / tier_of cost more than the encoding
	var records := _make_records(peer, baseline, tiers, sent)
	var forgets := _make_forgets(baseline, tiers)
	baseline.serves += 1
	return {"baseline": baseline, "sent": sent, "forgets": forgets, "records": records, "reset": reset, "packets": []}


func _deliver(peer: int, tick: int, built: Dictionary) -> void:
	if built.reset:
		full_state_resets += 1
	var packets: Array = built.packets
	if packets.is_empty():
		return
	built.baseline.record_sent_shared(tick, built.sent, built.forgets)
	for packet in packets:
		send_packet.call(peer, packet)
	packets_sent += packets.size()
	records_sent += built.records
	snapshot_sent.emit(peer, tick)


func _make_records(peer: int, baseline: ClientBaseline, tiers: Dictionary, sent: Dictionary) -> Array:
	var records := []
	var intervals := grid.tier_interval
	var far_interval: int = intervals[InterestGrid.Tier.FAR] * governor.make_far_factor()
	var entered := grid.entered_ids(peer)
	var known := baseline.known
	var signatures := baseline.signatures
	var confirmed := baseline.confirmed_versions
	var serves := baseline.serves
	for id: int in tiers:
		var state: Variant = _states.get(id)
		if state == null:
			continue
		var tier: int = tiers[id]
		if known.has(id):
			var interval: int = far_interval if tier == InterestGrid.Tier.FAR else intervals[tier]
			if interval > 1 and (serves + id) % interval != 0 and not (not entered.is_empty() and entered.has(id)):
				continue
		var shared: Dictionary = _shared.get(id, {})
		var key: int = signatures.get(id, 0) * 4 + tier
		var entry: ClientBaseline.SharedRecord = shared.get(key)
		if entry == null:
			entry = _make_shared_record(id, state, tier, confirmed.get(id, _no_versions))
			shared[key] = entry
			_shared[id] = shared
			shared_built += 1
		else:
			shared_reused += 1
		if entry.mask == 0:
			continue
		sent[id] = entry
		records.append(entry.bytes_same_cell if entry.cell >= 0 and baseline.can_omit_cell_code(id, entry.cell) else entry.bytes)
	return records


## The delta of entity `id` for a client that acknowledged the group versions `have`, at `tier`: the groups the tier
## allows whose version differs, plus the tier group when it differs. Built once for every client with the same `have`.
func _make_shared_record(id: int, state: Dictionary, tier: int, have: Dictionary) -> ClientBaseline.SharedRecord:
	var entry := ClientBaseline.SharedRecord.new()
	var allowed := _make_allowed_groups(tier)
	var versions: Dictionary = state.versions
	var groups: Dictionary = state.groups
	var changed := {}
	var mask := 0
	for bit: int in versions:
		if bit & allowed != 0 and have.get(bit, 0) != versions[bit]:
			changed[bit] = groups[bit]
			entry.versions[bit] = versions[bit]
			mask |= bit
	if have.get(SnapshotCodec.GROUP_TIER, 0) != tier + 1:   # the tier group's version is the tier + 1
		changed[SnapshotCodec.GROUP_TIER] = SnapshotCodec.encode_tier(tier)
		entry.versions[SnapshotCodec.GROUP_TIER] = tier + 1
		mask |= SnapshotCodec.GROUP_TIER
	if mask == 0:
		return entry
	entry.mask = mask
	entry.bytes = SnapshotCodec.make_record(id, mask, changed)
	if changed.has(SnapshotCodec.GROUP_POSE):
		entry.cell = state.cell
		entry.bytes_same_cell = SnapshotCodec.make_record(id, mask | SnapshotCodec.FLAG_SAME_CELL, changed)
	return entry


## Entities this client may still show that it no longer sees (a freed one is dropped silently: the reliable
## remove message already told the client).
func _make_forgets(baseline: ClientBaseline, tiers: Dictionary) -> PackedInt32Array:
	var forgets := PackedInt32Array()
	for id: int in baseline.known.keys():
		if not _states.has(id):
			baseline.drop_entity(id)
		elif not tiers.has(id):
			forgets.append(id)
	return forgets


static func _make_allowed_groups(tier: int) -> int:
	match tier:
		InterestGrid.Tier.NEAR:
			return NEAR_GROUPS
		InterestGrid.Tier.MID:
			return MID_GROUPS
	return FAR_GROUPS
