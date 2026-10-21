class_name SiegeRelays
extends RefCounted
## Where the buried relays lie and who stands near one (host). Each relay has two AreaTriggers: a wide one (the hum
## under the ground is heard) and a narrow one (the plate can be dug out). The positions never go to the clients: the
## host tells each player only his own band (Band.NONE / SENSE / REACH) when it changes.

enum Band { NONE, SENSE, REACH }

signal band_changed(peer: int, band: int, relay_id: String)

var points := {}            # relay id -> Vector3
var _reach := {}            # relay id -> AreaTrigger
var _sense := {}
var _in_reach := {}         # relay id -> {peer: true}
var _in_sense := {}
var _bands := {}            # peer -> Band
var _nearest := {}          # peer -> relay id


func apply_add(relay_id: String, at: Vector3, reach_m: float, sense_m: float) -> void:
	points[relay_id] = at
	_in_reach[relay_id] = {}
	_in_sense[relay_id] = {}
	_reach[relay_id] = _make_trigger(AreaShape.make_cylinder(at, reach_m, 12.0), _in_reach[relay_id])
	_sense[relay_id] = _make_trigger(AreaShape.make_cylinder(at, sense_m, 24.0), _in_sense[relay_id])


static func _make_trigger(shape: AreaShape, inside: Dictionary) -> AreaTrigger:
	var t := AreaTrigger.new(shape)
	t.entered.connect(func(peer: Variant) -> void: inside[peer] = true)
	t.left.connect(func(peer: Variant) -> void: inside.erase(peer))
	return t


## One host tick with the players' places (peer -> Vector3).
func apply_scan(positions: Dictionary) -> void:
	for relay_id in points:
		(_reach[relay_id] as AreaTrigger).apply_scan(positions)
		(_sense[relay_id] as AreaTrigger).apply_scan(positions)
	for peer in positions:
		_apply_band(int(peer), _make_band_of(int(peer), positions[peer]))
	for peer in _bands.keys():
		if not positions.has(peer):
			_apply_band(int(peer), {"band": Band.NONE, "relay": ""})


func make_band(peer: int) -> int:
	return int(_bands.get(peer, Band.NONE))


## The relay `peer` stands within reach of ("" none).
func make_reachable_relay(peer: int) -> String:
	return str(_nearest.get(peer, "")) if make_band(peer) == Band.REACH else ""


func _make_band_of(peer: int, at: Vector3) -> Dictionary:
	var best := {"band": Band.NONE, "relay": ""}
	var best_d := INF
	for relay_id in points:
		var band: int = Band.REACH if _in_reach[relay_id].has(peer) else (Band.SENSE if _in_sense[relay_id].has(peer) else Band.NONE)
		var d := Vector2(at.x - points[relay_id].x, at.z - points[relay_id].z).length()
		if band != Band.NONE and d < best_d:
			best_d = d
			best = {"band": band, "relay": str(relay_id)}
	return best


func _apply_band(peer: int, now: Dictionary) -> void:
	_nearest[peer] = now.relay
	if int(_bands.get(peer, Band.NONE)) == int(now.band):
		return
	_bands[peer] = int(now.band)
	band_changed.emit(peer, int(now.band), str(now.relay))
