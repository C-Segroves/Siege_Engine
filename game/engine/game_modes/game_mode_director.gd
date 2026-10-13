class_name GameModeDirector
extends Node
## Runs a battle's game mode (config "game_mode", GameModes; child "GameModes" of the Battle). Host-authoritative
## over the LAN:
##   host   feeds the rules (GameModeRules) the battle's events: kills (every combatant's `destroyed`), touches
##          (combatants within reach of an object, TOUCH_SECONDS apart), destroyed objectives (the Structures it
##          makes of them, or Tribes base objects when TribesBase reports them) and time; announces the rules'
##          messages, carries out their requests (respawn everybody, destroy a fouling Herc) and ends the match;
##          sends the rules' state to every peer when it changes (and every SYNC_SECONDS);
##   peers  draw the objects (GameModeVisuals) and give the objectives panel its lines (make_objective_lines) from
##          that state; a switch's group changes team with it (GameModeResources).
## The AI plays the objectives (GameModeBrains, GameModeAI); a mode's base defenders come back on their own
## (GameModeDefenders, WAR).
## Who touches: soldiers on foot; Hercs and other non-Tribes vehicles (the remake lets Hercs carry flags, as
## Starsiege CTF does); not riders or pilots of Tribes vehicles (Tribes 2 Flag::onCollision ignores mounted
## players; a carrier who boards keeps the flag).

const SYNC_SECONDS := 1.0
const TOUCH_SECONDS := 0.1
const MESSAGE_SECONDS := 4.0
const TRIBES_PACKS := ["tribes", "tribes2"]
const OBJECTIVE_SHAPE_REACH := 2.0
## Football: a penalised Herc plays on team + this (the original's yellow / purple) and drops this high.
const PENALTY_TEAM_OFFSET := 2
const PENALTY_DROP_LIFT := 1.0
## H's Tribes base objects (destructible generators, stations): their destruction counts as an objective's.
const TRIBES_BASE_NODE := "TribesBase"
const TRIBES_BASE_SIGNAL := "object_destroyed"

var battle: Battle
var mode_id := ""
var rules: GameModeRules
var map_data := {}
var visuals: GameModeVisuals
var brains: GameModeBrains
var defenders: GameModeDefenders
## Host: net id -> [own team, penalty box rect, placed] of a Herc in the Football penalty box.
var _penalty := {}
var _built := {}
var _watched := {}               # net id -> true (host: its `destroyed` is connected)
var _structures := {}            # object id -> Structure
var _touch_t := 0.0
var _sync_t := 0.0
var _sent_revision := -1


func _init(p_battle: Battle, built: Dictionary) -> void:
	name = "GameModes"
	battle = p_battle
	_built = built
	map_data = built.get("map", {})
	mode_id = GameModes.canonical(str(battle.config.get(GameModes.CONFIG_KEY, GameModes.DEFAULT)))
	rules = GameModes.make_rules(mode_id, GameModes.make_rules_settings(mode_id, map_data, battle.config))


func _ready() -> void:
	visuals = GameModeVisuals.new(battle)
	add_child(visuals)
	add_child(GameModeResources.new(self))
	brains = GameModeBrains.new(self)
	add_child(brains)
	defenders = GameModeDefenders.new(self)
	add_child(defenders)
	GameModeVisuals.apply_hidden_station_flags(_built.get("stations", []))
	if multiplayer.is_server():
		rules.setup(GameModes.make_mode_objects(mode_id, map_data), make_team_names())
		defenders.spawn_all.call_deferred()
	_build_objectives.call_deferred()


## Team id -> name of the teams playing (none in a free-for-all).
func make_team_names() -> Dictionary:
	if not GameModes.is_team_based(mode_id):
		return {}
	var d := GameModes.definition(mode_id)
	var count := clampi(int(battle.config.get("team_count", MapTeams.MIN_TEAMS)), int(d.get("min_teams", 2)),
		maxi(int(d.get("max_teams", 2)), 1))
	var out := {}
	for t in count:
		out[t] = MapTeams.make_team_name(t, battle.config)
	return out


