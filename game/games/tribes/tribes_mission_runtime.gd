class_name TribesMissionRuntime
extends MissionRuntimeBase
## Runs a Tribes (1998) or Tribes 2 (2001) single-player mission (the training missions) inside a Battle, on foot
## (docs/formats/tribes.md section 8, tribes2.md section 8). The importer copies the mission (.mis) and its
## scripts from the user's disc into gamedata/<pack>/missions/ (tools/export_tribes_missions.py); they run here
## as written in the shared Darkstar script runtime (DarkstarScript; Tribes in the Darkstar dialect, Tribes 2
## in TorqueScript), and this node is the game engine under them:
##   the .mis builds the object tree (TribesSimObjects: groups, drop points, shapes, items, triggers, paths);
##   the game's function table (Tribes1Functions / Tribes2Functions) answers the engine functions;
##   TribesActors keeps the clients and their soldiers (the player's Infantry, the AI's bots);
##   TribesContacts raises touches (items, switches, flags), triggers and the mission area;
##   TribesSchedules runs the script timers.
##   TribesMissionOutput says and shows it: the radio (training lines with their voice), the objective lines,
##   the waypoint (nav point), messages.
## The mission ends through the game's end call (debrief). Host only: the training missions are single player.
## Subclasses: Tribes1MissionRuntime, Tribes2MissionRuntime.

const PACKS := ["tribes", "tribes2"]
const MISSIONS_DIR := "missions"
const INDEX_FILE := "missions/_index.json"
const DATABLOCKS_FILE := "missions/datablocks.json"
## Seconds between two contact / trigger / mission-area checks.
const CHECK_INTERVAL := 0.1

## Schedules due in one frame run at most this many rounds (events scheduling events at 0 ms).
const MAX_SCHEDULE_ROUNDS := 64
const CODE_SUCCESS := 1
## The remake's damage per unit of Tribes damage (weapons_infantry.json: Tribes damage x3000).
const TRIBES_DAMAGE_SCALE := 3000.0
const CODE_FAILED := 6

var pack := ""
var vm: DarkstarScript
var sim := TribesSimObjects.new()
var schedules := TribesSchedules.new()
var functions: DarkstarFunctionTable
var items: TribesItems
var actors: TribesActors
var contacts: TribesContacts
## The models of the mission's items (TribesItemModels).
var item_models: TribesItemModels
var datablocks := {}            # lower name -> {type, name, fields}
var datablock_ids := {}         # lower name -> object id
var sim_time := 0.0
## Radio lines, objectives, the waypoint and messages.
var output: TribesMissionOutput
## Script warnings that are not errors (method calls on objects that do not exist: the originals print them).
var warnings: Array[String] = []
## Every script error since the mission started (flush_errors keeps them here).
var error_log: Array[String] = []
var debug := false
var _scripts_dir_files := {}    # lower file name -> file name


# ------------------------------------------------------------------ missions

## The training missions of `p`: [{id, name, order, map, mission, scripts, briefing, armor}] by order.
static func list_missions(p: String) -> Array:
	var j = Assets.load_json(INDEX_FILE, p)
	if not (j is Array):
		return []
	var out: Array = (j as Array).duplicate(true)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.get("order", 0)) < int(b.get("order", 0)))
	return out


## "tribes:1_Welcome" / "tribes2:Training1" -> the mission definition ({} when it is not installed).
static func load_mission(qualified: String) -> Dictionary:
	if not qualified.contains(":"):
		return {}
	var p := qualified.get_slice(":", 0)
	var id := qualified.get_slice(":", 1).to_lower()
	if not p in PACKS:
		return {}
	for e in list_missions(p):
		if String(e.get("id", "")).to_lower() == id:
			var d: Dictionary = e.duplicate(true)
			d["pack"] = p
			d["runtime"] = "tribes"
			d["mission_name"] = "%s:%s" % [p, e.id]
			return d
	return {}


static func is_tribes(mission: Dictionary) -> bool:
	return String(mission.get("runtime", "")) == "tribes"


static func is_mission_name(mission_name: String) -> bool:
	return mission_name.get_slice(":", 0) in PACKS and mission_name.contains(":")


