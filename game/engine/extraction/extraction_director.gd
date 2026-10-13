class_name ExtractionDirector
extends Node
## An extraction raid (config mode "extraction"; child "Extraction" of the Battle; docs/design/extraction.md).
## Host-authoritative over the LAN:
##   start     the host lays out the map (ExtractionMap), rolls the caches (LootRoller), spawns the faction squads
##             (ExtractionSquads), sets the relations and sends every peer one raid setup message; each player's
##             inventory starts as the kit he brought (lobby roster "kit"), and he drops in (ExtractionTransports)
##   loot      interact (InfantryInteraction offer, make_loot_offer) asks the host, which moves what fits from the nearest container into the inventory and
##             sends the container to every peer and the inventory to its owner only
##   downed    a lethal hit with a teammate up downs a player instead (ExtractionRevive: bleed-out, revive by interact)
##   death     a killed player leaves everything he carried and his worn armour in a bag, except his insured stack
##             (it goes home); killed bots leave their weapons, wrecks their Herc weapons as salvage; nobody respawns
##   exfil     exfil_call (pad: hold the right stick click; inventory_toggle: hold X, HeldAction) -> ExtractionTransports; an extracted player's carried items go to his profile's stash
##             (his own machine saves it); the raid ends when no player is left in it
## Every peer keeps its own profile (ExtractionProfile): the kit is spent when the raid starts.

const STATUS_IN_RAID := "in_raid"
const STATUS_EXTRACTED := "extracted"
const STATUS_DEAD := "dead"
const STATUS_LEFT := "left"
const NOTIFY_SECONDS := 4.0
const STATE_SYNC_SECONDS := 0.25
const DROP_MERGE_RADIUS := 2.5
## A drop is probed for its floor from this far above the point it fell from (metres; a soldier's feet sink a little).
const DROP_PROBE_LIFT := 0.5
## Caches are put on the highest floor found this far above the terrain (metres).
const FLOOR_PROBE_HEIGHT := 60.0
const STATIC_LAYERS := 0xFFFFFFFF
const CALLIN_AHEAD := 14.0
const SCATTER_SPREAD := 0.8

var battle: Battle
var built := {}
var map: ExtractionMap
var transports: ExtractionTransports
var rng := RandomNumberGenerator.new()
## Host: peer -> ExtractionInventory; peer -> raid status.
var inventories := {}
var status := {}
## Every peer: container id -> LootContainer; zone points; exfil states [{zone, state, seconds}]; team -> faction.
var containers := {}
var zones: Array = []
var exfil_states: Array = []
var faction_teams := {}
## The local player's inventory (the host's copy for him) and raid status.
var my_inventory := ExtractionInventory.new()
var my_status := STATUS_IN_RAID
## What the local player's insured slot kept when he was killed.
var my_kept: Array = []
var hud: ExtractionHud
## Downed players and revives (every peer).
var revive: ExtractionRevive
## Inventory stations (supply panel) and the pre-raid tasks (every peer).
var station: ExtractionStation
var tasks: RaidTasks
## Host: peer -> the armour he wore in (dropped on death unless free) and his insured slot [item id, units].
var worn_armor := {}
var insured := {}
var _next_container := 1
var _reload_t := 0.0
var _sync_t := 0.0
var _end_t := -1.0
var _outcomes := {}       # peer -> text
## Pad holds (SiegeInput.HELD_ACTIONS): X held opens the inventory, the right stick click held calls exfil.
var _inventory_hold := HeldAction.new("inventory_toggle")
var _exfil_hold := HeldAction.new("exfil_call")


func _init(p_battle: Battle, p_built: Dictionary) -> void:
	battle = p_battle
	built = p_built
	name = "Extraction"


