class_name SSScriptEvents
extends RefCounted
## Engine -> script callbacks of a Starsiege mission (host): the start sequence (onMissionPreLoad,
## onMissionLoad, player::onAdd, vehicle::onAdd, onMissionStart, onSPClientInit), and the object events
## <script>::<kind>::<event> (falling back to <kind>::<event>) raised by unit and structure signals:
## vehicle / structure / turret onAttacked (at most every ATTACK_CB_INTERVAL s per object) and onDestroyed.

## Minimum seconds between two onAttacked callbacks of the same object.
const ATTACK_CB_INTERVAL := 2.0

var rt: StarsiegeMissionRuntime
var _attack_cb_t := {}     # obj id -> time of last onAttacked callback


func _init(runtime: StarsiegeMissionRuntime) -> void:
	rt = runtime


## Script start sequence: load, player add, vehicle add, mission start, single-player client init
## (HA2/CA2 read $playerId, set by vehicle::onAdd, inside onMissionStart/onSPClientInit).
func raise_start_callbacks() -> void:
	call_if_defined("onmissionpreload", [])
	call_if_defined("onmissionload", [])
	for p in rt.tree.player_objs:
		call_if_defined("player::onadd", [p])
	for id in rt.tree.objects:
		if rt.tree.is_vehicle(id) and rt.tree.objects[id].node != null:
			call_if_defined("vehicle::onadd", [id])
	call_if_defined("onmissionstart", [])
	call_if_defined("onspclientinit", [])


## Calls `<script>::<kind>::<event>` if the mission defines it, else `<kind>::<event>`.
func raise_object_callback(id: int, kind: String, event: String, args: Array) -> void:
	var vm := rt.vm
	if vm == null:
		return
	var o: Dictionary = rt.tree.get_record(id)
	var script_name := String(o.get("script", ""))
	rt.log_debug("callback %s %s.%s %s" % [o.get("path", id), kind, event, args])
	var specific := "%s::%s::%s" % [script_name, kind, event]
	if script_name != "" and vm.has_function(specific):
		vm.call_script(specific, args)
	elif vm.has_function("%s::%s" % [kind, event]):
		vm.call_script("%s::%s" % [kind, event], args)
	rt.flush_errors()


func call_if_defined(name: String, args: Array) -> void:
	if rt.vm and rt.vm.has_function(name):
		rt.vm.call_script(name, args)


func watch_unit(h: Herc, id: int) -> void:
	h.damaged.connect(_on_unit_damaged.bind(id))
	h.destroyed.connect(_on_unit_destroyed.bind(id))


func watch_structure(st: SSStructure, id: int) -> void:
	st.destroyed.connect(_on_structure_destroyed.bind(id))
	st.attacked.connect(_on_structure_attacked.bind(id))


func _attack_callback_due(id: int) -> bool:
	var last: float = _attack_cb_t.get(id, -100.0)
	if rt.sim_time - last < ATTACK_CB_INTERVAL:
		return false
	_attack_cb_t[id] = rt.sim_time
	return true


func _on_unit_damaged(_h: Herc, attacker: Node, id: int) -> void:
	if not rt.multiplayer.is_server() or attacker == null:
		return   # scripted damage (damageArea/damageObject) is not an attack
	if _attack_callback_due(id):
		raise_object_callback(id, "vehicle", "onattacked", [id, SSObjectTree.id_of_node(attacker)])


func _on_unit_destroyed(_h: Herc, killer: Node, id: int) -> void:
	if not rt.multiplayer.is_server():
		return
	rt.tree.objects[id].alive = false
	raise_object_callback(id, "vehicle", "ondestroyed", [id, SSObjectTree.id_of_node(killer)])
	if rt.tree.objects[id].has("player_num"):
		rt.note_player_death()


func _on_structure_attacked(_s: SSStructure, attacker: Node, id: int) -> void:
	if attacker == null:
		return
	if _attack_callback_due(id):
		raise_object_callback(id, rt.tree.callback_kind(id), "onattacked", [id, SSObjectTree.id_of_node(attacker)])


func _on_structure_destroyed(s: Structure, killer: Node, id: int) -> void:
	rt.tree.objects[id].alive = false
	if not rt.multiplayer.is_server():
		return
	raise_object_callback(id, rt.tree.callback_kind(id), "ondestroyed", [id, SSObjectTree.id_of_node(killer)])
	var i := rt.structures.find(s)
	if i >= 0:
		rt.battle.fx("structure_down", [i], true)