# ------------------------------------------------------------------ players

## The rules' view of combatant `h` (see GameModeRules).
func make_player(h: Herc) -> Dictionary:
	var soldier := h as Infantry
	var riding := soldier != null and soldier.stowed
	var body: Herc = h
	var can_touch := not _is_tribes_vehicle(h)
	if riding:
		var vehicle: Herc = soldier.seat.vehicle if soldier.seat != null else null
		var piloting_herc := vehicle != null and soldier.seat.seat == VehicleOccupancy.PILOT_SEAT \
			and not _is_tribes_vehicle(vehicle)
		can_touch = piloting_herc
		if vehicle != null:
			body = vehicle
	return {"id": h.net_id, "key": h.display_name, "label": KillText.make_unit_label(h), "team": h.team, "alive": h.alive, "pos": body.global_position,
		"can_touch": can_touch and h.alive, "vehicle": not (body is Infantry), "integrity": body.integrity}


static func _is_tribes_vehicle(h: Herc) -> bool:
	return not (h is Infantry) and str(Assets.split_id(h.vehicle_id)[0]) in TRIBES_PACKS


## Every combatant: soldiers (on foot or riding) and vehicles with an AI pilot (a player's vehicle is played by
## his soldier).
func make_players() -> Array:
	var out := []
	for h in battle.vehicles.values():
		if is_instance_valid(h) and is_combatant(h):
			out.append(make_player(h))
	return out


## True when `h` plays for itself: a soldier, or a vehicle not piloted by somebody's soldier.
func is_combatant(h: Herc) -> bool:
	if h is Infantry:
		return true
	var occupancy := h.get_node_or_null(VehicleOccupancy.NODE_NAME) as VehicleOccupancy
	return occupancy == null or occupancy.is_ai_piloted() or (occupancy.has_pilot() and not _has_soldier(occupancy))


## True when the vehicle's pilot is a player or bot with a soldier (who then stands for him).
func _has_soldier(occupancy: VehicleOccupancy) -> bool:
	return battle.occupancy != null and battle.occupancy.soldier_of(occupancy.pilot()) != null


## The local player's view for the HUD ({} without a body).
func make_local_player() -> Dictionary:
	return make_player(battle.player) if is_instance_valid(battle.player) else {}


## The objectives panel's lines (MissionObjectives): the mode's goal, then its state as plain lines (scores,
## objectives, time left).
func make_objective_lines() -> Array:
	var out := [{"text": GameModes.make_objective_text(battle.config), "done": false}]
	var lines := rules.make_hud_lines(make_local_player())
	for line in lines.slice(1):   # the first is the mode's name, already in the goal line
		if line != "":
			out.append({"text": line, "info": true})
	return out


# ------------------------------------------------------------------ host loop

func _physics_process(delta: float) -> void:
	if multiplayer.is_server() and not battle.is_over() and not rules.over:
		_watch_new_combatants()
		var players := make_players()
		rules.apply_tick(delta, players)
		_touch_t -= delta
		if _touch_t <= 0.0:
			_touch_t = TOUCH_SECONDS
			_apply_touches(players)
		_flush(delta)
	visuals.apply(rules)
	_place_penalized()


func _watch_new_combatants() -> void:
	for id in battle.vehicles:
		if _watched.has(id):
			continue
		var h: Herc = battle.vehicles[id]
		if is_instance_valid(h):
			_watched[id] = true
			h.destroyed.connect(_on_destroyed)
			h.damaged.connect(_on_damaged)


func _on_destroyed(h: Herc, killer: Node) -> void:
	if not multiplayer.is_server() or rules.over:
		return
	var killer_player: Dictionary = make_player(killer) if killer is Herc and is_instance_valid(killer) else {}
	rules.apply_kill(make_player(h), killer_player)
	_flush(0.0)