## Tribes: the mission's terrain map only (no Earthsiege world).
static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.map = String(mission.get("map", ""))


## The armour a training mission starts the player in (on foot; its loadout is the armour's own).
static func make_mission_herc(mission: Dictionary) -> Dictionary:
	return {"vehicle": String(mission.get("armor", "")), "loadout": []}


## Tribes: the mission scripts own their area (leaveMissionArea callbacks).
static func make_area_rule() -> String:
	return BattleBounds.AREA_NONE


## Training missions always put the player in their armour.
static func is_mission_herc_forced() -> bool:
	return true


## AI followers keep the Earthsiege formation table's slots (as before the runtimes were split).
func formation_offset_local(k: int) -> Vector3:
	return MissionRuntime.make_es1_formation_offset("mech", 0, k, 0.0)


# ------------------------------------------------------------------ setup (host)

func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	battle = p_battle
	m = mission
	pack = String(m.get("pack", "tribes"))
	debug = "--tribes-debug" in OS.get_cmdline_user_args()
	mission_vars = vars if vars.size() == MISSION_VAR_COUNT else _default_vars()
	var j = Assets.load_json(DATABLOCKS_FILE, pack)
	datablocks = j if j is Dictionary else {}
	items = TribesItems.new(pack, datablocks)
	actors = TribesActors.new(self)
	contacts = TribesContacts.new(self)
	item_models = TribesItemModels.new(self)
	var interaction := InfantryInteraction.of(battle)
	if interaction:
		interaction.add_provider(contacts.make_interact_offer)
	output = TribesMissionOutput.new(self)
	vm = DarkstarScript.new()
	vm.dialect = _make_dialect()
	vm.host = self
	functions = _make_functions()
	_index_scripts_dir()
	_build_datablock_objects()
	_prepare_globals()
	load_mission_file(String(m.get("mission", "")))
	flush_errors()


## Subclass: the script dialect.
func _make_dialect() -> int:
	return DarkstarLexer.Dialect.DARKSTAR


## Subclass: the game's engine function table.
func _make_functions() -> DarkstarFunctionTable:
	return DarkstarStdLib.new()


## Subclass: globals and objects the engine sets up before the mission file runs.
func _prepare_globals() -> void:
	pass


## Subclass: the namespace parents of a datablock (Tribes 2 links the class chain).
func _link_datablock(_name: String, _record: Dictionary) -> void:
	pass


func _build_datablock_objects() -> void:
	for key in datablocks:
		var d: Dictionary = datablocks[key]
		var id := sim.create(String(d.get("type", "")), String(d.get("name", key)), 0, d.get("fields", {}))
		sim.objects[id]["is_datablock"] = true
		datablock_ids[key] = id
		_link_datablock(key, d)


func _index_scripts_dir() -> void:
	var dir := Assets.path(MISSIONS_DIR + "/scripts", pack)
	for f in DirAccess.get_files_at(dir):
		_scripts_dir_files[f.to_lower()] = f


## Runs the mission file (missions/<id>.mis): it builds the object tree and execs the mission's scripts.
func load_mission_file(rel: String) -> void:
	var p := Assets.path("%s/%s" % [MISSIONS_DIR, rel], pack)
	if not FileAccess.file_exists(p):
		push_error("TribesMissionRuntime: mission file missing: " + p)
		return
	vm.load_source(FileAccess.get_file_as_string(p), rel.get_file())


## exec("name"): a mission script copied by the importer (missions/scripts/, any letter case, ".cs" optional).
## The base game scripts (game.cs, objectives.cs ...) are this engine's part in the remake: false for them.
func exec_script(script_name: String) -> bool:
	var f := script_name.replace("\\", "/").get_file().to_lower()
	if not f.ends_with(".cs"):
		f += ".cs"
	if not _scripts_dir_files.has(f):
		log_debug("exec %s: base script, provided by the engine" % script_name)
		return false
	var rel := "%s/scripts/%s" % [MISSIONS_DIR, _scripts_dir_files[f]]
	vm.load_source(FileAccess.get_file_as_string(Assets.path(rel, pack)), String(_scripts_dir_files[f]))
	return true


