class_name LootTransfer
extends RefCounted
## The host's side of the loot window (LootWindow; ExtractionDirector builds it as `loot`): what a player takes from a
## container, puts back into it, or takes all of. The host decides every move from its own copy of the container, so
## two players at the same bag cannot both take the same item: the second finds it gone. Each answer is a message to
## the asking player ("Took ...", "Too heavy: ...", "Already taken."); the container's new contents go to every peer
## (ExtractionDirector.apply_container_contents) and the inventory to its owner only.
## Credits move as the pseudo item MONEY_ID; ammunition and other stacks merge into the stack already held.

## The credits row of a container or of the kit, in requests.
const MONEY_ID := "@credits"
## A player may stand this much farther than the pickup reach when the request arrives (metres: he moved while it travelled).
const REACH_SLACK_M := 1.0

var director: ExtractionDirector


func _init(p_director: ExtractionDirector) -> void:
	director = p_director


## Host: `peer` takes up to `units` of `item_id` (MONEY_ID: credits) from container `container_id`.
func apply_take(peer: int, container_id: int, item_id: String, units: int) -> void:
	var move := _begin(peer, container_id)
	if move.is_empty():
		return
	var taken := _take_one(move, item_id, units)
	_finish(move, taken, "Took")


## Host: `peer` takes the credits and every item that fits.
func apply_take_all(peer: int, container_id: int) -> void:
	var move := _begin(peer, container_id)
	if move.is_empty():
		return
	var taken := []
	if move.money_left > 0:
		taken.append_array(_take_one(move, MONEY_ID, move.money_left))
	for id in (move.box as ExtractionInventory).stacks.keys():
		taken.append_array(_take_one(move, str(id), (move.box as ExtractionInventory).count(str(id))))
	_finish(move, taken, "Looted")


## Host: `peer` puts up to `units` of `item_id` (MONEY_ID: credits) from his kit back into the container.
func apply_put(peer: int, container_id: int, item_id: String, units: int) -> void:
	var move := _begin(peer, container_id)
	if move.is_empty():
		return
	var put := _put_one(move, item_id, units)
	_finish(move, put, "Put back")


## The working record of a move by `peer` (empty and a message when the container is gone or out of reach)
## {peer, soldier, container, inv, box (the container's stacks as an ExtractionInventory), money_left, refusal, items}.
func _begin(peer: int, container_id: int) -> Dictionary:
	var soldier := director.battle.occupancy.soldier_of(peer)
	if not director.is_in_raid(peer) or soldier == null or not soldier.alive or soldier.stowed or DownedState.is_downed(soldier):
		return {}
	var c := director.containers.get(container_id) as LootContainer
	if c == null or not is_instance_valid(c):
		director.notify(peer, "Already taken.")
		return {}
	if not is_within_reach(soldier.global_position, c.position):
		director.notify(peer, "Too far away.")
		return {}
	var box := ExtractionInventory.new()
	box.apply_merge(c.stacks)
	return {"peer": peer, "soldier": soldier, "container": c, "inv": director.inventories[peer], "box": box,
		"money_left": c.money, "refusal": "", "items": []}


static func is_within_reach(from: Vector3, to: Vector3) -> bool:
	var reach := float(ExtractionRules.data().get("pickup_reach_m", 3.0)) + REACH_SLACK_M
	return Vector2(to.x - from.x, to.z - from.z).length() <= reach and absf(to.y - from.y) <= reach


## Moves up to `units` of `item_id` from the container to the kit; the texts of what moved [String], the reason when none did.
func _take_one(move: Dictionary, item_id: String, units: int) -> Array:
	var inv: ExtractionInventory = move.inv
	var box: ExtractionInventory = move.box
	if item_id == MONEY_ID:
		var amount := clampi(units, 0, int(move.money_left))
		inv.money += amount
		move.money_left = int(move.money_left) - amount
		return [ExtractionRules.make_money_text(amount)] if amount > 0 else _refuse(move, "Already taken.")
	var wanted := mini(units, box.count(item_id))
	if wanted <= 0:
		return _refuse(move, "Already taken.")
	var n := inv.apply_add(item_id, wanted)
	if n <= 0:
		return _refuse(move, "%s: %s" % [ExtractionItems.make_name(item_id), inv.make_refusal_for(item_id)])
	box.apply_take(item_id, n)
	(move.items as Array).append([item_id, n])
	return [ExtractionItems.make_stack_text(item_id, n)]


## Moves up to `units` of `item_id` from the kit into the container.
func _put_one(move: Dictionary, item_id: String, units: int) -> Array:
	var inv: ExtractionInventory = move.inv
	if item_id == MONEY_ID:
		var amount := clampi(units, 0, inv.money)
		inv.money -= amount
		move.money_left = int(move.money_left) + amount
		return [ExtractionRules.make_money_text(amount)] if amount > 0 else _refuse(move, "No credits to put back.")
	if ExtractionItems.kind_of(item_id) == "weapon":
		ExtractionLoadout.apply_unload_weapon(move.soldier, inv, ExtractionItems.ref_of(item_id))
	var n := inv.apply_take(item_id, units)
	if n <= 0:
		return _refuse(move, "You do not carry that.")
	(move.box as ExtractionInventory).apply_add_unchecked(item_id, n)
	return [ExtractionItems.make_stack_text(item_id, n)]


func _refuse(move: Dictionary, reason: String) -> Array:
	move.refusal = reason if str(move.refusal) == "" else "%s  %s" % [move.refusal, reason]
	return []


## Sends the new contents and kit, runs the pickup hooks and tells the player what happened.
func _finish(move: Dictionary, moved: Array, verb: String) -> void:
	var peer: int = move.peer
	var c: LootContainer = move.container
	if not moved.is_empty():
		director.apply_container_contents(c.container_id, (move.box as ExtractionInventory).make_stacks(), int(move.money_left))
		director.apply_equipment(peer)
		ExtractionLoadout.apply_reload(move.soldier, move.inv)
		director.send_inventory(peer)
		_apply_pickup_hooks(peer, c.container_id, move.items)
	var text := "%s: %s" % [verb, ", ".join(PackedStringArray(moved))] if not moved.is_empty() else ""
	if str(move.refusal) != "":
		text += ("   " if text != "" else "") + str(move.refusal)
	director.notify(peer, text if text != "" else "Nothing to move.")


## The Cybrid siege's radio fragments and the faction flag notice what was taken.
func _apply_pickup_hooks(peer: int, container_id: int, taken: Array) -> void:
	if taken.is_empty():
		return
	director.siege.apply_stacks_taken(peer, taken)
	for s in taken:
		if str(s[0]) == RaidTasks.FLAG_ITEM:
			director.callins.points.apply_flag_taken(peer, container_id)
