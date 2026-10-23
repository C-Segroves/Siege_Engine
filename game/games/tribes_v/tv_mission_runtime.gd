class_name TVMissionRuntime
extends AAMissionRuntime
## Runs a Tribes: Vengeance campaign mission (tools/tv_import.py maps, docs/formats/tribes_vengeance.md "Mission scripts").
## The map's UnrealScript Script actors (maps/<id>/script.json, run by TVScriptHost on a MissionTask) drive the mission: level start and
## trigger-radius events start scripts that speak lines (the .ogg speech files), add / complete / remove objectives, enable
## or disable the placed soldiers (AI actors and AISpawnPoints) and end the mission (next / fail). A map without a
## script falls back to the Aerial Assault rule (reach the objective markers in order, else survive).
## The placed soldiers appear when enabled and the player comes near (NPC_SPAWN_RADIUS), as the originals' AI streamed in,
## wearing the Vengeance body of their class (tools/tv_skeletal.npc_body) on a Tribes 2 armour of that body's size; teams
## compare the TeamInfo names (same team as the player's start = ally).

const TV_PACK := "tribes_v"
const NPC_SPAWN_RADIUS := 170.0
const NPC_SPAWNS_PER_TICK := 4
const NPC_SKILL := 0.45
## A trigger reaches this far above and below its height (the Unreal collision cylinder's slack).
const TRIGGER_VERTICAL_SLACK := 2.5
const MIN_TRIGGER_RADIUS := 2.0
const TRIGGER_PLAYER := "player"
const VOICE_BUS := "Ducked"
const TELEPORT_LIFT := 1.0
const DAMAGE_HP := 100.0
const CHARACTER_BODIES := {"victoria": "tv_princessvictoria", "juliachild": "tv_imperiallightjulia", "julia": "tv_imperiallightjulia",
	"daniel": "tv_phoenixmediumdaniel", "mercury": "tv_mercury", "jericho": "tv_phoenixheavyjericho"}
const TEAM_BODIES := {"imperial": "tv_imperialmedium", "phoenix": "tv_phoenixmedium", "beagle": "tv_bloodeaglemedium"}
const SIZE_ARMOR := {"LIGHT": "tribes2:LIGHT", "MEDIUM": "tribes2:MEDIUM", "HEAVY": "tribes2:HEAVY", "CIVILIAN": "tribes2:LIGHT",
	"CREATURE": "tribes2:HEAVY"}

var script_run: MissionTask
var script_host: TVScriptHost
var script_data := {}
## [{name, text, state (0 open, 1 done, 2 failed), markers}]
var objectives: Array:
	get: return script_host.make_objective_records() if script_host != null else []
## Seconds left on the script's countdown (0 = none).
var countdown: float:
	get: return script_host.make_countdown() if script_host != null else 0.0
var player_team := ""
var _started := false
var _triggers: Array = []                # [{rec, area (AreaTrigger), enabled}]
var _npcs: Array = []                    # [{rec, enabled, spawned, dead, brain}]
var _npc_of := {}                        # soldier net id -> npc entry
var _squad_alive := {}                   # squad label -> living members
var _speech: AudioStreamPlayer
## The placed drivable vehicles (map.json "vehicles").
var fleet: TVVehicleFleet
var _bodies := {}                        # body id -> body record (bodies.json)


static func is_tv(mission: Dictionary) -> bool:
	return String(mission.get("runtime", "")) == TV_PACK


## The player's body (shape id with the pack prefix) and armour for `mission`: the start's pawn class names the character,
## else the start's team the faction; "" when the pack has no bodies.
static func make_player_body(mission: Dictionary) -> Dictionary:
	var m := MapBuilder.load_map(String(mission.get("map", "")))
	var start: Dictionary = {}
	for s in m.get("spawns", []):
		if str(s.get("kind", "")) == "infantry":
			start = s
			break
	var key := str(start.get("pawn", "")).to_lower()
	var id := ""
	for k in CHARACTER_BODIES:
		if key.contains(k):
			id = CHARACTER_BODIES[k]
			break
	if id == "":
		var team := str(start.get("team_name", "")).to_lower()
		for k in TEAM_BODIES:
			if team.contains(k):
				id = TEAM_BODIES[k]
				break
	if id == "":
		id = "tv_phoenixmedium"
	var shape := "%s:%s" % [TV_PACK, id]
	if not InfantryCatalog.is_shape_installed(shape):
		return {"body": "", "armor": ARMOR}
	var size := "MEDIUM"
	for b in InfantryCatalog.make_tv_all_bodies():
		if str(b.id) == id:
			size = str(b.size)
	return {"body": shape, "armor": str(SIZE_ARMOR.get(size, ARMOR))}


