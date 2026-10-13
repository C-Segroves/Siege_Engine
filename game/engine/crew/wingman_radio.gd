class_name WingmanRadio
extends Node
## Wingman chatter of the Earthsiege campaigns (host only): watches the player's wingmen and speaks their pilot
## radio lines through Battle.radio (ChatChannels.RADIO, with the voice clip). The lines come from the pack's
## pilot tables (RadioTable "pilot<n>"); the n-th wingman (spawn order) uses table PILOT_TABLES[n % 3].
##
## Which event says which message is an approximation [L]: the originals' trigger code is not traced; the
## mapping follows what the lines mean (docs/formats/audio_video.md "Pilot radio" for Earthsiege,
## docs/formats/es2.md section 11 for Earthsiege 2). The order acknowledgements (messages 10..34, 38..42)
## stay silent: the remake has no wingman order menu.

## Pilot table message numbers (STR extra byte 0), named by what their lines say.
const MSG_ENEMY_SPOTTED := 1
const MSG_KILL := 2
const MSG_NEEDS_HELP := 3
const MSG_DESTROYED := 4
const MSG_NICE_SHOOTING := 5
const MSG_MISSION_WON := 6
const MSG_FRIENDLY_FIRE := 8
const MSG_EJECTING := 9
## A destroyed wingman says one of these (both are last words: hit / bailing out).
const DESTROYED_MESSAGES := [MSG_DESTROYED, MSG_EJECTING]
## The pilot voices both games ship clips for (Earthsiege SIMVOICE P1/P2/P4; Earthsiege 2 PILOT0 has none).
const PILOT_TABLES := [1, 2, 4]
## Unit meta: the wingman's squad slot (spawn order) on this radio; the cockpit's comm windows read it.
const SLOT_META := "radio_slot"
## Seconds a wingman stays quiet after speaking (remake choice, so the radio never floods).
const LINE_COOLDOWN := 6.0
## Seconds between two "enemy spotted" calls of the whole squad (they tend to acquire the same group at once).
const SPOTTED_SQUAD_GAP := 20.0
## Integrity under which a wingman calls for help (once per mission).
const HELP_INTEGRITY := 0.35
## Seconds between checks of the wingmen's targets and of newly spawned vehicles.
const POLL_INTERVAL := 0.5

var battle: Node
var _tables: Array[RadioTable] = []
var _wingmen: Array = []         # [{unit, table, quiet_until, had_target, asked_help}]
var _watched := {}               # instance id of every vehicle whose death is watched -> true
var _clock := 0.0
var _poll_t := 0.0
var _spotted_until := 0.0


## A radio for `p_battle` speaking the pilot tables of `pack`; add it to the tree (host only).
static func create(p_battle: Node, pack: String) -> WingmanRadio:
	var r := WingmanRadio.new()
	r.name = "WingmanRadio"
	r.battle = p_battle
	for n in PILOT_TABLES:
		var t := RadioTable.load_table(pack, "pilot%d" % n)
		if not t.is_empty():
			r._tables.append(t)
	return r


func has_tables() -> bool:
	return not _tables.is_empty()


## Starts listening to `unit` as the next wingman.
func add_wingman(unit: Herc) -> void:
	if unit == null or _tables.is_empty():
		return
	unit.set_meta(SLOT_META, _wingmen.size())
	var w := {"unit": unit, "table": _tables[slot_table_index(_wingmen.size(), _tables.size())], "quiet_until": 0.0,
		"had_target": false, "asked_help": false}
	_wingmen.append(w)
	unit.damaged.connect(_on_wingman_damaged.bind(w))
	unit.destroyed.connect(_on_wingman_destroyed.bind(w))


## The pilot number (PILOT<n>.STR voice, PILOT<n>.DBA face) of the wingman in squad slot `slot` (spawn order):
## the cockpit's comm window and the radio agree on who is speaking.
static func pilot_number(slot: int) -> int:
	return PILOT_TABLES[slot_table_index(slot, PILOT_TABLES.size())]


## The squad slot `unit` speaks from (-1: not one of the radio's wingmen).
static func slot_of(unit: Node) -> int:
	return int(unit.get_meta(SLOT_META, -1)) if unit != null else -1