# ------------------------------------------------------------------ player and start (host)

## Subclass: where the player starts (engine frame).
func player_spawn(_k: int) -> Transform3D:
	return Transform3D.IDENTITY


## Binds the players' soldiers to their clients, then the game starts (subclass _start_game).
func spawn_units() -> void:
	for h in battle.vehicles.values():
		if h is Infantry and (h as Infantry).owner_peer > 0 and not h.has_meta("bot_id"):
			actors.bind_human(h as Infantry)
	_start_game()
	output.flush()
	flush_errors()


func _start_game() -> void:
	pass


## The battle team of a script team (Tribes 2 numbers its teams from 1).
func make_battle_team(script_team: int) -> int:
	return script_team


func make_script_team(battle_team: int) -> int:
	return battle_team


## A soldier of this mission died (TribesActors); subclass: the game's kill callbacks.
func on_player_killed(_player: int, _killer: int) -> void:
	pass


# ------------------------------------------------------------------ contacts (TribesContacts; subclasses answer)

## True for an item someone carries (it is not lying in the world).
func is_carried(_id: int) -> bool:
	return false


## True for a shape whose touch the game reports (a script callback exists for it).
func is_touchable(_id: int) -> bool:
	return false


func on_item_touched(_item: int, _player: int) -> void:
	pass


func on_shape_touched(_shape: int, _player: int) -> void:
	pass


func on_trigger(_trigger: int, _player: int, _entered: bool) -> void:
	pass


func on_mission_area(_player: int, _inside: bool) -> void:
	pass


## Subclass: the game's own per-frame work (respawns, AI tasks).
func _update_game(_delta: float) -> void:
	pass


# ------------------------------------------------------------------ objects (both games)

func delete_object(id: int) -> void:
	sim.delete(id)


## Item::hide / ShapeBase.hide: a hidden item cannot be picked up, a hidden shape not touched.
func hide_object(id: int, hidden: bool) -> void:
	if sim.exists(id):
		sim.objects[id]["hidden"] = hidden


## A soldier or a client's (also a vehicle's) moves to `p` (engine frame); another object's record does.
func move_object(id: int, p: Vector3) -> void:
	var node = sim.get_record(actors.player_of(id) if actors.player_of(id) > 0 else id).get("node")
	if node is Infantry and is_instance_valid(node):
		(node as Infantry).global_position = p
		(node as Infantry).velocity = Vector3.ZERO
	elif node is Node3D and is_instance_valid(node):
		(node as Node3D).global_position = p
	elif sim.exists(id):
		sim.objects[id].fields["position"] = DarkstarStdLib.make_vector_string(TribesSimObjects.to_original(p))


## The damage level of a soldier or vehicle as a share of its health (0 = unhurt, 1 = destroyed).
func damage_level(id: int) -> float:
	var h := _damageable(id)
	return 1.0 - h.integrity if h else 0.0


func set_damage_level(id: int, level: float) -> void:
	var s := actors.soldier_of(id)
	if s == null or not s.alive:
		return
	var c: Dictionary = s.components[0]
	c.hp = float(c.max) * clampf(1.0 - level, 0.0, 1.0)
	s.integrity = HercDamage.integrity_of(s.components)


## Damage (the remake's units) to a soldier or a vehicle the script means.
func apply_damage(id: int, amount: float) -> void:
	var h := _damageable(id)
	if h and h.alive:
		KillText.apply_caused_hit(h, [0.0, amount, null, h.global_position], KillText.CAUSE_SCRIPTED)


func _damageable(id: int) -> Herc:
	var s := actors.soldier_of(id)
	if s:
		return s
	var node = sim.get_record(id).get("node")
	return node as Herc if node is Herc and is_instance_valid(node) else null


# ------------------------------------------------------------------ per frame (host)

