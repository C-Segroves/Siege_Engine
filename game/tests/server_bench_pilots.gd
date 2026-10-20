extends Node
## Scripted human input for tests/server_load_bench: every synthetic human's soldier (or Herc) runs forward,
## weaves, sweeps its aim and pulses its trigger, written straight into the controls the server would otherwise
## receive from that client (BattleNetSync._apply_controls does the same with the decoded RPC).

const WEAVE_RATE := 0.3
const AIM_RATE := 0.2
const FIRE_PERIOD_TICKS := 30
const FIRE_TICKS := 3
const REFRESH_SECONDS := 1.0
## The synthetic humans are raw ENet connections that cannot speak RPC, so their snapshot acknowledgements are
## made here: each sent snapshot is acknowledged after this many seconds (a 100 ms round trip), none are lost.
const ACK_DELAY_SECONDS := 0.1

var battle: Battle
var peers: Array = []
var _time := 0.0
var _refresh_left := 0.0
var _humans: Array = []
var _acks: Array = []   # [due time, peer, tick]


func _init(p_battle: Battle, p_peers: Array) -> void:
	battle = p_battle
	peers = p_peers
	name = "BenchPilots"


## The vehicles and soldiers piloted by the synthetic humans.
func make_humans() -> Array:
	var out := []
	for h in battle.vehicles.values():
		var herc := h as Herc
		if herc != null and is_instance_valid(herc) and peers.has(herc.owner_peer) and not herc.has_meta(InfantryBots.META_AI):
			out.append(herc)
	return out


func _ready() -> void:
	var sync: BattleNetSync = battle.get_node("NetSync")
	sync.snapshot_sent.connect(func(peer: int, tick: int) -> void: _acks.append([_time + ACK_DELAY_SECONDS, peer, tick]))


func _flush_acks(sync: BattleNetSync) -> void:
	while not _acks.is_empty() and _acks[0][0] <= _time:
		var ack: Array = _acks.pop_front()
		sync.acknowledge(ack[1], ack[2])


func _physics_process(delta: float) -> void:
	_time += delta
	_flush_acks(battle.get_node("NetSync"))
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_humans = make_humans()
		_refresh_left = REFRESH_SECONDS
	var pulse := Engine.get_physics_frames() % FIRE_PERIOD_TICKS < FIRE_TICKS
	for i in _humans.size():
		if is_instance_valid(_humans[i]):
			_drive(_humans[i], float(i), pulse and i % 2 == 0)


func _drive(h: Herc, phase: float, fire: bool) -> void:
	h.throttle = 1.0
	h.turn = sin(_time * WEAVE_RATE + phase)
	h.torso_target = sin(_time * AIM_RATE + phase * 2.0)
	HercSnapshots.apply_trigger_bits(h, 1 if fire else 0)