static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.map = String(mission.get("map", ""))
	config["infantry_pack"] = ARMOR.get_slice(":", 0)
	var who := make_player_body(mission)
	for peer in config.get("roster", {}):
		config.roster[peer]["infantry_armor"] = str(who.armor)
		config.roster[peer]["infantry_body"] = str(who.body)


static func make_mission_herc(mission: Dictionary) -> Dictionary:
	return {"vehicle": str(make_player_body(mission).armor), "loadout": []}


func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	super.setup(p_battle, mission, vars)
	for b in InfantryCatalog.make_tv_all_bodies():
		_bodies[str(b.id)] = b
	player_team = str(map.get("player_team", ""))
	fleet = TVVehicleFleet.new(self)
	fleet.build(map.get("vehicles", []))
	_speech = AudioStreamPlayer.new()
	_speech.bus = VOICE_BUS if AudioServer.get_bus_index(VOICE_BUS) >= 0 else "Master"
	add_child(_speech)
	var path := str(map.get("_dir", "")).path_join(str(map.get("script", "script.json")))
	if str(map.get("script", "")) != "" and FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary and not (parsed.get("scripts", []) as Array).is_empty():
			script_data = parsed
			script_host = TVScriptHost.new(self, script_data.scripts, script_data.get("actors", {}), _speech)
			script_run = script_host.tasks
			_build_triggers()
			_build_npcs()
			goal = GOAL_SCRIPT


## Scripted: the script run is the whole rule set; else the Aerial Assault fallback.
func _physics_process(delta: float) -> void:
	if script_run == null:
		super._physics_process(delta)
		return
	if _over or battle == null or not multiplayer.is_server():
		return
	elapsed += delta
	var p: Herc = battle.player
	if p == null or not is_instance_valid(p):
		return
	if not _started:
		_started = true
		script_run.fire("MessageLevelStart", "all")
		script_run.fire("MessagePlayerStart", "all")
		script_run.tick(0.0)          # the start-up scripts disable the soldiers that are not there yet, before any spawns
		_sync_placed()
	script_run.tick(delta)
	_check_triggers(p)
	script_host.apply_tick(delta)
	if make_rules_step(delta, CHECK_INTERVAL) <= 0.0:
		return
	_sync_placed()


# ------------------------------------------------------------------ triggers

func _build_triggers() -> void:
	for rec in script_data.get("triggers", []):
		var c: Array = rec.pos
		var radius := maxf(float(rec.radius), MIN_TRIGGER_RADIUS)
		# The script's height is the half height above and below the centre.
		var shape := AreaShape.make_cylinder(_vec(c), radius, float(rec.height) * 2.0, TRIGGER_VERTICAL_SLACK)
		var area := AreaTrigger.new(shape)
		area.max_enter = int(rec.get("max_enter", 0))
		area.entered.connect(func(_id: Variant) -> void: script_run.fire("MessageTriggerEnter", str(rec.label)))
		area.left.connect(func(_id: Variant) -> void: script_run.fire("MessageTriggerExit", str(rec.label)))
		_triggers.append({"rec": rec, "area": area, "enabled": bool(rec.get("enabled", true))})


func _check_triggers(p: Herc) -> void:
	var candidates := {TRIGGER_PLAYER: p.global_position}
	for t in _triggers:
		if bool(t.enabled):
			(t.area as AreaTrigger).apply_scan(candidates)


# ------------------------------------------------------------------ placed soldiers

