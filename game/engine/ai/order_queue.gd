class_name OrderQueue
extends RefCounted
## A unit's or group's list of orders, worked through in turn: the current one runs until the game's rule says it
## completed (or was skipped), then advance() makes the next current. An entry may be null (an order record the
## game could not resolve): the queue then waits on it, as the originals' order lists do (docs/formats/es2.md 10.8).

var orders: Array[AIOrder] = []
var index := 0


func push(order: AIOrder) -> void:
	orders.append(order)


## The order now running, or null when the list is done (or the entry is unresolved).
func current() -> AIOrder:
	return orders[index] if index < orders.size() else null


func is_finished() -> bool:
	return index >= orders.size()


func advance() -> void:
	index += 1


func clear() -> void:
	orders.clear()
	index = 0
