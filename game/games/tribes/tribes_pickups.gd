class_name TribesPickups
extends Node
## The items lying in a Tribes / Tribes 2 map (maps/<id>/items.json, tools/export_tribes_items.py): weapons,
## ammunition, packs, hand items and repair patches, drawn with their own models (Tribes 2 placed items do not
## rotate: item.cs "don't make placed items rotate"; a mission Item with rotate = true spins).
##   touch     a soldier on foot within the item's pickupRadius takes it when it gives him something
##             (ItemData::onCollision -> Player::pickup; TribesItemGrants)
##   interact  the nearest item within reach (InfantryInteraction offer), which may also swap the weapon in hand or
##             the worn pack for it
##   respawn   a taken item comes back after ITEM_RESPAWN_SECONDS (T1 game.cs / T2 item.cs $ItemRespawnTime)
## Host-authoritative: the host decides every pickup and tells the peers which items are gone (reliable RPC).
## Child "Pickups" of the Battle, for maps of a Tribes pack outside missions (a training mission's items belong to
## its script runtime, which draws them through make_item_model).

const NODE_NAME := "Pickups"
const MAP_ITEMS_FILE := "maps/%s/items.json"
## T1 game.cs $ItemRespawnTime = 30 (s); T2 item.cs $ItemRespawnTime = 30000 (ms).
const ITEM_RESPAWN_SECONDS := 30.0
## Vertical reach of a touch (metres): the soldier's capsule against the item's box.
const TOUCH_HEIGHT := 2.5
## An explicit pickup reaches this much further than a touch.
const INTERACT_EXTRA_REACH := 1.0
## Turn rate of a rotating item (rad/s; Torque Item rotate: one turn in about 3 s).
const ROTATE_RATE := 2.0
const CHECK_SECONDS := 0.1

var battle: Node
var pack := ""
var grants: TribesItemGrants
## id -> {datablock, pos, yaw, count, rotate, node, taken_left}
var items := {}
var _check_left := 0.0


func _init(p_battle: Node, p_pack: String, placed: Array) -> void:
	battle = p_battle
	pack = p_pack
	name = NODE_NAME
	grants = TribesItemGrants.new(pack)
	for i in placed.size():
		var rec: Dictionary = placed[i]
		if grants.record(str(rec.get("datablock", ""))).is_empty() or not grants.is_pickup(str(rec.datablock)):
			continue
		items[i] = {"datablock": str(rec.datablock), "pos": _vec(rec.get("pos", [0, 0, 0])),
			"yaw": deg_to_rad(float(rec.get("yaw", 0.0))), "count": int(rec.get("count", 1)),
			"rotate": bool(rec.get("rotate", false)), "node": null, "taken_left": 0.0}


## The battle's pickups for its map ({} items when the map has none): null outside Tribes maps and in missions.
static func make_for(p_battle: Node, map_id: String) -> TribesPickups:
	var pack := map_id.get_slice(":", 0) if map_id.contains(":") else ""
	if not pack in InfantryCatalog.INFANTRY_PACKS:
		return null
	var j = Assets.load_json(MAP_ITEMS_FILE % map_id.get_slice(":", 1), pack)
	var placed: Array = j.get("items", []) if j is Dictionary else []
	return TribesPickups.new(p_battle, pack, placed) if not placed.is_empty() else null


func _ready() -> void:
	for id in items:
		_build_item(id)
	var interaction := InfantryInteraction.of(battle)
	if interaction:
		interaction.add_provider(make_interact_offer)


## An item's model (a training runtime draws its script items with it too): the item datablock's shape, resting
## on its lowest point once it is in the tree.
static func make_item_model(grant_table: TribesItemGrants, datablock: String) -> Node3D:
	var shape_id := str(grant_table.record(datablock).get("shape", ""))
	if shape_id == "":
		return null
	var model := ShapeInstance.new()
	model.build(Assets.shape(shape_id), 0, Packs.default_palette(shape_id.get_slice(":", 0)))
	var holder := Node3D.new()
	holder.add_child(model)
	holder.ready.connect(func() -> void: model.position.y = -model.lowest_point() * model.scale.y, CONNECT_ONE_SHOT)
	return holder