## `units` with the radio's squad first in slot order, then the others in their given order.
static func make_squad_first(units: Array) -> Array:
	var squad := units.filter(func(u) -> bool: return slot_of(u) >= 0)
	squad.sort_custom(func(a, b) -> bool: return slot_of(a) < slot_of(b))
	return squad + units.filter(func(u) -> bool: return slot_of(u) < 0)


static func slot_table_index(slot: int, table_count: int) -> int:
	return slot % table_count if table_count > 0 else 0


func wingman_count() -> int:
	return _wingmen.size()


## The mission is won: a living wingman calls it.
func announce_mission_won() -> void:
	var w := _pick_living_wingman()
	if not w.is_empty():
		_say(w, MSG_MISSION_WON)


func _physics_process(delta: float) -> void:
	_clock += delta
	_poll_t -= delta
	if _poll_t > 0.0:
		return
	_poll_t = POLL_INTERVAL
	_watch_new_vehicles()
	_check_targets()


func _watch_new_vehicles() -> void:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v is Herc and not _watched.has(v.get_instance_id()):
			_watched[v.get_instance_id()] = true
			v.destroyed.connect(_on_vehicle_destroyed)


## A wingman that acquires a target after having none reports the contact.
func _check_targets() -> void:
	for w in _wingmen:
		var u: Herc = w.unit
		if not is_instance_valid(u) or not u.alive:
			continue
		var has_target := _is_hostile_alive(u, u.target)
		if has_target and not w.had_target and _clock >= _spotted_until and _try_say(w, MSG_ENEMY_SPOTTED):
			_spotted_until = _clock + SPOTTED_SQUAD_GAP
		w.had_target = has_target


func _on_vehicle_destroyed(victim: Herc, killer: Node) -> void:
	if _wingmen.is_empty() or not killer is Herc or _is_squad_side(victim):
		return
	var w := _wingman_of(killer)
	if not w.is_empty():
		_try_say(w, MSG_KILL)
	elif _is_human_squad_member(killer):
		var other := _pick_living_wingman()
		if not other.is_empty():
			_try_say(other, MSG_NICE_SHOOTING)


func _on_wingman_damaged(unit: Herc, attacker: Node, w: Dictionary) -> void:
	if not unit.alive:
		return
	if attacker is Herc and _is_human_squad_member(attacker):
		_try_say(w, MSG_FRIENDLY_FIRE)
	elif unit.integrity < HELP_INTEGRITY and not w.asked_help and _try_say(w, MSG_NEEDS_HELP):
		w.asked_help = true


func _on_wingman_destroyed(_unit: Herc, _killer: Node, w: Dictionary) -> void:
	_say(w, DESTROYED_MESSAGES[randi() % DESTROYED_MESSAGES.size()])


## Speaks `message` unless the wingman spoke less than LINE_COOLDOWN ago; true when it was said.
func _try_say(w: Dictionary, message: int) -> bool:
	if _clock < float(w.quiet_until):
		return false
	_say(w, message)
	return true


func _say(w: Dictionary, message: int) -> void:
	var line: Dictionary = (w.table as RadioTable).make_random_line(message)
	if line.is_empty() or not is_instance_valid(w.unit):
		return
	w.quiet_until = _clock + LINE_COOLDOWN
	battle.radio(str(w.unit.display_name), str(line.text), str(line.voice))


func _wingman_of(unit: Node) -> Dictionary:
	for w in _wingmen:
		if w.unit == unit:
			return w
	return {}


func _pick_living_wingman() -> Dictionary:
	var living := _wingmen.filter(func(w): return is_instance_valid(w.unit) and w.unit.alive)
	return living[randi() % living.size()] if not living.is_empty() else {}


## The wingmen's side (the team of the first wingman).
func _squad_team() -> int:
	return int(_wingmen[0].unit.team) if not _wingmen.is_empty() and is_instance_valid(_wingmen[0].unit) else 0


func _is_squad_side(v: Node) -> bool:
	return int(v.team) == _squad_team()


## A human player on the wingmen's side (the mission AI marks its units with the "ai" meta).
func _is_human_squad_member(v: Node) -> bool:
	return _is_squad_side(v) and not v.has_meta("ai")


func _is_hostile_alive(me: Herc, t: Node) -> bool:
	return t != null and is_instance_valid(t) and t is Herc and t.alive and int(t.team) != int(me.team)
