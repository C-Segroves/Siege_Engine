class_name StarsiegeMissionRuntime
extends MissionRuntimeBase
## Runs a Starsiege campaign mission (gamedata/starsiege/missions/<ID>.json + <ID>.cs) inside a Battle.
##
## The mission JSON (tools/export_starsiege_missions.py) holds the decoded .mis object tree: vehicles
## (Hercs, tanks, flyers with team, loadout, pilot, script name), static shapes/turrets/interiors,
## nav markers, path markers, drop points and triggers, with "path" = the script path
## ("MissionGroup/patrolGroup/patrol1"). Starsiege missions are driven by their script, so the original
## .cs is executed by SSScript; this node provides the engine functions the scripts call (SSEngineFunctions)
## and raises the engine callbacks (vehicle::onDestroyed/onAttacked/onArrived, structure::*,
## trigger::onEnter, ...). Structures and nav points are built on every peer; units, script and rules
## run on the host.
##
## Collaborators: SSObjectTree (ids, paths, groups), SSScenery (structures, markers),
## SSStartPositions (where vehicles start), SSUnitDirector (AI units and order()),
## SSSensors (triggers, scan), SSScriptEvents (engine -> script callbacks),
## SSEngineFunctions (the script-callable engine functions).
##
## Turrets fire (SSTurret), interiors are placed by the map (map.json "interiors"), camera paths and
## object cameras are shown by SSCutscene (host screen). Approximations: scan (onScan) = player keeping
## a target locked within 600 m for 2 s; sound and HUD calls are recorded or ignored
## (see docs/formats/starsiege.md).

const PACK := "starsiege"
const TEAM_OF := {"yellow": 0, "red": 1, "blue": 2, "purple": 3, "neutral": 9}
const TEAM_TAGS := {"yellow": "IDSTR_TEAM_YELLOW", "red": "IDSTR_TEAM_RED", "blue": "IDSTR_TEAM_BLUE",
	"purple": "IDSTR_TEAM_PURPLE", "neutral": ""}
const CHECK_INTERVAL := 0.25
## Seconds after the player's death before the failed debriefing.
const PLAYER_DEATH_DEBRIEF_DELAY := 8.0
## Darkstar player manager: player numbers are object ids starting here.
const FIRST_PLAYER_NUM := 2049
## Debriefing codes stored in mission var 0 (as the ES runtimes do).
const CODE_SUCCESS := 1
const CODE_FAILED := 6
const STARTUP_SCRIPTS := ["scripts/missionStdLib.cs", "scripts/datFormation.cs"]

## Inventory calls of the last finished mission (read by the campaign provider).
static var last_inventory: Array = []

var vm: SSScript
var tree := SSObjectTree.new()
var units: SSUnitDirector
var sensors: SSSensors
var events: SSScriptEvents
var starts: SSStartPositions
var engine_functions: SSEngineFunctions
var cutscene: SSCutscene
var timers := []          # [time_left, code]
var inventory_changes := []
var sim_time := 0.0
var damage_factor := 3.0   # Starsiege damage -> ES scale (export_starsiege_gameplay.py)
var debug := false
var _player_dead_t := -1.0

## Views onto the object tree (kept for scripts and tests that read them directly).
var objs: Dictionary:
	get: return tree.objects
var by_path: Dictionary:
	get: return tree.by_path
var by_name: Dictionary:
	get: return tree.by_name
var player_objs: Dictionary:
	get: return tree.player_objs
var root_id: int:
	get: return tree.root_id
var formations: Dictionary:
	get: return units.formations


func _init() -> void:
	units = SSUnitDirector.new(self)
	sensors = SSSensors.new(self)
	events = SSScriptEvents.new(self)
	starts = SSStartPositions.new(self)
	engine_functions = SSEngineFunctions.new(self)


static func load_mission(id: String) -> Dictionary:
	id = id.trim_prefix("starsiege:").to_upper()
	var j = Assets.load_json("missions/%s.json" % id, PACK)
	return j if j is Dictionary else {}


## The campaign's starting vehicle (Human: Outrider Emancipator, Cybrid: Goad - *_planet_init.cs).
static func player_vehicle(mission: Dictionary) -> String:
	var v = mission.get("player_vehicle")
	if v is String and v != "":
		return v
	var c = Assets.load_json("campaigns/%s.json" % String(mission.get("campaign", "human")), PACK)
	if c is Dictionary and c.get("start_vehicle") is String:
		return String(c.start_vehicle)
	return ""


static func is_starsiege(mission: Dictionary) -> bool:
	return String(mission.get("pack", "")) == PACK


## Starsiege: the mission terrain in the engine map schema (set even when empty, as the launch always did).
static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.map = String(mission.get("map", ""))
	MissionRuntime.apply_world_to_config(config, mission)


## Starsiege: the remake's damage rule (the original's area handling is not traced).
static func make_area_rule() -> String:
	return BattleBounds.AREA_DAMAGE


