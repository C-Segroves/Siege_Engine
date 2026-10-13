class_name TribesActors
extends RefCounted
## The clients of a Tribes / Tribes 2 training mission and what they control (host):
##   clients   the player's (bound to the soldier Battle spawned for him) and the AI's (Tribes createAI, Tribes 2
##             AIConnect): records of the client id range with fields name / team / player;
##   players   a soldier (Infantry) per client, a "Player" record whose node is the soldier; an AI soldier gets a
##             TribesBot brain; the script inventory ({lower item: count}) is made real by TribesItems;
##   vehicles  vehicles the scripts make (Tribes 2 `new HoverVehicle` / `new FlyingVehicle`): real vehicles of the
##             catalog, parked and empty; a vehicle given a pilot destination (setPilotDestination) flies there
##             on rails (SCRIPTED_FLIGHT_SPEED), the soldiers mounted in it (mountObject) riding along hidden.
## Live fields: a client's `player` is its living player (0 when dead), an object's `position` is where its node is.

const BOT_ID_BASE := InfantryBots.BOT_ID_BASE - 100
const PLAYER_CLASS := "Player"
## Metres per second of a scripted flight when the vehicle's datablock has no maxForwardSpeed.
const SCRIPTED_FLIGHT_SPEED := 60.0
const ARRIVE_DISTANCE := 2.0
## Seconds of spawn protection that stand for the scripts' `invincible` flag.
const INVINCIBLE_SECONDS := 1.0e6
const BOT_SKILL_FLOOR := 0.3

var rt: TribesMissionRuntime
var sim: TribesSimObjects
var human_client := 0
## Clients join this group when the game keeps one (Tribes 2 ClientGroup), 0 = none.
var client_group := 0
var client_class := "GameConnection"
var ai_client_class := "AIConnection"
var inventories := {}            # player id -> {lower item: count}
var _bot_index := 0
var _riders := {}                # player id -> vehicle object id
var _flights := {}               # vehicle object id -> engine-frame destination


func _init(runtime: TribesMissionRuntime) -> void:
	rt = runtime
	sim = runtime.sim


# ------------------------------------------------------------------ clients

func make_client(client_name: String, script_team: int, ai: bool) -> int:
	var id := sim.create(ai_client_class if ai else client_class, "", client_group,
		{"name": client_name, "team": script_team}, true)
	sim.objects[id]["is_client"] = true
	sim.objects[id]["ai"] = ai
	sim.objects[id]["player_id"] = 0
	return id


func bind_human(soldier: Infantry) -> void:
	human_client = make_client(soldier.display_name, rt.make_script_team(soldier.team), false)
	_make_player(human_client, soldier)


func is_client(id: int) -> bool:
	return bool(sim.get_record(id).get("is_client", false))


func is_ai(id: int) -> bool:
	return bool(sim.get_record(client_of(id)).get("ai", false))


## Every client, the player's first.
func clients() -> Array:
	var out := [human_client] if sim.exists(human_client) else []
	for id in sim.objects:
		if is_client(int(id)) and int(id) != human_client:
			out.append(int(id))
	return out


## The player object of a client or player id (also when dead; 0 = none).
func player_of(id: int) -> int:
	var rec := sim.get_record(id)
	if rec.is_empty():
		return 0
	if rec.get("is_client", false):
		return int(rec.player_id)
	return id if String(rec.class) == PLAYER_CLASS else 0


func client_of(id: int) -> int:
	var rec := sim.get_record(id)
	if rec.get("is_client", false):
		return id
	return int(rec.fields.get("client", 0)) if String(rec.get("class", "")) == PLAYER_CLASS else 0


func soldier_of(id: int) -> Infantry:
	var node = sim.get_record(player_of(id)).get("node")
	return node as Infantry if is_instance_valid(node) else null


func is_alive(id: int) -> bool:
	var s := soldier_of(id)
	return s != null and s.alive


func _make_player(client: int, soldier: Infantry) -> int:
	var pid := sim.create(PLAYER_CLASS, "", 0, {"client": client})
	sim.objects[pid].node = soldier
	sim.objects[client].player_id = pid
	inventories[pid] = {}
	soldier.set_meta("tribes_player", pid)
	soldier.destroyed.connect(func(_h: Herc, killer: Node) -> void: _on_destroyed(pid, killer))
	return pid


func _on_destroyed(pid: int, killer: Node) -> void:
	var killer_pid := int(killer.get_meta("tribes_player", 0)) if killer is Node and killer.has_meta("tribes_player") else 0
	rt.on_player_killed(pid, killer_pid)


# ------------------------------------------------------------------ spawning

