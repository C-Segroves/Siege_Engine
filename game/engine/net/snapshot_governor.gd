class_name SnapshotGovernor
extends RefCounted
## Keeps the snapshot work inside the server's tick budget (docs/DEDICATED_SERVER_SCALING.md section 8.5). It watches the
## cost of the server frame as a share of the tick budget and, when the server is overrun, sheds snapshot work in steps:
## first the FAR tier is sent less often (a blip needs the least), then clients are served round-robin every 2nd and
## every 3rd snapshot (the client interpolates over the longer gap: each unit's update carries the time it covers, and
## packets are deltas against what the client acknowledged, so a skipped snapshot loses nothing). The level comes back
## down after a hold-down that doubles each time the server overran again straight after a step down.

const MAX_LEVEL := 4
## Per level: the factor on the FAR tier's send interval and the "serve every n-th snapshot" of each client.
const FAR_FACTOR: Array[int] = [1, 2, 3, 3, 3]
const SKIP_EVERY: Array[int] = [1, 1, 1, 2, 3]
const SMOOTHING := 0.25
const FIRST_HOLD := 96
const MAX_HOLD := 1536
const RAISE_GAP := 6

var enabled := false
## Load = the smoothed frame cost / the tick budget: above `raise_load` the level goes up, below `lower_load` it may come down.
var raise_load := 0.85
var lower_load := 0.6
## Fewer clients than this: nothing to shed.
var min_clients := 8
var level := 0
var load_share := 0.0

var _hold := FIRST_HOLD
var _since_change := 0
var _lowered_recently := false


## Feeds one snapshot's observation: the cost of the last frame in ms and the tick budget in ms.
func observe(frame_ms: float, budget_ms: float, clients: int) -> void:
	if not enabled or clients < min_clients:
		_reset_level()
		return
	load_share = lerpf(load_share, frame_ms / maxf(budget_ms, 0.001), SMOOTHING)
	_since_change += 1
	if load_share > raise_load and level < MAX_LEVEL and _since_change >= RAISE_GAP:
		if _lowered_recently:
			_hold = mini(_hold * 2, MAX_HOLD)
		_lowered_recently = false
		level += 1
		_since_change = 0
	elif load_share < lower_load and level > 0 and _since_change >= _hold:
		level -= 1
		_since_change = 0
		_lowered_recently = true
	elif _lowered_recently and _since_change > _hold:
		_lowered_recently = false
		_hold = maxi(_hold / 2, FIRST_HOLD)


func make_far_factor() -> int:
	return FAR_FACTOR[level]


## Snapshots between two servings of one client.
func make_skip_every() -> int:
	return SKIP_EVERY[level]


## Whether client number `index` is served at snapshot `snapshot_no` (round-robin over the clients).
func serves(index: int, snapshot_no: int) -> bool:
	var every := SKIP_EVERY[level]
	return every <= 1 or (snapshot_no + index) % every == 0


func _reset_level() -> void:
	level = 0
	load_share = 0.0
	_since_change = 0