func _ready() -> void:
	hud = ExtractionHud.new(self)
	battle.overlay.add_child(hud)
	Net.player_left.connect(_on_player_left)
	if not Net.is_online():
		Session.launcher_page = "extraction"
	var interaction := InfantryInteraction.of(battle)
	if interaction:
		interaction.add_provider(make_loot_offer)
	if battle.infantry and battle.infantry.gear:
		battle.infantry.gear.reload_hook = _apply_reload_request
	revive = ExtractionRevive.new(self)
	add_child(revive)
	station = ExtractionStation.new(self)
	add_child(station)
	tasks = RaidTasks.new(self)
	add_child(tasks)
	_apply_exit_guard()
	_commit_local_kit()


## Host: riders may get out only where it is safe (ExitSafety through OccupancyDirector.exit_guard; playtest X7).
func _apply_exit_guard() -> void:
	if not multiplayer.is_server():
		return
	battle.occupancy.exit_guard = make_exit_refusal
	battle.occupancy.exit_refused.connect(func(peer: int, reason: String) -> void: notify(peer, reason))


## Host: "" when `peer` may leave `vehicle` here, else why not (raid players only).
func make_exit_refusal(peer: int, vehicle: Herc) -> String:
	var soldier := battle.occupancy.soldier_of(peer)
	if not is_in_raid(peer) or soldier == null:
		return ""
	return ExitSafety.make_refusal(battle, soldier, vehicle)


## The objective lines (MissionObjectives): the raid's steps, then the local player's pre-raid tasks.
func make_objective_lines() -> Array:
	var extracted := my_status == STATUS_EXTRACTED
	var lines := [
		{"text": "Loot caches and bags (%s)" % InfantryInteraction.make_key_text(), "done": not my_inventory.is_empty() or extracted},
		{"text": "Call an exfil transport (%s)" % OccupancyHint.make_key_text("exfil_call"), "done": not exfil_states.is_empty() or extracted},
		{"text": "Reach the extraction zone and get out alive", "done": extracted},
	]
	return lines + tasks.make_objective_lines()


## The local soldier steps onto an inventory station (TribesStations.EXTRACTION_SHOP_METHOD): the supply panel.
func open_station_shop(soldier: Infantry) -> void:
	station.open_for(soldier)


## The inventory panel's Equip button.
func request_equip(item_id: String) -> void:
	_request("_request_equip_item", [item_id])


@rpc("any_peer", "reliable")
func _request_equip_item(item_id: String) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_equip_item(multiplayer.get_remote_sender_id(), item_id)


## Host: `peer` takes `item_id` (a weapon he carries) in hand, or wears it (a pack): it moves to the front of his
## inventory, which ExtractionLoadout reads in order (playtest X4).
func _apply_equip_item(peer: int, item_id: String) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if not is_in_raid(peer) or soldier == null or soldier.stowed or DownedState.is_downed(soldier):
		return
	var inv: ExtractionInventory = inventories[peer]
	if inv.count(item_id) <= 0 or not ExtractionItems.kind_of(item_id) in ExtractionLoadout.EQUIP_KINDS:
		return
	inv.apply_move_to_front(item_id)
	apply_equipment(peer)
	ExtractionLoadout.apply_reload(soldier, inv)
	send_inventory(peer)


## Interact offer (InfantryInteraction provider): the container within reach of the local player's `soldier`.
func make_loot_offer(soldier: Infantry) -> Dictionary:
	if my_status != STATUS_IN_RAID or DownedState.is_downed(soldier):
		return {}
	var c := find_container_near(soldier.global_position)
	if c == null:
		return {}
	return {"distance": Vector2(c.position.x - soldier.global_position.x, c.position.z - soldier.global_position.z).length(),
		"text": ExtractionHud.make_loot_text(c), "apply": func() -> void: _request("_request_pickup", [])}


## Every peer: the local player's kit leaves his profile for the raid.
func _commit_local_kit() -> void:
	var entry: Dictionary = battle.config.get("roster", {}).get(multiplayer.get_unique_id(), {})
	if not entry.get("kit") is Dictionary:
		return
	var profile := ExtractionProfile.load_for(Net.player_name)
	profile.apply_commit_kit()
	profile.save()


# ------------------------------------------------------------------ host: starting the raid