func _on_damaged(h: Herc, attacker: Node) -> void:
	if multiplayer.is_server() and not rules.over and attacker is Herc and is_instance_valid(attacker) and attacker != h:
		rules.apply_hit(make_player(h), make_player(attacker))


func _apply_touches(players: Array) -> void:
	var radius := float(rules.settings.get("touch_radius_m", 3.0))
	var herc_radius := float(rules.settings.get("herc_touch_radius_m", 8.0))
	for p in players:
		if not bool(p.alive) or not bool(p.can_touch):
			continue
		var reach := herc_radius if bool(p.vehicle) else radius
		for o in rules.objects.values():
			if o.state != ModeObject.CARRIED and o.is_touched_at(p.pos, reach):
				rules.apply_touch(p, o.id)


## Messages, requests, the end of the match and the state for the peers.
func _flush(delta: float) -> void:
	for text in rules.take_messages():
		battle.fx("message", [text, MESSAGE_SECONDS], true)
	for r in rules.take_requests():
		_apply_request(r)
	if rules.over:
		_send_state()
		battle.end_match(rules.result_text, {}, rules.winner)
		return
	_sync_t -= delta
	if rules.revision != _sent_revision or _sync_t <= 0.0:
		_send_state()


func _apply_request(r: Dictionary) -> void:
	match str(r.get("kind", "")):
		"respawn_all":
			for h in battle.vehicles.values():
				if is_instance_valid(h) and is_combatant(h):
					h.respawn(battle.spawner.make_respawn_point(h.team))
		"kill":
			_destroy(int(r.id))
		"damage":
			var hurt: Herc = battle.vehicles.get(int(r.id))
			if is_instance_valid(hurt) and hurt.alive:
				hurt.apply_environment_damage(float(r.share))
		"penalty":
			if not (r.box as Array).is_empty():
				_penalty[int(r.id)] = [int(r.team), r.box, false]
				_set_team.rpc(int(r.id), int(r.team) + PENALTY_TEAM_OFFSET)
			_destroy(int(r.id))
		"penalty_end":
			var entry: Array = _penalty.get(int(r.id), [])
			_penalty.erase(int(r.id))
			if not entry.is_empty():
				_set_team.rpc(int(r.id), int(entry[0]))
			_destroy(int(r.id))


func _destroy(id: int) -> void:
	var h: Herc = battle.vehicles.get(id)
	if is_instance_valid(h) and h.alive:
		h.apply_destruction(null)


## Host: a Herc back from the dead while penalised starts inside its penalty box (Football sendToPenaltyBox:
## a random point in the box's rectangle).
func _place_penalized() -> void:
	if not multiplayer.is_server():
		return
	for id in _penalty:
		var entry: Array = _penalty[id]
		var h: Herc = battle.vehicles.get(id)
		if not is_instance_valid(h):
			continue
		if not h.alive:
			entry[2] = false
		elif not bool(entry[2]):
			entry[2] = true
			var box: Array = entry[1]
			var at := Vector3(randf_range(float(box[0]), float(box[2])), 0.0, randf_range(float(box[1]), float(box[3])))
			at.y = MapBuilder.ground_height(battle, at) + PENALTY_DROP_LIFT
			h.global_position = at


## Every peer: `id` plays for `team` (the Football penalty teams, yellow and purple in the original).
@rpc("authority", "reliable", "call_local")
func _set_team(id: int, team: int) -> void:
	var h: Herc = battle.vehicles.get(id)
	if is_instance_valid(h):
		h.team = team


func _send_state() -> void:
	_sync_t = SYNC_SECONDS
	_sent_revision = rules.revision
	if Net.is_online():
		_apply_state.rpc(rules.make_state())


@rpc("authority", "reliable")
func _apply_state(state: Dictionary) -> void:
	rules.apply_state(state)


# ------------------------------------------------------------------ destructible objectives

