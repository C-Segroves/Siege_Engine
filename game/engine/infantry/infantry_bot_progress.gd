class_name InfantryBotProgress
extends RefCounted
## Whether an AI soldier (InfantryBot) gets any nearer to the goal it walks to. The bot has no path finding: a
## station behind a wall or a vehicle on a ledge it cannot jet onto would hold it in place for the rest of the
## match. A goal it got no nearer to for GIVE_UP_SECONDS is unreachable for UNREACHABLE_MS; the bot then
## chooses another (remake rule; the Tribes bots walk AI graphs the remake does not load).

const GIVE_UP_SECONDS := 8.0
## Metres nearer that count as progress.
const GIVE_UP_PROGRESS := 3.0
const UNREACHABLE_MS := 30000

var _key := ""
var _best := INF
var _since := 0.0
var _unreachable := {}        # goal key -> ticks msec until which it is given up


## Records the bot's `distance` to goal `key` after `delta` seconds; gives the goal up when it got no nearer.
func apply_sample(key: String, distance: float, delta: float) -> void:
	if key != _key:
		_key = key
		_best = distance
		_since = 0.0
		return
	if distance < _best - GIVE_UP_PROGRESS:
		_best = distance
		_since = 0.0
		return
	_since += delta
	if _since >= GIVE_UP_SECONDS:
		_unreachable[key] = Time.get_ticks_msec() + UNREACHABLE_MS
		_key = ""


## True while goal `key` is given up.
func is_unreachable(key: String) -> bool:
	return Time.get_ticks_msec() < int(_unreachable.get(key, 0))


static func make_station_key(index: int) -> String:
	return "station:%d" % index


static func make_repair_key(obj: Node) -> String:
	return "repair:%d" % obj.get_instance_id()


static func make_vehicle_key(vehicle: Herc) -> String:
	return "vehicle:%d" % vehicle.net_id