## Puts `client`'s soldier at `xf` (engine frame): a dead soldier respawns there, a living one moves there, an
## AI client without one gets a new bot soldier. Returns the player id (0 = none).
func spawn_player(client: int, xf: Transform3D) -> int:
	var soldier := soldier_of(client)
	if soldier != null:
		if not soldier.alive:
			inventories[player_of(client)] = {}   # a respawn starts with the armour's spawn kit again
			soldier.respawn(xf)
		else:
			soldier.global_transform = xf
			soldier.velocity = Vector3.ZERO
			soldier.torso_target = xf.basis.get_euler().y
		return player_of(client)
	if not is_ai(client):
		return 0
	return _spawn_bot(client, xf)


func _spawn_bot(client: int, xf: Transform3D) -> int:
	var rec := sim.get_record(client)
	var bot_id := BOT_ID_BASE - _bot_index
	_bot_index += 1
	var team := rt.make_battle_team(int(DarkstarScript.num(rec.fields.get("team", 1))))
	var spec: Dictionary = rt.battle.infantry.make_soldier_spec(bot_id, team, DarkstarScript.to_str(rec.fields.get("name", "Bot")), xf)
	spec.armor = InfantryCatalog.light_armor_id(rt.pack)
	spec.vehicle = spec.armor
	spec.loadout = []
	spec["bot"] = true
	rt.battle.send_spawn(spec)
	var soldier := rt.battle.vehicles.get(int(spec.net_id)) as Infantry
	if soldier == null:
		return 0
	var skill := maxf(DarkstarScript.num(rec.fields.get("skill", 0.5)), BOT_SKILL_FLOOR)
	soldier.add_child(TribesBot.make_scripted(soldier, bot_id, skill))
	return _make_player(client, soldier)


## Takes an AI client out of the mission (Tribes 2 AIConnection.drop): its soldier leaves the battle.
func drop_client(client: int) -> void:
	var soldier := soldier_of(client)
	if soldier != null and soldier.has_meta("bot_id"):
		rt.battle.remove_vehicle(soldier.net_id)
	var pid := player_of(client)
	inventories.erase(pid)
	sim.delete(pid)
	sim.delete(client)


func brain_of(id: int) -> TribesBot:
	var s := soldier_of(id)
	return s.get_node_or_null("Bot") as TribesBot if s != null else null


func order_engage(client: int, target: int) -> void:
	var brain := brain_of(client)
	if brain:
		brain.apply_engage(soldier_of(target))


func order_move(client: int, p: Vector3) -> void:
	var brain := brain_of(client)
	if brain:
		brain.apply_move(p)


# ------------------------------------------------------------------ inventory

func item_count(player: int, item: String) -> int:
	return int((inventories.get(player_of(player), {}) as Dictionary).get(item.to_lower(), 0))


func set_item(player: int, item: String, n: int) -> void:
	var pid := player_of(player)
	if not inventories.has(pid):
		return
	var inv: Dictionary = inventories[pid]
	if n > 0:
		inv[item.to_lower()] = n
	else:
		inv.erase(item.to_lower())
	rt.items.apply_to(soldier_of(pid), inv)


## clearInventory: no weapons, hand items or pack (the spawn kit too).
func clear_items(player: int) -> void:
	var pid := player_of(player)
	var s := soldier_of(pid)
	if not inventories.has(pid):
		return
	inventories[pid] = {}
	if s != null:
		s.kit.counts.clear()
		s.kit.pack_id = ""
		s.kit.grenade_id = ""
	rt.items.apply_to(s, inventories[pid])


## Puts the weapon an item stands for in the soldier's hand (Tribes 2 use(), Tribes Player::mountItem).
func use_item(player: int, item: String) -> void:
	var s := soldier_of(player)
	var wid := rt.items.weapon_of(item)
	if s == null or wid == "":
		return
	var slot := s.make_loadout().find(wid)
	if slot >= 0:
		s.apply_weapon_slot(slot)


## Tribes 2 setArmor("Light" / "Heavy" ...): the pack's armour of that size, the inventory carried over.
func set_armor(player: int, armor_name: String) -> void:
	var s := soldier_of(player)
	var armor_id := rt.items.armor_of(armor_name)
	if s == null or armor_id == "" or armor_id == s.armor_id:
		return
	s.apply_armor(armor_id, s.make_loadout(), s.kit.grenade_id, s.kit.pack_id)
	rt.items.apply_to(s, inventories.get(player_of(player), {}))
	if s == rt.battle.player:
		rt.battle.refresh_player_view()


# ------------------------------------------------------------------ live fields

