class_name Unlocks
extends RefCounted
## The permanent rights an operator holds (docs/design/lobby_loadout_economy.md section 2.3). `owned` and `lost` are
## disjoint sets of UnlockId strings. Nothing is ever deleted: the id of a pack that is not installed stays and is only
## hidden; a lost unlock (an extraction death) is bought back for the rebuy price. Free items (FreeUnlocks) are owned
## without being stored.

var owned := {}
var lost := {}


func is_free(id: String) -> bool:
	return FreeUnlocks.is_free(id)


func is_owned(id: String) -> bool:
	return is_free(id) or owned.has(id)


func is_lost(id: String) -> bool:
	return lost.has(id)


## True when the id's pack is installed (an id without a pack is always visible).
func is_visible(id: String) -> bool:
	var pack := UnlockId.pack_of(id)
	return pack == "" or Assets.has_pack(pack)


## The visible bought unlocks of `kind`, in id order.
func make_owned(kind: String) -> Array:
	var out := []
	for id in owned:
		if UnlockId.kind_of(str(id)) == kind and is_visible(str(id)):
			out.append(id)
	out.sort()
	return out


## Bought unlocks whose game is not installed (shown as a footnote only).
func make_hidden_count() -> int:
	return owned.keys().filter(func(id: String) -> bool: return not is_visible(id)).size()


func apply_add(id: String) -> void:
	lost.erase(id)
	if not FreeUnlocks.is_free_everywhere(id):
		owned[id] = true


## An owned unlock is lost (extraction death). Free items cannot be lost.
func apply_lose(id: String) -> void:
	if owned.has(id):
		owned.erase(id)
		lost[id] = true


func apply_recover(id: String) -> void:
	if lost.has(id):
		lost.erase(id)
		owned[id] = true


func make_owned_ids() -> Array:
	var ids := owned.keys()
	ids.sort()
	return ids


func make_lost_ids() -> Array:
	var ids := lost.keys()
	ids.sort()
	return ids


func apply_ids(owned_ids: Array, lost_ids: Array) -> void:
	owned.clear()
	lost.clear()
	for id in owned_ids:
		owned[str(id)] = true
	for id in lost_ids:
		lost[str(id)] = true
		owned.erase(str(id))