## Defend and Destroy / WAR (every peer, identically): each objective becomes a Structure at its placement with its
## map shape; Tribes base objects report their own destruction instead when TribesBase is there.
func _build_objectives() -> void:
	if GameModes.family_of(mode_id) != "defend_destroy":
		return
	var base := battle.get_node_or_null(TRIBES_BASE_NODE)
	if base != null and base.has_signal(TRIBES_BASE_SIGNAL) and str(map_data.get("_pack", "")) in TRIBES_PACKS:
		base.connect(TRIBES_BASE_SIGNAL, _on_base_object_destroyed)
		return
	var kinds: Array = rules.settings.get("objective_kinds", [ModeObject.KIND_OBJECTIVE])
	for d in GameModes.make_mode_objects(mode_id, map_data):
		if str(d.get("kind", "")) in kinds and int(d.get("team", -1)) >= 0:
			_build_structure(d)


func _build_structure(d: Dictionary) -> void:
	var at := ModeObject._vec(d.get("pos", [0, 0, 0]))
	var shape_id := _find_placed_shape(at)
	if shape_id == "":
		push_warning("GameModeDirector: no shape at objective %s (%s): it cannot be destroyed" % [d.get("id"), d.get("datablock", "")])
		return
	_remove_static_at(at, shape_id)
	var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(d.get("yaw", 0.0)))), at)
	var spack: String = Assets.split_id(shape_id)[0]
	var pal := Packs.default_palette(spack)
	var s := Structure.create(battle, shape_id, xf, pal if pal != "" else battle.palette_id, int(d.team),
		float(rules.settings.get("objective_hp", 6000.0)))
	s.display_name = str(d.get("name", d.get("datablock", "Objective")))
	_structures[int(d.id)] = s
	if multiplayer.is_server():
		s.destroyed.connect(func(_s: Structure, killer: Node) -> void: _on_objective_destroyed(int(d.id), killer))


## The shape the map places at `at` (a station or a static), "" when none.
func _find_placed_shape(at: Vector3) -> String:
	for list_key in ["stations", "statics"]:
		for o in map_data.get(list_key, []):
			var p: Array = o.get("pos", [0, 0, 0])
			if str(o.get("shape", "")) != "" and Vector3(p[0], p[1], p[2]).distance_to(at) <= OBJECTIVE_SHAPE_REACH:
				return str(o.shape)
	return ""


func _remove_static_at(at: Vector3, shape_id: String) -> void:
	var node_name := shape_id.replace(":", "_")
	for c in battle.get_children():
		if c is StaticBody3D and not (c is Structure) and str(c.name).begins_with(node_name) \
				and (c as Node3D).global_position.distance_to(at) <= OBJECTIVE_SHAPE_REACH:
			c.queue_free()
			return


func _on_objective_destroyed(object_id: int, killer: Node) -> void:
	var by: Dictionary = make_player(killer) if killer is Herc and is_instance_valid(killer) else {}
	rules.apply_destroyed(object_id, by)
	_flush(0.0)


## TribesBase reported `obj` destroyed: the objective at its place.
func _on_base_object_destroyed(obj: Node, killer: Node) -> void:
	if not multiplayer.is_server() or not (obj is Node3D):
		return
	for o in rules.objects.values():
		if o.team == int(obj.get("team")) and o.pos.distance_to((obj as Node3D).global_position) <= OBJECTIVE_SHAPE_REACH:
			_on_objective_destroyed(o.id, killer)
			return


## The node standing for mode object `object_id` (a destructible objective; null when none).
func make_objective_node(object_id: int) -> Node3D:
	if object_id == 0:
		return null
	if _structures.has(object_id) and is_instance_valid(_structures[object_id]):
		return _structures[object_id]
	var o: ModeObject = rules.objects.get(object_id)
	if o == null:
		return null
	for node in GameModeResources.make_group_nodes_of(battle, [[o.pos.x, o.pos.y, o.pos.z]]):
		return node
	return null
