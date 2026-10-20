class_name ClientBaseline
extends RefCounted
## What the server knows one client has received (docs/DEDICATED_SERVER_SCALING.md section 3.2): the baseline the
## next snapshot is a delta against. Every packet tick sent to the client is remembered (`record_sent`); when the
## client acknowledges that tick (`acknowledge`) its groups become `confirmed`. Packets are never chained: each is
## a delta against `confirmed`, so a lost packet only means its groups go out again.
## A client that has not acknowledged anything for FALLBACK_SNAPSHOTS snapshots loses its baseline and gets full
## state again (still at its tier rates), which is also what a client that never acknowledges receives.

const FALLBACK_SNAPSHOTS := 32
## Sent packet ticks kept while waiting for their acknowledgement.
const SENT_RING := 64

## entity id -> {group bit: PackedByteArray} the client has acknowledged.
var confirmed := {}
## entity id -> true: the client may be showing it (sent at least once, forget not yet acknowledged).
var known := {}
var snapshots_since_ack := 0
## Snapshots built for this client (the clock of its tier intervals and interest evaluations; the stream's governor
## may skip a client, so this is not the global snapshot number).
var serves := 0
## The shared-record path (BattleSnapshotStream): per entity the version of each acknowledged group (group bit ->
## version), a signature of them (clients with the same signature get the same delta record) and the pose cell code.
var confirmed_versions := {}
var signatures := {}
var _confirmed_cells := {}
var _last_cells := {}
var _sent_shared := {}                      # tick -> {"entries": {id: SharedRecord}, "forgets": PackedInt32Array}
var _last_sent_cell := {}                   # entity id -> the pose cell bytes of the newest packet sent
var _sent := {}                             # tick -> {"groups": {id: {bit: bytes}}, "forgets": PackedInt32Array}


## Whether the baseline is too old to trust (call once per snapshot before building).
func is_stale() -> bool:
	return snapshots_since_ack > FALLBACK_SNAPSHOTS


## Drops the baseline: the next snapshot carries full state.
func reset_to_full_state() -> void:
	confirmed.clear()
	_sent.clear()
	_last_sent_cell.clear()
	confirmed_versions.clear()
	signatures.clear()
	_confirmed_cells.clear()
	_last_cells.clear()
	_sent_shared.clear()
	snapshots_since_ack = 0


## The groups out of `wanted` (bit -> bytes) the client has not acknowledged yet, restricted to `allowed` bits.
func make_changed_groups(id: int, wanted: Dictionary, allowed: int) -> Dictionary:
	var have: Dictionary = confirmed.get(id, {})
	var changed := {}
	for bit: int in wanted:
		if bit & allowed != 0 and have.get(bit) != wanted[bit]:
			changed[bit] = wanted[bit]
	return changed


## Whether a pose in the cell `cell_bytes` can go without them: the client acknowledged that cell and no packet
## with another one is still in flight (the client decodes against the cell of the newest pose it received).
func can_omit_cell(id: int, cell_bytes: PackedByteArray) -> bool:
	var pose: PackedByteArray = confirmed.get(id, {}).get(SnapshotCodec.GROUP_POSE, PackedByteArray())
	return not pose.is_empty() and pose.slice(0, SnapshotCodec.CELL_BYTES) == cell_bytes \
		and _last_sent_cell.get(id, cell_bytes) == cell_bytes


## Remembers what packet tick `tick` carried: `groups` (id -> {bit: bytes} actually sent) and `forgets`.
func record_sent(tick: int, groups: Dictionary, forgets: PackedInt32Array) -> void:
	for id: int in groups:
		known[id] = true
		if groups[id].has(SnapshotCodec.GROUP_POSE):
			_last_sent_cell[id] = groups[id][SnapshotCodec.GROUP_POSE].slice(0, SnapshotCodec.CELL_BYTES)
	_sent[tick] = {"groups": groups, "forgets": forgets}
	snapshots_since_ack += 1
	_trim_sent_ring()


## The client received every part of snapshot `tick`.
func acknowledge(tick: int) -> void:
	if _sent_shared.has(tick):
		_acknowledge_shared(tick)
		return
	var entry: Dictionary = _sent.get(tick, {})
	if entry.is_empty():
		return
	for id: int in entry.groups:
		var have: Dictionary = confirmed.get(id, {})
		have.merge(entry.groups[id], true)
		confirmed[id] = have
	for id in entry.forgets:
		confirmed.erase(id)
		known.erase(id)
	for sent_tick: int in _sent.keys():
		if sent_tick <= tick:
			_sent.erase(sent_tick)
	snapshots_since_ack = 0


## Forgets an entity that left the battle (the client removes it through the reliable remove message).
func drop_entity(id: int) -> void:
	confirmed.erase(id)
	confirmed_versions.erase(id)
	signatures.erase(id)
	_confirmed_cells.erase(id)
	_last_cells.erase(id)
	known.erase(id)
	_last_sent_cell.erase(id)


func _trim_sent_ring() -> void:
	if _sent.size() > SENT_RING:
		_sent.erase(_sent.keys().min())
	if _sent_shared.size() > SENT_RING:
		_sent_shared.erase(_sent_shared.keys().min())


# ------------------------------------------------------------------ shared records

## A group's weight in a signature (odd, so a version change always moves the sum).
static func make_group_weight(bit: int) -> int:
	return (bit * 2654435761) | 1


## Whether a pose in `cell` can go without its cell bytes: the client acknowledged a pose in that cell and no packet
## with another one is in flight (the same rule as can_omit_cell, on cell codes).
func can_omit_cell_code(id: int, cell: int) -> bool:
	return _confirmed_cells.get(id, -1) == cell and _last_cells.get(id, cell) == cell


## Whether the client has acknowledged anything (either path).
func has_confirmed() -> bool:
	return not confirmed.is_empty() or not confirmed_versions.is_empty()


## Remembers what packet tick `tick` carried: `entries` (id -> SharedRecord, shared with other clients) and `forgets`.
func record_sent_shared(tick: int, entries: Dictionary, forgets: PackedInt32Array) -> void:
	for id: int in entries:
		known[id] = true
		var entry: SharedRecord = entries[id]
		if entry.cell >= 0:
			_last_cells[id] = entry.cell
	_sent_shared[tick] = {"entries": entries, "forgets": forgets}
	snapshots_since_ack += 1
	_trim_sent_ring()


func _acknowledge_shared(tick: int) -> void:
	var sent: Dictionary = _sent_shared[tick]
	var entries: Dictionary = sent.entries
	for id: int in entries:
		var entry: SharedRecord = entries[id]
		var have: Dictionary = confirmed_versions.get(id, {})
		var signature: int = signatures.get(id, 0)
		var versions: Dictionary = entry.versions
		for bit: int in versions:
			signature += (versions[bit] - have.get(bit, 0)) * make_group_weight(bit)
			have[bit] = versions[bit]
		confirmed_versions[id] = have
		signatures[id] = signature
		if entry.cell >= 0:
			_confirmed_cells[id] = entry.cell
	for id in sent.forgets:
		drop_entity(id)
	for sent_tick: int in _sent_shared.keys():
		if sent_tick <= tick:
			_sent_shared.erase(sent_tick)
	snapshots_since_ack = 0


## One entity's delta as it goes to every client with the same confirmed signature: the changed groups' versions, the
## record bytes (with and without the pose cell) and the pose cell code (-1: no pose in it).
class SharedRecord:
	extends RefCounted
	var versions := {}                      # group bit -> version, the groups this record carries
	var cell := -1
	var mask := 0
	var bytes := PackedByteArray()
	var bytes_same_cell := PackedByteArray()