## Host, after the roster's soldiers exist: the layout, caches, squads, relations and the drop-in. It waits one
## physics frame first: the map's buildings answer ray queries only then (caches go on their floors).
func start_host() -> void:
	await get_tree().physics_frame
	if not is_inside_tree():
		return
	rng.seed = int(battle.config.get("extraction_seed", Time.get_ticks_usec()))
	map = ExtractionMap.make(battle, built, rng)
	transports = ExtractionTransports.make(self)
	var records := _roll_caches()
	var squads := ExtractionSquads.make(battle, rng)
	var roster: Dictionary = battle.config.get("roster", {})
	faction_teams = squads.spawn_all(map.areas, RaidTasks.make_required_factions(roster),
		RaidTasks.make_site_claims(roster, built.get("map", {}) if built.get("map") is Dictionary else {}))
	var teams := faction_teams.duplicate()
	for peer in battle.config.get("roster", {}):
		teams[make_player_team(int(peer))] = ""
	ExtractionFactions.apply_relations(teams, ExtractionFactions.make_preset_id(battle.config))
	_send_all("_setup_raid", [{"containers": records, "zones": map.zones, "areas": map.areas,
		"teams": faction_teams, "relations": TeamRelations.make_state()}])
	tasks.start_host(squads.placed_areas)
	for peer in battle.config.get("roster", {}):
		_start_player(int(peer))
	for h in battle.vehicles.values():
		watch(h)
	transports.start_drop_in(make_raid_peers())


func _roll_caches() -> Array:
	var roller := LootRoller.make(rng.randi())
	var rules := ExtractionRules.map_rules()
	var radius := float(rules.get("area_radius_m", 28.0))
	var records := []
	for area in map.areas:
		for i in ExtractionRules.roll_range(rng, rules.get("caches_per_area", [2, 3])):
			var a := rng.randf() * TAU
			var p := make_ground_point(area + Vector3(cos(a), 0, sin(a)) * rng.randf_range(4.0, radius))
			records.append(_make_record(roller.make_cache(roller.make_weighted_key(ExtractionRules.data().area_cache_weights)), p))
	for i in int(rules.get("scattered_caches", 0)):
		var kind := roller.make_weighted_key(ExtractionRules.data().scattered_cache_weights)
		records.append(_make_record(roller.make_cache(kind), make_ground_point(map.make_random_point())))
	return records


func _make_record(cache: Dictionary, p: Vector3) -> Dictionary:
	var record := cache.duplicate()
	record["id"] = _next_container
	record["pos"] = p
	_next_container += 1
	return record


## `p` on the top floor there: a building's floor or roof when one stands over the terrain, else the terrain (a
## cache under a building could not be reached). Soldiers and vehicles are no floor.
func make_ground_point(p: Vector3) -> Vector3:
	var ground := MapBuilder.ground_height(battle, p)
	return Vector3(p.x, maxf(_make_floor_y(Vector3(p.x, ground + FLOOR_PROBE_HEIGHT, p.z), ground), ground), p.z)


## Where something dropped at `p` lies (playtest X1: bags floated out of reach): on the first floor below the drop
## (a building floor, a roof, else the terrain), never on a soldier's or vehicle's body.
func make_drop_point(p: Vector3) -> Vector3:
	var ground := MapBuilder.ground_height(battle, p)
	return Vector3(p.x, maxf(_make_floor_y(p + Vector3.UP * DROP_PROBE_LIFT, ground), ground), p.z)


## Height of the first world surface below `from` (down to just under `ground`); `ground` when none is hit.
func _make_floor_y(from: Vector3, ground: float) -> float:
	var query := PhysicsRayQueryParameters3D.create(from, Vector3(from.x, ground - 1.0, from.z), STATIC_LAYERS)
	query.exclude = ExitSafety.make_unit_rids(battle)
	var hit := battle.get_world_3d().direct_space_state.intersect_ray(query)
	return float(hit.position.y) if not hit.is_empty() else ground


func make_player_team(peer: int) -> int:
	return int(battle.config.get("roster", {}).get(peer, {}).get("team", ExtractionRules.data().get("player_team_base", 10)))


