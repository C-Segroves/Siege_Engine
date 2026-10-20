class_name ExtractionStation
extends Node
## An inventory station in an extraction raid (playtest X2; docs/design/extraction.md section 5; child "Station" of
## the ExtractionDirector). Gear is loot, so a station gives nothing free (TribesStations refills health and energy
## only); it opens the supply panel (StationShopPanel) where the soldier
##   reloads   loads his weapons and kit from the ammunition and gear he carries, at once
##   buys      ammunition for his weapons, his armour's grenades / mines / repair kits and its weapons at shop prices,
##             paid from the credits he carries first and the rest from his account (his profile's money)
## Requests go to the host, which checks the soldier still stands on a working inventory station, the money and the
## room in his inventory. The account part is charged on the owner's machine (each peer keeps its own profile, the
## same trust as the raid kit).

const NODE_NAME := "Station"
const STATIONS_NODE := "Stations"
const INVENTORY_KIND := "inventory"
const OFFER_KINDS := ["ammo", "gear", "weapon"]

var director: ExtractionDirector


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	name = NODE_NAME


# ------------------------------------------------------------------ queries

## True when `soldier` stands on a working inventory station (the map's TribesStations, or a call-in station).
func is_at_station(soldier: Infantry) -> bool:
	if director.callins != null and director.callins.is_at_inventory_station(soldier):
		return true   # a call-in station (CallinDirector)
	var stations := director.battle.get_node_or_null(STATIONS_NODE)
	if stations == null or not stations.has_method("find_station") or soldier == null:
		return false
	var i: int = stations.find_station(soldier)
	return i >= 0 and str(stations.stations[i].kind) == INVENTORY_KIND


## What the station sells `soldier`: [item record, ...], cheapest first (ammunition for his weapons, his armour's
## hand items and the weapons it may carry, of his armour's game).
static func make_offers(soldier: Infantry) -> Array:
	var pack := str(soldier.armor.get("pack", ""))
	var out := []
	for kind in OFFER_KINDS:
		for r in ExtractionShop.make_offers(kind, pack):
			if _is_for(soldier, r):
				out.append(r)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return ExtractionShop.make_buy_price(str(a.id)) < ExtractionShop.make_buy_price(str(b.id)))
	return out


static func _is_for(soldier: Infantry, r: Dictionary) -> bool:
	match str(r.kind):
		"ammo":
			return InfantryCatalog.make_ammo_capacity(soldier.armor_id, str(r.ref)) > 0 and soldier.make_loadout().has(str(r.ref))
		"gear":
			return (soldier.armor.get("hand_items", {}) as Dictionary).has(str(r.ref))
		"weapon":
			return InfantryCatalog.allows_weapon(soldier.armor_id, str(r.ref))
	return false


# ------------------------------------------------------------------ local

## The local player at an inventory station: the supply panel (TribesStations.EXTRACTION_SHOP_METHOD).
func open_for(soldier: Infantry) -> void:
	if director.my_status == ExtractionDirector.STATUS_IN_RAID and not DownedState.is_downed(soldier):
		StationShopPanel.open(director)


func request_reload() -> void:
	_request("_request_reload", [])


## Buys one lot of `item_id`; `account` is the local profile's money (what the host may charge beyond the carried
## credits).
func request_buy(item_id: String) -> void:
	_request("_request_buy", [item_id, ExtractionProfile.load_for(Net.player_name).money])


func _request(method: String, args: Array) -> void:
	if multiplayer.is_server():
		callv("_apply" + method.trim_prefix("_request"), [multiplayer.get_unique_id()] + args)
	else:
		callv("rpc_id", [1, method] + args)


@rpc("any_peer", "reliable")
func _request_reload() -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_reload(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func _request_buy(item_id: String, account: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_buy(multiplayer.get_remote_sender_id(), item_id, account)


# ------------------------------------------------------------------ host

func _soldier_at_station(peer: int) -> Infantry:
	var soldier := director.battle.occupancy.soldier_of(peer)
	if not director.is_in_raid(peer) or soldier == null or DownedState.is_downed(soldier) or not is_at_station(soldier):
		return null
	return soldier


## Host: loads `peer`'s weapons and kit from what he carries.
func _apply_reload(peer: int) -> void:
	var soldier := _soldier_at_station(peer)
	if soldier == null:
		return
	var loaded := ExtractionLoadout.apply_reload(soldier, director.inventories[peer])
	director.send_inventory(peer)
	director.notify(peer, "Reloaded from your pack." if loaded else "Nothing to reload: no spare ammunition carried.")


## Host: `peer` buys one lot of `item_id` (carried credits first, then up to `account` from his profile).
func _apply_buy(peer: int, item_id: String, account: int) -> void:
	var soldier := _soldier_at_station(peer)
	if soldier == null or not make_offers(soldier).any(func(r: Dictionary) -> bool: return str(r.id) == item_id):
		return
	var inv: ExtractionInventory = director.inventories[peer]
	var units := ExtractionShop.make_buy_units(item_id)
	var price := ExtractionShop.make_buy_price(item_id)
	if inv.money + maxi(account, 0) < price:
		director.notify(peer, "Not enough credits (%s)." % ExtractionRules.make_money_text(price))
		return
	if inv.make_room_for(item_id, units) < units:
		director.notify(peer, "No room for %s." % ExtractionItems.make_name(item_id))
		return
	var from_carried := mini(inv.money, price)
	inv.money -= from_carried
	inv.apply_add(item_id, units)
	if price > from_carried:
		director.send_to(peer, self, "_charge_account", [price - from_carried])
	director.apply_equipment(peer)
	ExtractionLoadout.apply_reload(soldier, inv)
	director.send_inventory(peer)
	director.notify(peer, "Bought %s." % ExtractionItems.make_stack_text(item_id, units))


## The owner pays the rest of a station purchase from his account.
@rpc("authority", "reliable", "call_local")
func _charge_account(amount: int) -> void:
	var profile := ExtractionProfile.load_for(Net.player_name)
	profile.money = maxi(profile.money - amount, 0)
	profile.save()
