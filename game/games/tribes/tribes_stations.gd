class_name TribesStations
extends Node
## The map's Tribes stations for soldiers (child "Stations" of the Battle; docs/formats/tribes_infantry.md
## section 4). A soldier uses a station of his team (or a neutral one, or any in a free-for-all) by standing on
## it, as the originals activate a station on contact (Station::onCollision):
##   inventory  opens the buy menu (StationMenu): armour, weapons, grenade type and backpack, free; the new kit
##              comes fully loaded (health, energy, ammunition, hand items);
##   ammo       tops up the carried weapons and hand items every RESUPPLY_SECONDS (AmmoStation::onResupply);
##   command    opens the command map (CommandMap: orders to teammates and bots);
##   vehicle    opens the vehicle menu: the chosen vehicle appears empty on the station's pad when the pad
##              is clear (serverCmdBuyVehicle / VehicleStation::onBuyingVechicle).
## Purchases are asked of the host, which checks the soldier is still on the station. The interact action (E,
## pad X; InfantryInteraction) opens the menu again while he stands there.
## A station of the base (TribesBase) works only while it is enabled and powered (Station::onCollision: "Unit is
## not powered"); on maps whose stations carry a base_equipment spec, only real stations count (Tribes 2 ammo
## and repair items lying on racks are pickups), and a Tribes 1 vehicle pad is the pad, not the station.
## In an extraction raid (docs/design/extraction.md) gear is loot: inventory and ammo stations only refill health
## and energy, and vehicle stations are off (vehicles come from bought call-ins).

## A soldier is on a station within this horizontal distance of its origin and height band (metres).
const STATION_REACH := 2.5
const STATION_HEIGHT := 3.5
## AmmoStation::onResupply runs every 0.5 s and adds per weapon: bullets 20, plasma 5, grenades / discs /
## mortar shells 2 (scripts/station.cs); weapons not in the table get 1.
const RESUPPLY_SECONDS := 0.5
const RESUPPLY_ROUNDS := {"CHAINGUN": 20, "PLASMA_GUN": 5, "PLASMA_RIFLE": 5, "GRENADE_LAUNCHER": 2,
	"DISC_LAUNCHER": 2, "SPINFUSOR": 2, "MORTAR": 2}
const DEFAULT_RESUPPLY_ROUNDS := 1
## A vehicle pad serves a vehicle station within this distance; it is clear with no vehicle this close.
const PAD_SEARCH_RADIUS := 80.0
const PAD_CLEAR_RADIUS := 8.0
const STATION_KINDS := ["inventory", "ammo", "vehicle", "command"]
## Base-equipment kinds (base_equipment.json) that act as these stations.
const SPEC_STATION_KINDS := {"inventory": "inventory", "ammo": "ammo", "vehicle": "vehicle", "vehicle_pad": "vehicle",
	"command": "command"}
const MENU_KINDS := ["inventory", "vehicle", "command"]
## ExtractionDirector method that opens the raid's shop at an inventory station (agent F).
const EXTRACTION_SHOP_METHOD := "open_station_shop"

var battle: Battle
## [{kind, team, xf, object, vehicle, lift}] (`vehicle`: the one vehicle a dedicated pad of the map builds, "" for a station that offers them
## all; `lift`: metres above the pad's origin the vehicle appears)
var stations: Array = []
var _resupply_t := 0.0
var _on_station := -1          # index of the station the local soldier stands on (-1: none)
var _menu: StationMenu
var _command_map: CommandMap


func _init(p_battle: Battle, built_stations: Array) -> void:
	battle = p_battle
	name = "Stations"
	var has_specs := built_stations.any(func(s: Dictionary) -> bool: return (s.get("record", {}) as Dictionary).has("spec"))
	var pads_are_stations := not built_stations.any(func(s: Dictionary) -> bool: return _spec_kind(s) == "vehicle")
	for s in built_stations:
		var kind := _station_kind(s, has_specs, pads_are_stations)
		if kind != "":
			var obj = s.get("object")
			stations.append({"kind": kind, "team": int(obj.team) if is_instance_valid(obj) else int(s.get("team", -1)),
				"xf": s.xf, "object": obj, "vehicle": str((s.get("record", {}) as Dictionary).get("vehicle", "")),
				"lift": float((s.get("record", {}) as Dictionary).get("lift_m", 0.0))})


func _ready() -> void:
	var interaction := InfantryInteraction.of(battle)
	if interaction:
		interaction.add_provider(make_offer)
	var base := TribesBase.of(battle)
	if base:
		base.deployed.connect(_add_deployed_station)