func _build_npcs() -> void:
	for rec in map.get("npc_spawns", []):
		if str(rec.get("body", "")) == "":
			continue
		var e := {"rec": rec, "enabled": bool(rec.get("enabled", true)), "spawned": false, "dead": false, "brain": null, "goals": {}}
		_npcs.append(e)
		var squad := str(rec.get("squad", ""))
		if squad != "":
			_squad_alive[squad] = int(_squad_alive.get(squad, 0)) + 1


## Streams the placed soldiers and vehicles in around the player.
func _sync_placed() -> void:
	_sync_npcs()
	var p: Herc = battle.player
	if p != null and is_instance_valid(p):
		fleet.sync(p.global_position)


func _sync_npcs() -> void:
	var p: Herc = battle.player
	if p == null or not is_instance_valid(p):
		return
	_steer_npcs()
	var spawned := 0
	for e in _npcs:
		if not bool(e.enabled) or bool(e.spawned) or bool(e.dead):
			continue
		var pos := _vec(e.rec.pos)
		if p.global_position.distance_to(pos) <= NPC_SPAWN_RADIUS:
			_spawn_npc(e)
			spawned += 1
			if spawned >= NPC_SPAWNS_PER_TICK:
				return


func _spawn_npc(e: Dictionary) -> bool:
	var rec: Dictionary = e.rec
	var body_id := str(rec.body)
	var shape := "%s:%s" % [TV_PACK, body_id]
	if not InfantryCatalog.is_shape_installed(shape):
		e.spawned = true
		return false
	var size := str((_bodies.get(body_id, {}) as Dictionary).get("size", "MEDIUM"))
	var armor_id := str(SIZE_ARMOR.get(size, ARMOR))
	if InfantryCatalog.armor(armor_id).is_empty():
		armor_id = ARMOR
	var team := PLAYER_TEAM if _is_ally(str(rec.get("team", ""))) else ENEMY_TEAM
	var bots: InfantryBots = battle.infantry.bots
	var pos := _vec(rec.pos)
	var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(rec.get("yaw", 0.0)))), battle.infantry.make_on_ground(pos))
	var spec: Dictionary = battle.infantry.make_soldier_spec(bots.allocate_bot_id(), team, make_speaker_name(str(rec.get("label", ""))), xf)
	spec.armor = armor_id
	spec.vehicle = armor_id
	spec.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	spec["body_shape"] = shape
	spec["bot"] = true
	var brain := bots.spawn_bot(spec, NPC_SKILL)
	e.spawned = true
	if brain == null:
		return false
	e.brain = brain
	_steer(e)
	_npc_of[int(brain.soldier.net_id)] = e
	script_run.fire("MessageAISpawned", str(rec.get("label", "")))
	return true


## Writes the goals of entry `e` onto its brain (TVNpcGoals).
func _steer(e: Dictionary) -> void:
	var p: Herc = battle.player
	var at: Vector3 = p.global_position if p != null and is_instance_valid(p) else Vector3.ZERO
	TVNpcGoals.steer(e, script_data.get("actors", {}), at, _vec(e.rec.pos))


func _steer_npcs() -> void:
	for e in _npcs:
		if bool(e.spawned) and not bool(e.dead) and e.brain != null:
			_steer(e)


## The placed soldiers a goal op addresses: the actor by label, its spawn point, or every member of the squad of that label.
func _entries_for_goal(label: String) -> Array:
	return _npcs.filter(func(e: Dictionary) -> bool:
		return str(e.rec.get("label", "")) == label or str(e.rec.get("spawn_label", "")) == label or str(e.rec.get("squad", "")) == label)


func apply_goal(label: String, mode: String, name: String, goal: Dictionary) -> void:
	for e in _entries_for_goal(label):
		TVNpcGoals.apply(e, mode, name, goal)
		if bool(e.spawned) and not bool(e.dead) and e.brain != null:
			_steer(e)


func _is_ally(team: String) -> bool:
	if team == "" or player_team == "":
		return team == ""
	return team == player_team


## True when the TeamInfo name `team` is the player's side (a placed vehicle of it is his; "" = nobody's, parked for the taking).
func is_ally_team(team: String) -> bool:
	return _is_ally(team)