## The campaign's starting vehicle with its standard loadout ({} when the campaign names none).
static func make_mission_herc(mission: Dictionary) -> Dictionary:
	var vehicle := player_vehicle(mission)
	if vehicle == "":
		return {}
	return {"vehicle": vehicle, "loadout": (Packs.vehicle(vehicle).get("loadout", []) as Array).duplicate()}


static func eng_to_orig(p: Vector3) -> Vector3:
	return Vector3(p.x, -p.z, p.y)


static func orig_to_eng(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, z, -y)


# ------------------------------------------------------------------ setup (all peers)

func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	battle = p_battle
	m = mission
	debug = "--ss-debug" in OS.get_cmdline_user_args()
	mission_vars = vars if vars.size() == 100 else _default_vars()
	var w = Assets.load_json("gameplay/weapons_engine.json", PACK)
	if w is Dictionary and w.has("damage_factor"):
		damage_factor = float(w.damage_factor)
	tree.build(m)
	SSScenery.build(self)
	refresh_nav()


## Called by SSScenery for each structure it builds.
func watch_structure(st: SSStructure, id: int) -> void:
	events.watch_structure(st, id)
	structures.append(st)


# ------------------------------------------------------------------ nav points (cockpit/HUD use nav_points + nav_index)

## Rebuilds nav_points from the enabled nav markers (setNavMarker) and selects the chosen one.
func refresh_nav() -> void:
	nav_points.clear()
	var selected := -1
	for id in tree.ids_of_kind("nav_marker"):
		var o: Dictionary = tree.objects[id]
		var node: Node3D = o.node
		if o.get("nav_on", false):
			if not node.is_in_group("nav_points"):
				node.add_to_group("nav_points")
			if o.get("nav_selected", false):
				selected = nav_points.size()
			nav_points.append(node.global_position if node.is_inside_tree() else node.position)
		elif node.is_in_group("nav_points"):
			node.remove_from_group("nav_points")
	nav_index = maxi(selected, 0)


# ------------------------------------------------------------------ player, units and script start (host)

func player_spawn(k: int) -> Transform3D:
	return starts.make_player_spawn(k)


## Where a vehicle placed at mission position `p` starts (SSStartPositions).
func make_start_position(p: Vector3, lift: float) -> Vector3:
	return starts.make_start_position(p, lift)


## Terrain height under p (p.y where there is no terrain).
func ground_height_at(p: Vector3) -> float:
	return starts.ground_height_at(p)


func formation_offset_local(k: int) -> Vector3:
	return Vector3(15.0 * k, 0, 20.0 * k)


## Starts the script: loads the libraries and mission script, registers the player squad, spawns the
## mission vehicles and raises the start callbacks in the original order.
func spawn_units() -> void:
	cutscene = SSCutscene.make(self)
	add_child(cutscene)
	_start_script_vm()
	_register_player_squad()
	for id in tree.objects.keys():
		var o: Dictionary = tree.objects[id]
		if o.kind in SSObjectTree.VEHICLE_KINDS and not o.has("player_num"):
			units.spawn_vehicle(id)
	events.raise_start_callbacks()
	flush_errors()


func _start_script_vm() -> void:
	vm = SSScript.new()
	vm.host = self
	var st = Assets.load_json("scripts/strings.json", PACK)
	if st is Dictionary:
		vm.strings = st
	vm.globals["$missionname"] = String(m.get("id", ""))
	for script in STARTUP_SCRIPTS:
		load_script(script)
	if m.get("script") != null:
		load_script(String(m.script))


## The engine's "playerSquad" group (player + squadmates, found by name from the scripts): the
## player vehicles Battle already spawned from the roster.
func _register_player_squad() -> void:
	var squad := tree.add_engine_object("playerSquad", "MissionGroup/playerSquad", "group", tree.root_id)
	var pnum := 0
	for nid in battle.vehicles:
		var h: Herc = battle.vehicles[nid]
		if h.has_meta("ai"):
			continue
		var path := "MissionGroup/playerSquad/player%d" % pnum
		var vid := tree.add_engine_object("player%d" % pnum, path, "herc", squad, {"team": "yellow", "script": ""})
		tree.objects[vid].node = h
		h.set_meta("ss_id", vid)
		watch_unit(h, vid)
		var player_num := FIRST_PLAYER_NUM + pnum
		tree.player_objs[player_num] = vid
		tree.objects[vid]["player_num"] = player_num
		pnum += 1


func load_script(rel: String) -> void:
	var p := Assets.path(rel, PACK)
	if not FileAccess.file_exists(p):
		return
	vm.load_source(FileAccess.get_file_as_string(p), rel.get_file())


func watch_unit(h: Herc, id: int) -> void:
	events.watch_unit(h, id)


## Calls `<script>::<kind>::<event>` if the mission defines it, else `<kind>::<event>` (SSScriptEvents).
func raise_object_callback(id: int, kind: String, event: String, args: Array) -> void:
	events.raise_object_callback(id, kind, event, args)