## A deployed inventory / ammo station joins the stations (TribesDeployables).
func _add_deployed_station(obj: TribesBaseObject) -> void:
	var kind := str(SPEC_STATION_KINDS.get(obj.kind, ""))
	if kind in ["inventory", "ammo"]:
		stations.append({"kind": kind, "team": obj.team, "xf": obj.global_transform, "object": obj})


## The station role of built station `s` ("" when it is none): its base spec's kind when the map has specs,
## else the map kind.
static func _station_kind(s: Dictionary, has_specs: bool, pads_are_stations: bool) -> String:
	if not has_specs:
		return str(s.get("kind", "")) if str(s.get("kind", "")) in STATION_KINDS else ""
	var kind := _spec_kind(s)
	if kind == "vehicle_pad" and not pads_are_stations:
		return ""
	return str(SPEC_STATION_KINDS.get(kind, ""))


static func _spec_kind(s: Dictionary) -> String:
	var record: Dictionary = s.get("record", {})
	var pack := str(record.get("shape", "")).get_slice(":", 0)
	return str(TribesBase.make_spec(pack, record).get("kind", "")) if record.has("spec") else ""


## Index of the station `soldier` stands on and may use (-1 when none).
func find_station(soldier: Infantry) -> int:
	if soldier == null or not soldier.alive or soldier.stowed:
		return -1
	for i in stations.size():
		var rel: Vector3 = soldier.global_position - (stations[i].xf as Transform3D).origin
		if Vector2(rel.x, rel.z).length() <= STATION_REACH and absf(rel.y) <= STATION_HEIGHT and may_use(soldier, i):
			return i
	return -1


## Team rule of Station::onCollision: the station's team or a neutral station; in a free-for-all any. The
## station must work (enabled, powered); vehicle stations are off in an extraction raid.
func may_use(soldier: Infantry, i: int) -> bool:
	if not TribesBase.is_working(stations[i].get("object")):
		return false
	if stations[i].kind == "vehicle" and is_extraction():
		return false
	var team := int(stations[i].team)
	return team < 0 or team == soldier.team or GameModes.is_free_for_all(battle.config)


func is_extraction() -> bool:
	return ExtractionRules.is_extraction(battle.config)


## InfantryInteraction provider: the inventory or vehicle station the soldier stands on, when its menu is closed.
func make_offer(soldier: Infantry) -> Dictionary:
	var i := find_station(soldier)
	if i < 0 or not (str(stations[i].kind) in MENU_KINDS) or is_instance_valid(_menu) or is_instance_valid(_command_map):
		return {}
	var rel: Vector3 = soldier.global_position - (stations[i].xf as Transform3D).origin
	return {"distance": Vector2(rel.x, rel.z).length(), "text": "use the %s station" % stations[i].kind,
		"apply": func() -> void: _use_station(soldier, i)}


func _physics_process(delta: float) -> void:
	if battle.is_over():
		return
	_watch_local_soldier()
	if multiplayer.is_server():
		_resupply_t -= delta
		if _resupply_t <= 0.0:
			_resupply_t = RESUPPLY_SECONDS
			_resupply_soldiers()


# ------------------------------------------------------------------ local: stepping onto a station

func _watch_local_soldier() -> void:
	var soldier := battle.player as Infantry
	var i := find_station(soldier)
	if i == _on_station:
		return
	_on_station = i
	if i >= 0 and not is_instance_valid(_menu) and not is_instance_valid(_command_map):
		_use_station(soldier, i)


## Steps onto / interacts with station `i`: its menu, or in an extraction raid a refill of health and energy.
func _use_station(soldier: Infantry, i: int) -> void:
	if is_extraction():
		if str(stations[i].kind) == "inventory":
			request_refill()
			_open_extraction_shop(soldier)
		return
	_open_menu(soldier, i)


## The extraction raid's own shop / reload menu (agent F's ExtractionDirector.open_station_shop: credits buy
## gear and reload ammunition from the raid inventory); nothing more when the raid offers none.
func _open_extraction_shop(soldier: Infantry) -> void:
	var raid = battle.get("extraction")
	if raid != null and raid.has_method(EXTRACTION_SHOP_METHOD):
		raid.call(EXTRACTION_SHOP_METHOD, soldier)