func _physics_process(delta: float) -> void:
	if _over or vm == null or not multiplayer.is_server():
		return
	sim_time += delta
	run_due_schedules()
	if _over:
		return
	actors.update(delta)
	_update_game(delta)
	if _over:
		return
	if make_rules_step(delta, CHECK_INTERVAL) > 0.0:
		contacts.update()
		item_models.update()
	output.flush()
	flush_errors()


## Runs every script timer that is due (and those they schedule for now).
func run_due_schedules() -> void:
	for _round in MAX_SCHEDULE_ROUNDS:
		var due := schedules.take_due(sim_time)
		if due.is_empty():
			return
		for e in due:
			_run_event(e)
			if _over:
				return


func _run_event(e: Dictionary) -> void:
	var object := int(e.get("object", 0))
	if object != 0 and not sim.exists(object):
		return
	match String(e.kind):
		"code":
			vm.eval_string(String(e.code))
		"call":
			vm.call_fn(String(e.name), e.args)
		"method":
			vm.call_method(object, String(e.name), e.args)


## Runs the game for `seconds` more script time at once (tests: a scripted fast-forward).
func advance(seconds: float) -> void:
	sim_time += seconds
	run_due_schedules()
	output.flush()
	flush_errors()


func is_mission_over() -> bool:
	return _over


# ------------------------------------------------------------------ objectives (TribesMissionOutput)

## Objective line `index` (0-based) now reads `text`; a changed line is announced (Tribes 1 announces its goal).
func set_objective(index: int, text: String) -> void:
	if output.store_objective(index, text) and output.objectives[index] != "":
		output.show_message("Objective: " + output.objectives[index])

## The objectives panel's lines: the objective page / HUD lines the scripts set (never marked done: the
## originals rewrite the lines instead).
func make_objective_lines() -> Array:
	var out := []
	if output == null:
		return out
	for line in output.objectives:
		if str(line).strip_edges() != "":
			out.append({"text": str(line), "done": false})
	return out


# ------------------------------------------------------------------ mission end

func debrief(success: bool, text := "") -> void:
	if _over:
		return
	output.flush()
	log_debug("DEBRIEF success=%s %s" % [success, text])
	var summary := text if text != "" else ("Training complete." if success else "Training failed.")
	end_mission(success, CODE_SUCCESS if success else CODE_FAILED, TribesText.make_plain(summary))


## Tribes: no wingmen to call the end; the training summary is the whole debriefing.
func apply_end(_success: bool) -> void:
	pass


func make_debriefing_text(_code: int, text: String) -> String:
	return text


# ------------------------------------------------------------------ DarkstarScript host interface

func ss_resolve(v) -> int:
	return sim.resolve(v)


func ss_builtin(fn_name: String, a: Array):
	return functions.call_function(fn_name, a)


func ss_get_field(k: String, f: String):
	if not k.is_valid_int():
		return null
	return actors.make_field(int(k), f)


func ss_field_changed(k: String, f: String, v) -> void:
	if k.is_valid_int() and sim.exists(int(k)):
		sim.objects[int(k)].fields[f] = v
		actors.apply_field(int(k), f, v)


func ss_declared(_type: String, _name: String, _fields: Dictionary) -> void:
	pass


## `new` / `instant` / `datablock`: an object of the mission tree or made by a script (subclass extends).
func ss_new_object(spec: Dictionary) -> int:
	var parent := int(spec.parent)
	if parent == 0 and sim.root_id == 0 and String(spec.class).to_lower() == "simgroup":
		var root := sim.create(spec.class, spec.name, 0, spec.fields)
		sim.root_id = root
		return root
	return sim.create(String(spec.class), String(spec.name), parent, spec.fields)


# ------------------------------------------------------------------ diagnostics

func log_debug(msg: String) -> void:
	if debug:
		print("[tribes %.1f] %s" % [sim_time, msg])


func add_warning(msg: String) -> void:
	if warnings.size() < 200 and not msg in warnings:
		warnings.append(msg)
		log_debug("warning: " + msg)


func flush_errors() -> void:
	if vm == null or vm.errors.is_empty():
		return
	for e in vm.errors:
		error_log.append(e)
		print_verbose("[tribes script] ", e)
		if debug:
			print("[tribes script] ", e)
	vm.errors.clear()