## The transports' team: below the players' (nobody's; the AI ignores transports anyway).
func make_transport_team() -> int:
	return int(ExtractionRules.data().get("player_team_base", 10)) - 1


func _start_player(peer: int) -> void:
	var kit: Dictionary = battle.config.roster[peer].get("kit", {}) if battle.config.roster[peer].get("kit") is Dictionary else {}
	var soldier := battle.occupancy.soldier_of(peer)
	var inv := ExtractionInventory.make_for_size(str(soldier.armor.get("size", "light")) if soldier else "light")
	inv.apply_stacks(kit.get("items", []))
	inventories[peer] = inv
	status[peer] = STATUS_IN_RAID
	worn_armor[peer] = str(kit.get("armor", soldier.armor_id if soldier else ""))
	insured[peer] = kit.get("insured", []) if kit.get("insured") is Array else []
	if soldier:
		ExtractionLoadout.apply_free_weapon(soldier, inv)
		apply_equipment(peer)
		ExtractionLoadout.apply_weapon_overrides(soldier)
		ExtractionLoadout.apply_raid_start(soldier)
		ExtractionLoadout.apply_reload(soldier, inv)
	send_inventory(peer)


## Host: `h` is watched for its death (bags and salvage).
func watch(h: Herc) -> void:
	if is_instance_valid(h) and not h.destroyed.is_connected(_on_destroyed):
		h.destroyed.connect(_on_destroyed)


# ------------------------------------------------------------------ queries

func is_in_raid(peer: int) -> bool:
	return str(status.get(peer, "")) == STATUS_IN_RAID


## Host: the players still in the raid.
func make_raid_peers() -> Array:
	return status.keys().filter(func(p) -> bool: return is_in_raid(int(p)))


## Host: the raid player whose soldier `soldier` is (0 = a bot).
func peer_of(soldier: Infantry) -> int:
	for peer in status:
		if battle.occupancy.soldier_of(int(peer)) == soldier:
			return int(peer)
	return 0


## Every peer: the container nearest `p` within the pickup reach (null when none).
func find_container_near(p: Vector3) -> LootContainer:
	var reach := float(ExtractionRules.data().get("pickup_reach_m", 3.0))
	var best: LootContainer = null
	for c in containers.values():
		var lc := c as LootContainer
		var d := Vector2(lc.position.x - p.x, lc.position.z - p.z).length()
		if d <= reach and absf(lc.position.y - p.y) <= reach and (best == null or d < Vector2(best.position.x - p.x, best.position.z - p.z).length()):
			best = lc
	return best


# ------------------------------------------------------------------ local input

func _process(delta: float) -> void:
	_inventory_hold.advance(delta)
	_exfil_hold.advance(delta)
	if battle.is_over() or my_status != STATUS_IN_RAID or DownedState.is_downed(battle.player):
		return
	if _inventory_hold.just_fired and not revive.is_local_reviving():
		InventoryPanel.toggle(self)
	if _exfil_hold.just_fired:
		_request("_request_exfil", [])


func _unhandled_input(event: InputEvent) -> void:
	if battle.is_over() or my_status != STATUS_IN_RAID:
		return
	if event.is_action_pressed("exfil_call"):
		_request("_request_exfil", [])
	elif event.is_action_pressed("inventory_toggle"):
		InventoryPanel.toggle(self)


## Sends a request to the host (or runs it here on the host).
func _request(method: String, args: Array) -> void:
	if multiplayer.is_server():
		callv("_apply" + method.trim_prefix("_request"), [multiplayer.get_unique_id()] + args)
	else:
		callv("rpc_id", [1, method] + args)


## The inventory panel's Drop button.
func request_drop(item_id: String, units: int) -> void:
	_request("_request_drop", [item_id, units])


## The inventory panel's Use button (vehicle call-ins).
func request_use(item_id: String) -> void:
	_request("_request_use", [item_id])