## A field the engine keeps live (null: the script's own value).
func make_field(id: int, f: String):
	var rec := sim.get_record(id)
	if rec.is_empty():
		return null
	if rec.get("is_client", false):
		match f:
			"player":
				return int(rec.player_id) if is_alive(id) else 0
			"vehiclemounted":
				return _riders.get(int(rec.player_id), rec.fields.get(f, 0))
	if f == "position" and is_instance_valid(rec.get("node")):
		return DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(sim.position_of(id)))
	return rec.fields.get(f, null)


## A script set field `f` of `id` to `v`: the engine fields act on the battle.
func apply_field(id: int, f: String, v) -> void:
	var rec := sim.get_record(id)
	match f:
		"invincible":
			var s := soldier_of(id)
			if s != null:
				s.spawn_protection = INVINCIBLE_SECONDS if DarkstarScript.truthy(v) else 0.0
				s.apply_spawn_protection()
		"team":
			var s := soldier_of(id) if rec.get("is_client", false) else null
			if s != null:
				s.team = rt.make_battle_team(int(DarkstarScript.num(v)))


# ------------------------------------------------------------------ vehicles

## A catalog vehicle for the script object `id` of datablock `datablock`, parked and empty at its position.
func spawn_vehicle(id: int, datablock: String, xf: Transform3D, script_team: int) -> void:
	var vid := rt.items.vehicle_of(datablock)
	if vid == "":
		rt.add_warning("no vehicle for datablock %s" % datablock)
		return
	var vdef := Packs.vehicle(vid)
	var spec := {"net_id": rt.battle.spawner.allocate_id(), "vehicle": vid, "team": rt.make_battle_team(script_team),
		"owner": VehicleOccupancy.EMPTY, "xf": xf, "loadout": vdef.get("loadout", []),
		"name": str(vdef.get("name", vid)), "ai": {}, "parked": true, "protection": 0.0}
	rt.battle.send_spawn(spec)
	sim.objects[id].node = rt.battle.vehicles.get(int(spec.net_id))


## Removes a script-made vehicle's node from the battle.
func remove_node(id: int) -> void:
	var node = sim.get_record(id).get("node")
	if node is Herc and is_instance_valid(node):
		_flights.erase(id)
		rt.battle.remove_vehicle((node as Herc).net_id)


## mountObject: the soldier of `player` rides in vehicle `vehicle` (hidden, carried along).
func mount(vehicle: int, player: int) -> void:
	var s := soldier_of(player)
	if s == null:
		return
	_riders[player_of(player)] = vehicle
	s.apply_stowed(true)
	_refresh_view(s)
	var client := client_of(player)
	if sim.exists(client):
		sim.objects[client].fields["vehiclemounted"] = vehicle


func unmount(player: int) -> void:
	var pid := player_of(player)
	var s := soldier_of(pid)
	_riders.erase(pid)
	if s != null and s.stowed:
		s.apply_stowed(false)
		_refresh_view(s)
	var client := client_of(pid)
	if sim.exists(client):
		sim.objects[client].fields["vehiclemounted"] = 0


## The player's own soldier rides in the chase view (Infantry.prefers_chase_view) and walks in first person.
func _refresh_view(s: Infantry) -> void:
	if s == rt.battle.player:
		rt.battle.refresh_player_view()


func mounted_vehicle(player: int) -> int:
	return int(_riders.get(player_of(player), 0))


## setPilotDestination: the vehicle flies straight to `p` (engine frame).
func fly_to(vehicle: int, p: Vector3) -> void:
	var node = sim.get_record(vehicle).get("node")
	if node is Node3D and is_instance_valid(node):
		_flights[vehicle] = p
		(node as Node3D).set_physics_process(false)


func update(delta: float) -> void:
	for vid in _flights.keys():
		_fly(vid, delta)
	for pid in _riders:
		var s := soldier_of(pid)
		var v = sim.get_record(int(_riders[pid])).get("node")
		if s != null and v is Node3D and is_instance_valid(v):
			s.global_position = (v as Node3D).global_position


func _fly(vid: int, delta: float) -> void:
	var node = sim.get_record(vid).get("node")
	if not (node is Node3D and is_instance_valid(node)):
		_flights.erase(vid)
		return
	var n := node as Node3D
	var to: Vector3 = _flights[vid] - n.global_position
	if to.length() < ARRIVE_DISTANCE:
		return
	var step := minf(to.length(), _flight_speed(vid) * delta)
	n.global_position += to.normalized() * step
	n.rotation.y = atan2(-to.x, -to.z)


func _flight_speed(vid: int) -> float:
	var db := String(sim.get_record(vid).get("datablock", ""))
	var v := float(DarkstarScript.num((rt.datablocks.get(db, {}).get("fields", {}) as Dictionary).get("maxforwardspeed", 0)))
	return v if v > 0.0 else SCRIPTED_FLIGHT_SPEED