static func _vec(p: Array) -> Vector3:
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


func _entries_named(label: String) -> Array:
	return _npcs.filter(func(e: Dictionary) -> bool:
		return str(e.rec.get("label", "")) == label or str(e.rec.get("spawn_label", "")) == label)


## Host: a soldier of the battle was destroyed (a placed soldier dying raises MessageDeath, its squad's last member
## MessageSquadDeath; Aerial Assault's kill count stays for the fallback).
func on_unit_destroyed(h: Herc) -> void:
	super.on_unit_destroyed(h)
	if script_run == null:
		return
	if not (h is Infantry):
		var vehicle_label := fleet.apply_death(h)
		if vehicle_label != "":
			script_run.fire("MessageDeath", vehicle_label)
		return
	var e: Dictionary = _npc_of.get(int((h as Infantry).net_id), {})
	if e.is_empty() or bool(e.dead):
		return
	e.dead = true
	var label := str(e.rec.get("label", ""))
	if script_run.fire("MessageDeath", label) == 0:
		script_run.fire("MessageDeath", str(e.rec.get("class", "")))
	var squad := str(e.rec.get("squad", ""))
	if squad != "":
		_squad_alive[squad] = int(_squad_alive.get(squad, 1)) - 1
		if int(_squad_alive[squad]) <= 0:
			script_run.fire("MessageSquadDeath", squad)


# ------------------------------------------------------------------ host interface of TVScriptHost

func has_overlay() -> bool:
	return battle != null and battle.get("overlay") != null


func apply_enable(label: String, on: bool) -> void:
	fleet.apply_enable(label, on)
	for t in _triggers:
		if str(t.rec.label) == label:
			t.enabled = on
	for e in _entries_named(label):
		e.enabled = on
		if on and not bool(e.spawned) and not bool(e.dead):
			_spawn_npc(e)


func apply_destroy(label: String) -> void:
	fleet.apply_destroy(label)
	for t in _triggers:
		if str(t.rec.label) == label:
			t.enabled = false
	for e in _entries_named(label):
		e.dead = true
		var b = e.brain
		if b != null and is_instance_valid(b) and is_instance_valid(b.soldier) and b.soldier.alive:
			b.soldier.apply_environment_damage(1.0)


func apply_spawn_point(label: String, on: bool) -> void:
	for e in _entries_named(label):
		e.enabled = on
		if on and not bool(e.spawned) and not bool(e.dead):
			_spawn_npc(e)


func apply_teleport(label: String, to_label: String) -> void:
	var at: Array = script_data.get("actors", {}).get(to_label, [])
	if at.is_empty():
		return
	var spot := _vec(at) + Vector3(0, TELEPORT_LIFT, 0)
	if label.to_lower() == "player":
		var p: Herc = battle.player
		if p != null and is_instance_valid(p):
			p.global_position = spot
	else:
		for e in _entries_named(label):
			var b = e.brain
			if b != null and is_instance_valid(b) and is_instance_valid(b.soldier):
				b.soldier.global_position = spot


func apply_damage(label: String, amount: float) -> void:
	if label.to_lower() == "player":
		var p: Herc = battle.player
		if p != null and is_instance_valid(p):
			ScriptedDamage.apply_share(p, amount / DAMAGE_HP)


func apply_end(success: bool) -> void:
	if success:
		end_mission(true, CODE_SUCCESS, "Mission complete.")
	else:
		end_mission(false, CODE_FAILED, "Mission failed.")


# ------------------------------------------------------------------ objectives panel

func make_objective_lines() -> Array:
	if script_run == null:
		return super.make_objective_lines()
	return script_host.make_objective_lines()


## Display name of an actor label: "AIDanielThc" -> "Daniel"; the player's lines come from their character.
func make_speaker_name(label: String) -> String:
	if label == "" or label.to_lower() == "player":
		return "Player"
	var s := label
	if s.begins_with("AI"):
		s = s.substr(2)
	var out := ""
	for ch in s:
		if ch >= "0" and ch <= "9":
			break
		out += ch
	return out if out != "" else label