func _open_menu(soldier: Infantry, i: int) -> void:
	match str(stations[i].kind):
		"inventory":
			_menu = StationMenu.open_inventory(battle, InfantryCatalog.armors_of(str(soldier.armor.pack)),
				soldier.armor_id, soldier.make_loadout(), soldier.kit)
			_menu.bought.connect(func(c: Dictionary) -> void:
				request_inventory(str(c.armor), c.loadout, {"grenade": c.get("grenade", ""), "pack": c.get("pack", "")}))
		"vehicle":
			_menu = StationMenu.open_vehicles(battle, make_station_vehicles(soldier, i))
			_menu.bought.connect(func(c: Dictionary) -> void: request_vehicle(str(c.vehicle), i))
		"command":
			if CommandOrders.of(battle) and not is_instance_valid(CommandMap.find_open(battle)):
				_command_map = CommandMap.open(battle, soldier)


## The vehicles station `i` sells: a dedicated pad's own vehicle, else its game's vehicles (Tribes vehicle family), in catalog order.
func make_station_vehicles(soldier: Infantry, i := -1) -> Array:
	var own := str(stations[i].get("vehicle", "")) if i >= 0 else ""
	if own != "":
		return [Packs.vehicle(own)] if not Packs.vehicle(own).is_empty() else []
	var pack := str(soldier.armor.get("pack", "tribes"))
	return Packs.vehicles.values().filter(func(v: Dictionary) -> bool:
		return str(v.get("pack", "")) == pack and str(v.get("category", "")) == "vehicle")


# ------------------------------------------------------------------ purchases (host decides)

## Asks the host for `armor_id` with `loadout` and `gear` ({grenade, pack} ids, "" = none).
func request_inventory(armor_id: String, loadout: Array, gear := {}) -> void:
	if multiplayer.is_server():
		apply_inventory(multiplayer.get_unique_id(), armor_id, loadout, gear)
	else:
		_request_inventory.rpc_id(1, armor_id, loadout, gear)


@rpc("any_peer", "reliable")
func _request_inventory(armor_id: String, loadout: Array, gear: Dictionary) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_inventory(multiplayer.get_remote_sender_id(), armor_id, loadout, gear)


## Host: `peer`'s soldier (or bot), standing on an inventory station, changes into `armor_id` with `loadout`,
## the grenade type and the pack of `gear` ({grenade, pack}).
func apply_inventory(peer: int, armor_id: String, loadout: Array, gear := {}) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	var i := find_station(soldier)
	if i < 0 or stations[i].kind != "inventory" or is_extraction() or InfantryCatalog.armor(armor_id).get("pack") != soldier.armor.get("pack"):
		return
	var allowed := loadout.filter(func(w) -> bool: return InfantryCatalog.allows_weapon(armor_id, str(w)))
	var grenade := str(gear.get("grenade", ""))
	var pack_choice := str(gear.get("pack", ""))
	if Net.is_online():
		_apply_kit.rpc(soldier.net_id, armor_id, allowed, grenade, pack_choice)
	else:
		_apply_kit(soldier.net_id, armor_id, allowed, grenade, pack_choice)


@rpc("authority", "reliable", "call_local")
func _apply_kit(net_id: int, armor_id: String, loadout: Array, grenade: String, pack_choice: String) -> void:
	var soldier := battle.vehicles.get(net_id) as Infantry
	if soldier:
		soldier.apply_armor(armor_id, loadout, grenade, pack_choice)
		apply_station_flash(soldier)
		if soldier == battle.player:
			battle.refresh_player_view()


## StationInventory::stationReady: `%player.setCloaked(true); %player.schedule(500, "setCloaked", false)` (scripts/station.cs
## lines 275-276) around the purchase; the flash is the timed cloak (a shot ends it, like any script cloak).
static func apply_station_flash(soldier: Infantry) -> void:
	InfantryPack.apply_cloak_profile(soldier)
	soldier.cloak.apply_forced(soldier.cloak.profile.station_flash_s)


## Seconds a vehicle leaving a pad is cloaked (serverVehicleHud.cs lines 144-148: setCloaked(true), schedule(4800, ...false)).
static func make_pad_cloak_s(soldier: Infantry) -> float:
	return CloakProfile.of(CloakProfile.make_timed_id(soldier)).vehicle_pad_cloak_s


func request_vehicle(vehicle_id: String, station: int) -> void:
	if multiplayer.is_server():
		apply_vehicle_purchase(multiplayer.get_unique_id(), vehicle_id, station)
	else:
		_request_vehicle.rpc_id(1, vehicle_id, station)