## The player's vehicle was destroyed: the failed debriefing follows PLAYER_DEATH_DEBRIEF_DELAY later.
func note_player_death() -> void:
	_player_dead_t = sim_time


## Unit deaths are reported to the script through the Herc signals instead (see watch_unit).
func on_unit_destroyed(_h: Herc) -> void:
	pass


# ------------------------------------------------------------------ per-frame (host)

func _physics_process(delta: float) -> void:
	if _over or not multiplayer.is_server() or vm == null:
		return
	sim_time += delta
	_run_due_timers(delta)
	if _over:
		return
	var dt := make_rules_step(delta, CHECK_INTERVAL)
	if dt <= 0.0:
		flush_errors()
		return
	units.update()
	sensors.check_triggers()
	sensors.check_scan(dt)
	if _player_dead_t >= 0.0 and sim_time - _player_dead_t > PLAYER_DEATH_DEBRIEF_DELAY:
		debrief(false, "Your vehicle has been destroyed.")
	flush_errors()


## Runs the schedule() timers `delta` seconds on (a skipped cut-scene fast-forwards them).
func advance_timers(delta: float) -> void:
	_run_due_timers(delta)
	flush_errors()


func is_mission_over() -> bool:
	return _over


## schedule() timers: runs the code of every timer that ran out (stops once the mission ended).
func _run_due_timers(delta: float) -> void:
	var due := []
	for t in timers:
		t[0] -= delta
		if t[0] <= 0.0:
			due.append(t)
	for t in due:
		timers.erase(t)
		vm.eval_string(String(t[1]))
		if _over:
			return


# ------------------------------------------------------------------ mission end

## True when every primary MissionBriefObjective has the "completed" status (and there is one).
func objectives_done() -> bool:
	var primary := _brief_objectives().filter(func(k) -> bool: return SSScript.truthy(vm.get_field(k, "isprimary")))
	return not primary.is_empty() and primary.all(_is_objective_completed)


## The objectives panel's lines: every MissionBriefObjective's short text, done when its status reads completed.
func make_objective_lines() -> Array:
	var out := []
	if vm == null:
		return out
	for k in _brief_objectives():
		var ob: Dictionary = vm.objects[k]
		out.append({"text": SSScript.to_str(ob.get("shorttxt", k)), "done": _is_objective_completed(k)})
	return out


## Ids of the script's MissionBriefObjective objects.
func _brief_objectives() -> Array:
	return vm.objects.keys().filter(func(k) -> bool:
		return String((vm.objects[k] as Dictionary).get("__type", "")).to_lower() == "missionbriefobjective")


## True when objective `k`'s status is the campaign's "completed" string (IDSTR_OBJ_COMPLETED).
func _is_objective_completed(k: Variant) -> bool:
	var done := String(vm.strings.get("IDSTR_OBJ_COMPLETED", "Completed")).to_lower()
	return SSScript.to_str(vm.get_field(k, "status")).to_lower() == done


func debrief(success: bool, why := "") -> void:
	if _over:
		return
	log_debug("DEBRIEF success=%s %s" % [success, why])
	var txt := String(m.get("debrief_success" if success else "debrief_fail", ""))
	if why != "":
		txt = why + "\n" + txt
	end_mission(success, CODE_SUCCESS if success else CODE_FAILED, txt)


## Starsiege: the campaign provider reads the mission's inventory calls after the battle.
func apply_end(_success: bool) -> void:
	last_inventory = inventory_changes.duplicate()


## Starsiege: the script's own debriefing (debrief_success / debrief_fail), as given.
func make_debriefing_text(_code: int, text: String) -> String:
	return text


# ------------------------------------------------------------------ diagnostics

func log_debug(msg: String) -> void:
	if debug:
		print("[ss %.1f] %s" % [sim_time, msg])


func log_echo(args: Array) -> void:
	if debug:
		print("[ss] ", args)


func flush_errors() -> void:
	if vm == null or vm.errors.is_empty():
		return
	for e in vm.errors:
		print_verbose("[starsiege script] ", e)
		if debug:
			print("[starsiege script] ", e)
	vm.errors.clear()


# ------------------------------------------------------------------ SSScript host interface

## Script value -> object id (ids, "MissionGroup/a/b" paths, bare names, player numbers).
func ss_resolve(v) -> int:
	return tree.resolve(v)


func ss_builtin(name: String, a: Array):
	return engine_functions.call_function(name, a)


func ss_declared(_type: String, _name: String, _fields: Dictionary) -> void:
	pass


func ss_get_field(_k: String, _f: String):
	return null


## Objective status changes are announced like the original HUD did.
func ss_field_changed(k: String, f: String, v) -> void:
	if f == "status" and vm and vm.objects.has(k):
		var short := SSScript.to_str(vm.objects[k].get("shorttxt", k))
		battle.fx("message", ["Objective %s: %s" % [SSScript.to_str(v), short], 5.0], true)


## Deprecated: use tree.position_of (kept for tests/test_starsiege_mission.gd).
func _obj_pos(id: int) -> Vector3:
	return tree.position_of(id)