@rpc("any_peer", "reliable")
func _request_pickup() -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_pickup(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func _request_exfil() -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_exfil(multiplayer.get_remote_sender_id())


@rpc("any_peer", "reliable")
func _request_drop(item_id: String, units: int) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_drop(multiplayer.get_remote_sender_id(), item_id, units)


@rpc("any_peer", "reliable")
func _request_use(item_id: String) -> void:
	if is_inside_tree() and multiplayer.is_server():
		_apply_use(multiplayer.get_remote_sender_id(), item_id)


# ------------------------------------------------------------------ host: what players do

## Host: `peer` loots the nearest container: money and every item that fits.
func _apply_pickup(peer: int) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if not is_in_raid(peer) or soldier == null or not soldier.alive or soldier.stowed or DownedState.is_downed(soldier):
		return
	var c := find_container_near(soldier.global_position)
	if c == null:
		return
	var inv: ExtractionInventory = inventories[peer]
	var taken := []
	inv.money += c.money
	if c.money > 0:
		taken.append(ExtractionRules.make_money_text(c.money))
	var left := []
	for s in c.stacks:
		var n := inv.apply_add(str(s[0]), int(s[1]))
		if n > 0:
			taken.append(ExtractionItems.make_stack_text(str(s[0]), n))
		if int(s[1]) - n > 0:
			left.append([s[0], int(s[1]) - n])
	_set_container(c.container_id, left, 0)
	apply_equipment(peer)
	ExtractionLoadout.apply_reload(soldier, inv)
	send_inventory(peer)
	var text := "Looted: %s" % ", ".join(PackedStringArray(taken)) if not taken.is_empty() else "Nothing fits."
	notify(peer, text + (" (full)" if not left.is_empty() else ""))


func _apply_exfil(peer: int) -> void:
	if is_in_raid(peer) and not DownedState.is_downed(battle.occupancy.soldier_of(peer)):
		notify(peer, transports.request_exfil(peer))


## Host: `peer` drops `units` of `item_id` at his feet (into a bag).
func _apply_drop(peer: int, item_id: String, units: int) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if not is_in_raid(peer) or soldier == null or soldier.stowed or DownedState.is_downed(soldier):
		return
	var inv: ExtractionInventory = inventories[peer]
	if ExtractionItems.kind_of(item_id) == "weapon":
		ExtractionLoadout.apply_unload_weapon(soldier, inv, ExtractionItems.ref_of(item_id))
	var n := inv.apply_take(item_id, units)
	if n <= 0:
		return
	drop_stacks([[item_id, n]], 0, soldier.global_position)
	apply_equipment(peer)
	send_inventory(peer)


## Host: `peer` uses `item_id`: a vehicle call-in puts that vehicle, empty, on the ground in front of him.
func _apply_use(peer: int, item_id: String) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if not is_in_raid(peer) or soldier == null or soldier.stowed or DownedState.is_downed(soldier) \
			or ExtractionItems.kind_of(item_id) != "callin":
		return
	var inv: ExtractionInventory = inventories[peer]
	if inv.apply_take(item_id, 1) < 1:
		return
	var vid := ExtractionItems.ref_of(item_id)
	var ahead := soldier.global_position - soldier.global_basis.z * CALLIN_AHEAD
	var p := SpawnClearance.make(battle).make_clear_origin(battle.infantry.make_on_ground(ahead))
	var spec := {"net_id": battle.spawner.allocate_id(), "vehicle": vid, "team": soldier.team,
		"owner": VehicleOccupancy.EMPTY, "xf": Transform3D(soldier.global_basis.orthonormalized(), p),
		"loadout": Packs.vehicle(vid).get("loadout", []), "name": str(Packs.vehicle(vid).get("name", vid)),
		"ai": {}, "parked": true, "protection": 0.0}
	battle.send_spawn(spec)
	watch(battle.vehicles.get(int(spec.net_id)))
	send_inventory(peer)
	notify(peer, "%s delivered." % str(Packs.vehicle(vid).get("name", vid)))


## Host: the soldier's weapons follow the inventory's weapon items (every peer re-equips him).
func apply_equipment(peer: int) -> void:
	var soldier := battle.occupancy.soldier_of(peer)
	if soldier == null:
		return
	var wanted := ExtractionLoadout.make_weapon_loadout(soldier, inventories[peer])
	if wanted == soldier.make_loadout():
		return
	var rounds := ExtractionLoadout.make_loaded_rounds(soldier)
	_send_all("_apply_equip", [soldier.net_id, wanted])
	ExtractionLoadout.apply_loaded_rounds(soldier, rounds)


@rpc("authority", "reliable", "call_local")
func _apply_equip(net_id: int, loadout: Array) -> void:
	var soldier := battle.vehicles.get(net_id) as Infantry
	if soldier == null:
		return
	soldier.equip(loadout)
	ExtractionLoadout.apply_weapon_overrides(soldier)
	if soldier == battle.player:
		battle.refresh_player_view()


# ------------------------------------------------------------------ host: deaths and extraction

func _on_destroyed(h: Herc, killer: Node) -> void:
	if not multiplayer.is_server() or h.has_meta("transport"):
		return
	tasks.on_unit_destroyed(h, killer)
	if h is Infantry:
		_on_soldier_killed(h as Infantry)
	else:
		_drop_wreck(h)


## A killed player leaves everything he carried and his worn armour in a bag, except his insured stack.
func _on_soldier_killed(soldier: Infantry) -> void:
	revive.apply_forget(soldier.net_id)
	var peer := peer_of(soldier)
	if peer == 0:
		drop_stacks(ExtractionLoadout.make_bot_stacks(soldier),
			ExtractionRules.roll_range(rng, ExtractionRules.data().get("bot_drop_money", [0, 0])), soldier.global_position)
		return
	if not is_in_raid(peer):
		return
	var inv: ExtractionInventory = inventories[peer]
	var split := ExtractionLoadout.make_insured_split(make_carried_with_armor(peer), insured.get(peer, []))
	drop_stacks(split.dropped, inv.money, soldier.global_position)
	inv.apply_clear()
	_finish_player(peer, STATUS_DEAD, split.kept, 0)


## Host: everything `peer` carries, his worn armour included (unless it is free standard issue).
func make_carried_with_armor(peer: int) -> Array:
	var all := ExtractionInventory.new()
	all.apply_merge(ExtractionLoadout.make_carried_stacks(battle.occupancy.soldier_of(peer), inventories[peer]))
	var armor_id := str(worn_armor.get(peer, ""))
	if armor_id != "" and not ExtractionItems.is_free_armor(armor_id):
		all.apply_add_unchecked(ExtractionItems.make_armor_id(armor_id), 1)
	return all.make_stacks()


## A destroyed vehicle leaves its Herc weapons as salvage (and a Cybrid its core, sometimes).
func _drop_wreck(h: Herc) -> void:
	var inv := ExtractionInventory.new()
	for w in h.weapons:
		inv.apply_add_unchecked(ExtractionItems.make_id("salvage", w.weapon_id), 1)
	if str(h.def.get("side", "")) == ExtractionFactions.KIND_CYBRID and rng.randf() < 0.5:
		inv.apply_add_unchecked(ExtractionItems.make_id("valuable", "cybrid_core"), 1)
	if not inv.is_empty():
		_add_container_at("wreck", inv.make_stacks(), 0, h.global_position)


## Host: `peer` leaves the raid with everything he carries.
func apply_extract(peer: int) -> void:
	if not is_in_raid(peer):
		return
	var soldier := battle.occupancy.soldier_of(peer)
	var inv: ExtractionInventory = inventories[peer]
	var carried := make_carried_with_armor(peer)
	var pay := tasks.make_payout(peer, carried)
	var stacks := RaidTasks.without_flags(carried)
	var money := inv.money + pay
	if pay > 0:
		notify(peer, "Tasks done: %s paid." % ExtractionRules.make_money_text(pay))
	var vehicle := battle.occupancy.vehicle_of(peer)
	if vehicle:
		VehicleOccupancy.of(vehicle).apply_leave(peer)
	if soldier:
		revive.apply_forget(soldier.net_id)
		_send_all("_retire_soldier", [soldier.net_id])
	_finish_player(peer, STATUS_EXTRACTED, stacks, money)


func _finish_player(peer: int, result: String, stacks: Array, money: int) -> void:
	status[peer] = result
	var carried := ExtractionInventory.new()
	carried.apply_merge(stacks)
	carried.money = money
	_outcomes[peer] = "%s: %s" % [battle.make_pilot_name(peer), "extracted (%s)" % ExtractionRules.make_money_text(carried.make_value())
		if result == STATUS_EXTRACTED else "killed in action"]
	_send_to(peer, "_raid_result", [result, stacks, money])
	notify_all(str(_outcomes[peer]))


@rpc("authority", "reliable", "call_local")
func _retire_soldier(net_id: int) -> void:
	var soldier := battle.vehicles.get(net_id) as Infantry
	if soldier:
		soldier.set_meta("extracted", true)
		soldier.apply_stowed(true, null)


## The local player's raid is over: extracted (`stacks`, his armour among them, go to his stash) or killed (his kit
## is lost; `stacks` is what his insured slot kept).
@rpc("authority", "reliable", "call_local")
func _raid_result(result: String, stacks: Array, money: int) -> void:
	my_status = result
	my_inventory.apply_clear()
	var profile := ExtractionProfile.load_for(Net.player_name)
	if result == STATUS_EXTRACTED:
		profile.apply_extracted(stacks, money)
		PlayerHold.apply(battle, true)
	else:
		profile.apply_died(stacks)
		my_kept = stacks
	profile.save()
	InventoryPanel.close_open(self)


func _on_player_left(peer: int) -> void:
	if multiplayer.is_server() and is_in_raid(peer):
		status[peer] = STATUS_LEFT
		_outcomes[peer] = "%s: left the raid" % battle.make_pilot_name(peer)


# ------------------------------------------------------------------ host: containers

## Host: `stacks` and `money` on the ground at `p`, in the bag already lying there or a new one.
func drop_stacks(stacks: Array, money: int, p: Vector3) -> void:
	if stacks.is_empty() and money <= 0:
		return
	for c in containers.values():
		var lc := c as LootContainer
		if lc.kind == "bag" and lc.position.distance_to(p) < DROP_MERGE_RADIUS:
			var inv := ExtractionInventory.new()
			inv.apply_merge(lc.stacks)
			inv.apply_merge(stacks)
			_set_container(lc.container_id, inv.make_stacks(), lc.money + money)
			return
	_add_container_at("bag", stacks, money, p)


func _add_container_at(kind: String, stacks: Array, money: int, p: Vector3) -> void:
	add_container({"kind": kind, "stacks": stacks, "money": money}, p)


## Host: a new container `fields` ({kind, stacks, money, optional shape}) dropped at `p`, on every peer.
func add_container(fields: Dictionary, p: Vector3) -> void:
	_send_all("_add_container", [_make_record(fields, make_drop_point(p))])


## Host: container `id` now holds `stacks` and `money` (removed everywhere when empty).
func _set_container(id: int, stacks: Array, money: int) -> void:
	if stacks.is_empty() and money <= 0:
		_send_all("_remove_container", [id])
	else:
		_send_all("_update_container", [id, stacks, money])


@rpc("authority", "reliable", "call_local")
func _setup_raid(setup: Dictionary) -> void:
	zones = setup.get("zones", [])
	faction_teams = setup.get("teams", {})
	TeamRelations.apply_state(setup.get("relations", {}))
	for record in setup.get("containers", []):
		_add_container(record)


@rpc("authority", "reliable", "call_local")
func _add_container(record: Dictionary) -> void:
	var c := LootContainer.make(record)
	containers[c.container_id] = c
	battle.add_child(c)


@rpc("authority", "reliable", "call_local")
func _update_container(id: int, stacks: Array, money: int) -> void:
	if containers.has(id):
		(containers[id] as LootContainer).apply_contents(stacks, money)


@rpc("authority", "reliable", "call_local")
func _remove_container(id: int) -> void:
	if containers.has(id):
		(containers[id] as LootContainer).queue_free()
		containers.erase(id)


# ------------------------------------------------------------------ host: every frame

func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or transports == null or battle.is_over():
		return
	transports.update(delta)
	_reload_t -= delta
	if _reload_t <= 0.0:
		_reload_t = float(ExtractionRules.data().get("reload_seconds", 0.5))
		_reload_all()
	_sync_t -= delta
	if _sync_t <= 0.0:
		_sync_t = STATE_SYNC_SECONDS
		_send_all("_exfil_update", [transports.make_states()])
	_check_end(delta)


## Host: pack_use with no pack to switch (InfantryGearDirector.reload_hook): load the rounds and hand items the
## player carries now instead of at the next reload_seconds tick.
func _apply_reload_request(peer: int, soldier: Infantry) -> void:
	if is_in_raid(peer) and inventories.has(peer) and ExtractionLoadout.apply_reload(soldier, inventories[peer]):
		send_inventory(peer)


func _reload_all() -> void:
	for peer in make_raid_peers():
		var soldier := battle.occupancy.soldier_of(int(peer))
		if soldier and soldier.alive and ExtractionLoadout.apply_reload(soldier, inventories[peer]):
			send_inventory(int(peer))


@rpc("authority", "unreliable", "call_local")
func _exfil_update(states: Array) -> void:
	exfil_states = states


## The raid ends end_delay_s after the last player left it.
func _check_end(delta: float) -> void:
	if status.is_empty() or not make_raid_peers().is_empty():
		return
	if _end_t < 0.0:
		_end_t = ExtractionRules.timer(battle.config, "end_delay_s")
	_end_t -= delta
	if _end_t <= 0.0:
		var lines := PackedStringArray(_outcomes.values().map(func(t) -> String: return str(t)))
		battle.end_match("Raid over.  %s" % "  -  ".join(lines))


# ------------------------------------------------------------------ messages

## Host: peer's inventory to its owner only.
func send_inventory(peer: int) -> void:
	if inventories.has(peer):
		_send_to(peer, "_inventory_state", [(inventories[peer] as ExtractionInventory).make_state()])


@rpc("authority", "reliable", "call_local")
func _inventory_state(state: Dictionary) -> void:
	my_inventory.apply_state(state)


## Host: a message on `peer`'s screen only.
func notify(peer: int, text: String) -> void:
	_send_to(peer, "_notify", [text])


## Host: a message on every screen.
func notify_all(text: String) -> void:
	_send_all("_notify", [text])


@rpc("authority", "reliable", "call_local")
func _notify(text: String) -> void:
	battle.overlay.show_message(text, NOTIFY_SECONDS)


## Host: runs `method` on `peer`'s machine (here when it is the host's own player; nothing for bots).
func _send_to(peer: int, method: String, args: Array) -> void:
	send_to(peer, self, method, args)


## Host: runs `node`'s rpc `method` on `peer`'s machine (a raid node such as ExtractionStation).
func send_to(peer: int, node: Node, method: String, args: Array) -> void:
	if peer == multiplayer.get_unique_id():
		node.callv(method, args)
	elif peer > 0 and Net.is_online() and multiplayer.get_peers().has(peer):
		node.callv("rpc_id", [peer, method] + args)


## Host: runs `method` on every peer (call_local methods).
func _send_all(method: String, args: Array) -> void:
	send_all_from(self, method, args)


## Host: runs `node`'s call_local rpc `method` on every peer (a raid node such as ExtractionRevive).
static func send_all_from(node: Node, method: String, args: Array) -> void:
	if Net.is_online():
		node.callv("rpc", [method] + args)
	else:
		node.callv(method, args)


## The local player's insured item id ("" = none), from the kit he brought (lobby roster).
func make_my_insured_id() -> String:
	var entry: Dictionary = battle.config.get("roster", {}).get(multiplayer.get_unique_id(), {})
	var kit: Dictionary = entry.get("kit", {}) if entry.get("kit") is Dictionary else {}
	return ExtractionProfile.make_insured_id_of(kit.get("insured", []) if kit.get("insured") is Array else [])
