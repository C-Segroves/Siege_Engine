class_name RepairDirector
extends Node
## The battle's repair work (child "Repair" of the Battle; docs/TRIBES_BASE_EQUIPMENT.md): one mechanic for every game.
##   pack    a soldier whose repair pack is on mends the nearest damaged structure, teammate or vehicle in its beam's
##           reach (RepairWork.find_pack_target) at the pack's rate; repairing a structure of a team not allied to
##           him captures it (BaseCapture); with nothing to mend the pack heals its wearer (InfantryPack);
##   hold    a Herc with no pack holds the `structure_repair` action next to a structure and mends it at a share of
##           its hit points per second (RepairRules "hold": remake values, the originals have no field repair for
##           Hercs); the client asks the host, which does the work and tells every peer whom the beam joins;
##   crew    a faction's guard soldiers (InfantryBot Task.REPAIR) mend their side's objects with META_JOB set;
##   beams   every peer draws one RepairBeam from each repairing unit to what it works on.

const NODE_NAME := "Repair"
const ACTION_HOLD := "structure_repair"

var battle: Node
var _holders := {}              # peer -> true while its Herc holds the repair action (host)
var _hold_beams := {}           # unit -> Structure the hold beam joins (every peer, from the host's message)
var _hold_sent := {}            # unit net id -> structure name last broadcast (host)
var _pack_targets := {}         # unit -> Node3D its pack works on this frame (every peer)
var _beams := {}                # unit -> RepairBeam
var _asked := false             # the local pilot's hold state the host knows


func _init(p_battle: Node) -> void:
	battle = p_battle
	name = NODE_NAME


## The battle's repair director (null when it has none).
static func of(p_battle: Node) -> RepairDirector:
	return p_battle.get_node_or_null(NODE_NAME) as RepairDirector if p_battle else null


func _physics_process(delta: float) -> void:
	_apply_local_hold()
	_apply_pack_targets()
	if multiplayer.is_server():
		_apply_pack_work(delta)
		_apply_hold_work(delta)
	if not ServerProfile.is_collision_only():
		_apply_beams()


func _units() -> Array:
	var vehicles = battle.get("vehicles")
	return (vehicles as Dictionary).values() if vehicles is Dictionary else []


# ------------------------------------------------------------------ pack

func _apply_pack_targets() -> void:
	_pack_targets.clear()
	for h in _units():
		var unit := h as Herc if is_instance_valid(h) else null
		if unit == null:
			continue
		var target: Node3D = null
		if unit.alive and RepairWork.is_pack_on(unit):
			target = RepairWork.find_pack_target(get_tree(), unit as Infantry)
		if target != null:
			_pack_targets[unit] = target
			unit.set_meta(RepairWork.META_TARGET, target)
		elif unit.has_meta(RepairWork.META_TARGET):
			unit.remove_meta(RepairWork.META_TARGET)


func _apply_pack_work(delta: float) -> void:
	for unit in _pack_targets:
		var soldier := unit as Infantry
		var target: Node3D = _pack_targets[unit]
		var amount := RepairWork.make_pack_rate(soldier, target) * delta
		if target is Structure:
			BaseCapture.apply_work(target, soldier.team, amount)
		else:
			RepairWork.apply_unit_repair(target as Herc, amount)


# ------------------------------------------------------------------ hold (a Herc without a pack)

## The local pilot's hold of the repair action goes to the host when it changes.
func _apply_local_hold() -> void:
	var want := false
	var pilot = battle.get("player")
	if pilot is Herc and not pilot is Infantry and pilot.alive and not ChatFocus.open:
		want = Input.is_action_pressed(ACTION_HOLD)
	if want == _asked:
		return
	_asked = want
	if multiplayer.is_server():
		_apply_hold(multiplayer.get_unique_id(), want)
	else:
		_request_hold.rpc_id(1, want)


@rpc("any_peer", "call_remote", "reliable")
func _request_hold(on: bool) -> void:
	if multiplayer.is_server():
		_apply_hold(multiplayer.get_remote_sender_id(), on)


## Host: `peer` starts or stops holding the repair action.
func _apply_hold(peer: int, on: bool) -> void:
	if on:
		_holders[peer] = true
	else:
		_holders.erase(peer)


func _apply_hold_work(delta: float) -> void:
	var now := {}
	for peer in _holders.keys():
		var unit := make_unit_of(peer)
		if unit == null:
			continue
		var rules := RepairRules.hold(str(unit.vehicle_id))
		var s := RepairWork.find_structure(get_tree(), unit.global_position, unit.team, float(rules.get("reach_m", 0.0)))
		if s == null or not bool(rules.get("enabled", false)):
			continue
		now[unit.net_id] = s.name
		BaseCapture.apply_work(s, unit.team, s.max_hp * float(rules.get("hp_share_per_s", 0.0)) * delta)
	if now != _hold_sent:
		_hold_sent = now
		if Net.is_online():
			_apply_hold_beams.rpc(now)
		_apply_hold_beams(now)


## The Herc a peer pilots (not a soldier on foot): the host's own player, else the Herc that peer owns.
func make_unit_of(peer: int) -> Herc:
	if peer == multiplayer.get_unique_id():
		var mine = battle.get("player")
		return mine as Herc if mine is Herc and not mine is Infantry and mine.alive else null
	for h in _units():
		var unit := h as Herc if is_instance_valid(h) else null
		if unit != null and unit.alive and unit.owner_peer == peer and not unit is Infantry:
			return unit
	return null


## Every peer: the beams of the hold repairs, {unit net id: structure name} as the host has them now.
@rpc("authority", "call_remote", "reliable")
func _apply_hold_beams(pairs: Dictionary) -> void:
	_hold_beams.clear()
	var vehicles = battle.get("vehicles")
	for id in pairs:
		var unit = (vehicles as Dictionary).get(int(id)) if vehicles is Dictionary else null
		var s := _find_structure_named(str(pairs[id]))
		if is_instance_valid(unit) and s != null:
			_hold_beams[unit] = s


func _find_structure_named(structure_name: String) -> Structure:
	for node in get_tree().get_nodes_in_group(RepairWork.STRUCTURE_GROUP):
		if node.name == structure_name:
			return node as Structure
	return null


# ------------------------------------------------------------------ beams

func _apply_beams() -> void:
	var live := {}
	for unit in _pack_targets:
		live[unit] = _pack_targets[unit]
	for unit in _hold_beams.keys():
		if is_instance_valid(unit) and is_instance_valid(_hold_beams[unit]):
			live[unit] = _hold_beams[unit]
		else:
			_hold_beams.erase(unit)
	for h in _units():
		var unit := h as Herc if is_instance_valid(h) else null
		var job = unit.get_meta(RepairWork.META_JOB) if unit != null and unit.has_meta(RepairWork.META_JOB) else null
		if job is Structure and is_instance_valid(job) and unit.alive and not (job as Structure).is_fully_repaired():
			live[unit] = job
	for unit in live:
		if not _beams.has(unit):
			_beams[unit] = RepairBeam.make(battle)
		(_beams[unit] as RepairBeam).apply_between(RepairBeam.make_anchor(unit), RepairBeam.make_anchor(live[unit]))
	for unit in _beams.keys():
		if not live.has(unit):
			if is_instance_valid(_beams[unit]):
				(_beams[unit] as Node).queue_free()
			_beams.erase(unit)