@rpc("any_peer", "reliable")
func _request_vehicle(vehicle_id: String, station: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		apply_vehicle_purchase(multiplayer.get_remote_sender_id(), vehicle_id, station)


## Host: a vehicle for `peer`'s team on the clear pad nearest `station`.
func apply_vehicle_purchase(peer: int, vehicle_id: String, station: int) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if find_station(soldier) != station or stations[station].kind != "vehicle" or Packs.vehicle(vehicle_id).is_empty():
		return
	var own := str(stations[station].get("vehicle", ""))
	if own != "" and vehicle_id != own:
		return
	var pad := find_own_pad(station) if own != "" else find_clear_pad((stations[station].xf as Transform3D).origin)
	if pad.size() == 0:
		battle.fx("message", ["Can't create vehicle. The pad is not clear.", 3.0], true)
		return
	var xf: Transform3D = pad[0]
	battle.send_spawn({"net_id": battle.spawner.allocate_id(), "vehicle": vehicle_id, "team": soldier.team,
		"owner": VehicleOccupancy.EMPTY, "xf": xf, "loadout": Packs.vehicle(vehicle_id).get("loadout", []),
		"name": str(Packs.vehicle(vehicle_id).get("name", vehicle_id)), "ai": {}, "parked": true, "protection": 0.0,
		"cloak_s": make_pad_cloak_s(soldier)})


## [pad transform] of a dedicated pad station when no vehicle stands on it ([] otherwise).
func find_own_pad(station: int) -> Array:
	var xf: Transform3D = stations[station].xf
	xf.origin += Vector3.UP * float(stations[station].get("lift", 0.0))
	return [xf] if _is_pad_clear(xf.origin) else []


## [pad transform] of the nearest vehicle pad within PAD_SEARCH_RADIUS of `near` with no vehicle on it ([] none).
func find_clear_pad(near: Vector3) -> Array:
	var pads: Array = battle.spawner.pad_points.duplicate()
	pads.sort_custom(func(a: Transform3D, b: Transform3D) -> bool: return a.origin.distance_to(near) < b.origin.distance_to(near))
	for xf in pads:
		if (xf as Transform3D).origin.distance_to(near) > PAD_SEARCH_RADIUS:
			break
		if _is_pad_clear((xf as Transform3D).origin):
			return [xf]
	return []


func _is_pad_clear(p: Vector3) -> bool:
	for h in battle.vehicles.values():
		if is_instance_valid(h) and not (h is Infantry) and h.alive and h.global_position.distance_to(p) < PAD_CLEAR_RADIUS:
			return false
	return true


# ------------------------------------------------------------------ host: ammo stations

func _resupply_soldiers() -> void:
	for h in battle.vehicles.values():
		var soldier := h as Infantry if is_instance_valid(h) else null
		var i := find_station(soldier) if soldier else -1
		if i < 0 or stations[i].kind != "ammo":
			continue
		if is_extraction():
			apply_refill(soldier)
		else:
			apply_resupply(soldier)


## Asks the host to refill the local soldier's health and energy at the inventory station he stands on.
func request_refill() -> void:
	if multiplayer.is_server():
		_apply_refill_request(multiplayer.get_unique_id())
	else:
		_request_refill.rpc_id(1)


@rpc("any_peer", "reliable")
func _request_refill() -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_refill_request(multiplayer.get_remote_sender_id())


func _apply_refill_request(peer: int) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	var i := find_station(soldier)
	if i >= 0 and stations[i].kind == "inventory":
		apply_refill(soldier)


## Full health and energy, nothing else (the extraction raid's stations: gear and ammunition are loot).
static func apply_refill(soldier: Infantry) -> void:
	InfantryPack.apply_repair(soldier, float(soldier.components[0].max))
	soldier.capacitor = soldier.capacitor_max


## One AmmoStation::onResupply step for `soldier`'s weapons and hand items (grenades, mines: 1 each).
static func apply_resupply(soldier: Infantry) -> void:
	for w in soldier.weapons:
		(w as InfantryWeapon).apply_resupply(int(RESUPPLY_ROUNDS.get(w.weapon_name, DEFAULT_RESUPPLY_ROUNDS)))
	soldier.kit.apply_resupply(soldier.armor, DEFAULT_RESUPPLY_ROUNDS)


## The nearest station of `kinds` that `soldier` may use, as its index (-1 when none within `max_distance`).
func find_nearest(soldier: Infantry, kinds: Array, max_distance: float) -> int:
	var best := -1
	var best_d := max_distance
	for i in stations.size():
		if not (str(stations[i].kind) in kinds) or not may_use(soldier, i):
			continue
		var d := soldier.global_position.distance_to((stations[i].xf as Transform3D).origin)
		if d < best_d:
			best_d = d
			best = i
	return best