func _build_item(id: int) -> void:
	var it: Dictionary = items[id]
	var holder := make_item_model(grants, it.datablock)
	if holder == null:
		return
	holder.name = "Item%d" % id
	holder.position = it.pos
	holder.rotation.y = it.yaw
	add_child(holder)
	it.node = holder


func _process(delta: float) -> void:
	for id in items:
		var it: Dictionary = items[id]
		if it.rotate and it.node:
			(it.node as Node3D).rotation.y += ROTATE_RATE * delta


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server():
		return
	_apply_respawns(delta)
	_check_left -= delta
	if _check_left > 0.0:
		return
	_check_left = CHECK_SECONDS
	for v in battle.get_tree().get_nodes_in_group("vehicles"):
		if v is Infantry and (v as Infantry).alive and not (v as Infantry).stowed:
			_apply_touches(v as Infantry)


func _apply_respawns(delta: float) -> void:
	for id in items:
		var it: Dictionary = items[id]
		if float(it.taken_left) > 0.0:
			it.taken_left = float(it.taken_left) - delta
			if float(it.taken_left) <= 0.0:
				_set_taken.rpc(id, false)


func _apply_touches(soldier: Infantry) -> void:
	for id in items:
		if is_available(id) and is_within(soldier, id, 0.0):
			apply_take(soldier, id, false)


## True when item `id` lies in the world.
func is_available(id: int) -> bool:
	return items.has(id) and float(items[id].taken_left) <= 0.0


## True when `soldier` is within item `id`'s pickup radius plus `extra` metres.
func is_within(soldier: Infantry, id: int, extra: float) -> bool:
	var it: Dictionary = items[id]
	var p := soldier.global_position
	var radius := float(grants.record(it.datablock).get("radius", 2.0)) + extra
	return Vector2(p.x - it.pos.x, p.z - it.pos.z).length() <= radius and absf(p.y - it.pos.y) <= TOUCH_HEIGHT


## Host: `soldier` takes item `id` when it gives him something (`swap`: an explicit pickup); true when taken.
func apply_take(soldier: Infantry, id: int, swap: bool) -> bool:
	if not is_available(id) or not grants.apply_take(soldier, str(items[id].datablock), int(items[id].count), swap):
		return false
	_set_taken.rpc(id, true)
	return true


## Interact offer (InfantryInteraction provider): the nearest item within reach that `soldier` would take.
func make_interact_offer(soldier: Infantry) -> Dictionary:
	var best := -1
	var best_d := INF
	for id in items:
		if not is_available(id) or not is_within(soldier, id, INTERACT_EXTRA_REACH):
			continue
		if not grants.can_take(soldier, str(items[id].datablock), true):
			continue
		var d: float = soldier.global_position.distance_to(items[id].pos)
		if d < best_d:
			best_d = d
			best = id
	if best < 0:
		return {}
	var label := str(grants.record(str(items[best].datablock)).get("name", items[best].datablock))
	return {"distance": best_d, "text": "pick up %s" % label, "apply": func() -> void: request_take(best)}


## Asks the host to give the local player's soldier item `id` (an explicit pickup).
func request_take(id: int) -> void:
	if multiplayer.is_server():
		_apply_request(multiplayer.get_unique_id(), id)
	else:
		_request_take.rpc_id(1, id)


@rpc("any_peer", "reliable")
func _request_take(id: int) -> void:
	if multiplayer.is_server():
		_apply_request(multiplayer.get_remote_sender_id(), id)


func _apply_request(peer: int, id: int) -> void:
	var occupancy = battle.get("occupancy")
	var soldier: Infantry = occupancy.soldier_of(peer) if occupancy else null
	if soldier and items.has(id) and is_within(soldier, id, INTERACT_EXTRA_REACH):
		apply_take(soldier, id, true)


@rpc("authority", "reliable", "call_local")
func _set_taken(id: int, taken: bool) -> void:
	if not items.has(id):
		return
	var it: Dictionary = items[id]
	it.taken_left = ITEM_RESPAWN_SECONDS if taken else 0.0
	if it.node:
		(it.node as Node3D).visible = not taken


static func _vec(a: Array) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
