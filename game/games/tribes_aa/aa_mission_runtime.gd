class_name AAMissionRuntime
extends MissionRuntimeBase
## Runs a Tribes: Aerial Assault mission inside a Battle (docs/formats/aerial_assault.md, "Game side").
##
## The disc's mission logic lives in the PS2 executable (campaign_logic / cNN_logic classes); tools/aa_logic.py reads it into
## campaign/logic.json (docs/formats/aerial_assault.md, "Mission logic"):
##   arena missions 1..5   the player's score (kills x points per kill) must reach the mode's limit against respawning bots;
##   scripted missions     the original state machine (AAScriptVM, MissionScript with the AAScriptHost senses): per state the voice prompts, the timers, the waves
##                         (the DERM_ tagged points of the map, BioDerm soldiers), the allies (BOT_ points), the orders to
##                         both sides, the failure rules (the player's death, running out of time, straying from the allies
##                         or the generators, losing the generators or the allies) and the success rule. This runtime is
##                         the machine's host (the vm_* methods): it senses the battle, spawns and orders the soldiers and
##                         plays the prompts (audio/training/NNN.ogg: the executable's ids are indexes of the TRAINING bank).
## Missions without a logic record (the trainings, or a pack imported before it) play the fallback rule:
##   reach and destroy   the targets are the map's generators (the enemy's: team != 0 when the map has any); with no
##                       generator the mission's waypoints, to be reached in order; with neither, survive
##                       SURVIVE_SECONDS. Destroying every generator (TribesBase.object_destroyed) or reaching the
##                       last waypoint ends the mission as won; the player's death loses it (Battle).
## The objectives panel shows the mission's own notes (OBJECTIVES.BIN text) followed by the progress line.
## The player is a Tribes 2 soldier (the look-alike armour); stations, generators and turrets are Tribes 2 base
## equipment (TribesBase.SPEC_PACK_FALLBACK). The player and the allies wear the animated Aerial Assault soldier bodies, the
## enemy waves the Tribes 2 Bioderm bodies (InfantryCatalog), when the packs have them.

const PACK := "tribes_aa"
const RUNTIME_KEY := "tribes_aa"
const ARMOR := "tribes2:MEDIUM"
const CHECK_INTERVAL := 0.25
const REACH_METRES := 15.0
const SURVIVE_SECONDS := 300.0
const SPAWN_LIFT := 1.0
const TARGET_MATCH_METRES := 3.0
const PLAYER_TEAM := 0
const GOAL_GENERATORS := "generators"
const GOAL_WAYPOINTS := "waypoints"
const GOAL_SURVIVE := "survive"
const GOAL_SCRIPT := "script"
const GOAL_ARENA := "arena"
const ENEMY_TEAM := 1
const SOLDIER_SKILL := 0.5
const OBJECTIVE_REFRESH := 3.0
const ARENA_RESPAWN_SECONDS := 4.0
const DESTROY_MATCH_METRES := 4.0
const ORDER_REFRESH := 1.0               # seconds between the soldiers' order updates (scripted missions)
const SWITCH_METRES := 15.0              # reaching the control switch (the original needs the player to press it)
const BOARD_METRES := 4.0                # the vehicle pad's reach: there is no vehicle to board, reaching the pad counts
const END_DELAY := 2.0                   # seconds between the closing prompt and the end of the mission (campaign_logic: 2.0)
const WAYPOINT_ID := "wp:%d"
const BIG_DISTANCE := AAScriptHost.BIG_DISTANCE
## The closing text of each fallback goal (the player's win), for the debriefing.
const WIN_TEXT := {GOAL_GENERATORS: "Generators destroyed. Mission complete.", GOAL_WAYPOINTS: "Final waypoint reached. Mission complete.",
	GOAL_SURVIVE: "Mission complete.", GOAL_ARENA: "Score limit reached. Mission complete."}
const TURRET_TAGS := ["TURRET1", "TURRET2", "TURRET3", "TURRET4", "TURRET5"]
const GENERATOR_TAGS := ["GEN1", "GEN2"]
const ORDER_META := "aa_order"
## campaign_logic::OrderBots task codes the remake plays: 1 / 3 roam to a place, 2 defend it, 7 deathmatch, 8 antagonize;
## any other task attacks the named object.
const TASK_DEATHMATCH := 7
const TASK_ANTAGONIZE := 8
const TASK_KINDS := {1: AIOrder.MOVE, 3: AIOrder.MOVE, 2: AIOrder.DEFEND}
const LOOK_MOUSE_SPEED := 300.0          # mouse speed (pixels / s) that counts as full look strength
## The training lessons' inputs -> the remake's actions (vm_input).
const INPUT_ACTIONS := {"move_forward": "throttle_up", "move_back": "throttle_down", "strafe_left": "turn_left",
	"strafe_right": "turn_right", "jump": "ascend", "jet": "jet", "fire": "fire_group_1", "grenade_throw": "grenade_throw",
	"mine_drop": "mine_drop", "pack_use": "pack_use", "weapon_next": "weapon_next", "interact": "interact",
	"scope_zoom": "scope_zoom", "target_next": "target_next", "target_nearest": "target_nearest"}

var map := {}
var goal := GOAL_SURVIVE
var targets: Array[Dictionary] = []     # {pos: Vector3}: the generators or the waypoints of the fallback goal
var elapsed := 0.0
## Waypoints reached so far, in order (0 outside the waypoints goal).
var waypoint_index: int:
	get:
		var n := 0
		while goal == GOAL_WAYPOINTS and n < targets.size() and kit.objectives.get_objective(WAYPOINT_ID % n).is_done():
			n += 1
		return n
var _base_hooked := false
var logic := {}                          # this mission's record of campaign/logic.json ({} = fallback rule)
var vm: AAScriptVM                       # scripted missions: the state machine (MissionScript with the Aerial Assault host)
var kills := 0                           # enemy soldiers killed
var enemies: Array = []                  # spawned enemy InfantryBot brains
var allies: Array = []
var _spawn_points: Array = []
var _destroyed: Array[Vector3] = []      # positions of the base objects destroyed so far
var _deployed := 0                       # deploy packs placed
var _switch := false                     # the player reached the control switch
var _waypoints := {}                     # tag -> true: the waypoints the script shows
var _texts := {}                         # CAMPAIGN.BIN strings the scripts show (number -> text)
var _objective_text := ""                # the lesson text a training step printed (PrintObjective)
var _generators_down := {}              # index in `targets` -> true: the fallback goal's generators destroyed so far
var _sink: AAMissionSink
var _world: AAMissionWorld
var _refresh := 0.0
var _respawns: Array[float] = []         # arena: seconds until each missing bot returns


static func is_aa(mission: Dictionary) -> bool:
	return String(mission.get("runtime", "")) == RUNTIME_KEY


static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.map = String(mission.get("map", ""))
	config["infantry_pack"] = ARMOR.get_slice(":", 0)     # the soldiers are Tribes 2 armour (Tribes 1 may be installed too)
	var bodies := InfantryCatalog.make_aa_bodies(ARMOR)
	if not bodies.is_empty():
		for peer in config.get("roster", {}):
			config.roster[peer]["infantry_armor"] = ARMOR
			config.roster[peer]["infantry_body"] = str(bodies[0].id)


static func make_mission_herc(_mission: Dictionary) -> Dictionary:
	return {"vehicle": ARMOR, "loadout": []}


static func is_mission_herc_forced() -> bool:
	return true


## Which fallback goal a map gets: "generators", else "waypoints", else "survive".
static func make_goal(m: Dictionary) -> String:
	if not _make_generators(m).is_empty():
		return GOAL_GENERATORS
	if not (m.get("waypoints", []) as Array).is_empty():
		return GOAL_WAYPOINTS
	return GOAL_SURVIVE


## Generator positions the player must destroy: the enemy's (team != PLAYER_TEAM), else all of them.
static func _make_generators(m: Dictionary) -> Array[Vector3]:
	var all: Array[Vector3] = []
	var enemy: Array[Vector3] = []
	for s in m.get("stations", []):
		if str(s.get("kind", "")) != "generator":
			continue
		var p: Array = s.pos
		var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
		all.append(v)
		if int(s.get("team", -1)) != PLAYER_TEAM:
			enemy.append(v)
	return enemy if not enemy.is_empty() else all


static func _make_waypoints(m: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for w in m.get("waypoints", []):
		var p: Array = w.pos
		out.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	return out


func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	super.setup(p_battle, mission, vars)
	var voice: AudioStreamPlayer = null
	map = MapBuilder.load_map(String(m.get("map", "")))
	logic = AAScript.make_logic(String(m.get("id", "")))
	goal = make_goal(map)
	if str(logic.get("type", "")) == AAScript.TYPE_ARENA:
		goal = GOAL_ARENA
	elif logic.has("script") and str(logic.get("type", "")) in [AAScript.TYPE_SCRIPTED, AAScript.TYPE_TRAINING]:
		goal = GOAL_SCRIPT
		vm = AAScriptVM.new(self, logic.script)
		_spawn_points = AAScript.make_spawn_points(map)
		_texts = AAScript.make_texts()
		voice = AudioStreamPlayer.new()
		add_child(voice)
	_sink = AAMissionSink.new(battle, voice)
	_world = AAMissionWorld.new(self, _sink)
	kit.announcer = MissionAnnouncer.new(_sink, MissionAnnouncer.Discipline.REPLACE_WAITING)
	kit.ender = MissionEnder.new(end_mission, _sink.is_voice_playing)
	match goal:
		GOAL_GENERATORS:
			for p in _make_generators(map):
				targets.append({"pos": p})
		GOAL_WAYPOINTS:
			for p in _make_waypoints(map):
				targets.append({"pos": p})
	_build_objectives()
	_build_markers()


## The fallback goals and the arena's score limit as objectives: destroy every generator, reach the waypoints in order
## (each starts when the one before is reached), survive, score.
func _build_objectives() -> void:
	match goal:
		GOAL_GENERATORS:
			var ids: Array[String] = []
			for i in targets.size():
				ids.append(AAMissionWorld.GENERATOR_ID % i)
			kit.objectives.apply_add(DestroyObjective.new(GOAL_GENERATORS, "", ids))
		GOAL_WAYPOINTS:
			for i in targets.size():
				var reach := ReachObjective.new(WAYPOINT_ID % i, "", AreaShape.make_sphere(targets[i].pos, REACH_METRES))
				if i > 0:
					reach.state = Objective.State.PENDING
				kit.objectives.apply_add(reach)
		GOAL_SURVIVE:
			kit.objectives.apply_add(SurviveObjective.new(GOAL_SURVIVE, "", SURVIVE_SECONDS))
		GOAL_ARENA:
			kit.objectives.apply_add(ScoreObjective.new(GOAL_ARENA, "", PLAYER_TEAM, int(logic.get("score_limit", 1))))


func is_generator_down(index: int) -> bool:
	return _generators_down.has(index)


func _build_markers() -> void:
	for i in targets.size():
		var n := Marker3D.new()
		n.position = targets[i].pos
		n.set_meta("label", str(i + 1))
		n.add_to_group("nav_points")
		nav_points.append(n.position)
		battle.add_child(n)


## The first infantry start of the player's team (the first start of the map without one), lifted off the ground.
func player_spawn(_k: int) -> Transform3D:
	return make_player_start(battle, map)


## The player's start in map `m` built under `parent`: the first infantry start of his team (else the first start), placed
## as the map builder places every start (a drop point's file height is not trusted: onto the terrain, kept only in a base).
static func make_player_start(parent: Node3D, m: Dictionary) -> Transform3D:
	var best := {}
	for s in m.get("spawns", []):
		if str(s.get("kind", "")) != "infantry":
			continue
		if best.is_empty():
			best = s
		if int(s.get("team", 0)) == PLAYER_TEAM:
			best = s
			break
	if best.is_empty():
		return Transform3D(Basis.IDENTITY, Vector3(0, float(m.get("ground_y", 0.0)) + SPAWN_LIFT, 0))
	return MapBuilder.make_spawn_transform(parent, best)


func _physics_process(delta: float) -> void:
	if _over or battle == null or not multiplayer.is_server():
		return
	elapsed += delta
	# The rules run every CHECK_INTERVAL on the time gathered since the last check, so script timers keep real time.
	var step := make_rules_step(delta, CHECK_INTERVAL)
	if step <= 0.0:
		return
	_hook_base()
	match goal:
		GOAL_SCRIPT:
			_step_script(step)
		GOAL_ARENA:
			_step_arena(step)
		_:
			_tick_objectives(step)


## TribesBase is built after the runtime: connect to it on the first tick it exists.
func _hook_base() -> void:
	if _base_hooked or not (goal == GOAL_GENERATORS or goal == GOAL_SCRIPT):
		return
	var base := TribesBase.of(battle)
	if base == null:
		return
	_base_hooked = true
	base.object_destroyed.connect(_on_object_destroyed)
	base.deployed.connect(func(_o: TribesBaseObject) -> void: _deployed += 1)


func _on_object_destroyed(obj: TribesBaseObject, _killer: Node) -> void:
	if _over:
		return
	if goal == GOAL_SCRIPT:
		_destroyed.append(obj.global_position)
		if obj.kind == TribesBaseObject.KIND_TURRET and vm != null:
			vm.notify("turret_destroyed")
		return
	if obj.kind != TribesBaseObject.KIND_GENERATOR:
		return
	for i in targets.size():
		if not _generators_down.has(i) and (targets[i].pos as Vector3).distance_to(obj.global_position) < TARGET_MATCH_METRES:
			_generators_down[i] = true
			break
	_tick_objectives(0.0)


## Moves the fallback goal's objectives on by `dt` seconds; a waypoint reached starts the next, the goal done wins.
func _tick_objectives(dt: float) -> void:
	kit.objectives.apply_tick(_world, dt)
	if goal == GOAL_WAYPOINTS and waypoint_index != nav_index:
		nav_index = waypoint_index
		var next := kit.objectives.get_objective(WAYPOINT_ID % nav_index)
		if next != null:
			next.apply_activate()
	if kit.objectives.is_complete():
		kit.ender.apply_verdict(MissionVerdict.make_win(CODE_SUCCESS, WIN_TEXT[goal]))
		kit.ender.apply_tick(0.0)


# ------------------------------------------------------------------ scripted missions (campaign/logic.json)

## One rules tick of a scripted mission: the soldiers' orders, the closing prompt, the player's death, then the state machine.
func _step_script(delta: float) -> void:
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = ORDER_REFRESH
		_aim_soldiers()
	if kit.ender.has_verdict():
		kit.ender.apply_tick(delta)
		return
	kit.announcer.apply_tick(delta)
	var p: Herc = battle.player
	if p != null and is_instance_valid(p) and not _switch and _near_tag("SWITCH1", SWITCH_METRES, p):
		_switch = true
	if p != null and is_instance_valid(p) and not p.alive and int(vm.program.get("death", 0)) > 0:
		vm.fail(int(vm.program.get("death", 0)))
		return
	vm.step(delta)


func _spawn_wave(wave: int) -> void:
	for e in AAScript.make_wave_soldiers(_spawn_points, ENEMY_TEAM, wave):
		var b := _spawn_soldier(ENEMY_TEAM, str(e.size), e.pos)
		if b:
			enemies.append(b)


## Allies of wave `wave` at their BOT_ points.
func _spawn_allies(wave: int) -> void:
	for e in AAScript.make_wave_soldiers(_spawn_points, PLAYER_TEAM, wave):
		var b := _spawn_soldier(PLAYER_TEAM, str(e.size), e.pos)
		if b:
			allies.append(b)


# ------------------------------------------------------------------ the host of the state machine (AAScriptVM)

func vm_alive(team: int) -> int:
	return count_alive(enemies if team == ENEMY_TEAM else allies)


## Distance from the player to the nearest object tagged `tag`; 0 when the map has none (a missing object never blocks).
func vm_distance(tag: String) -> float:
	var p: Herc = battle.player
	if p == null or not is_instance_valid(p):
		return BIG_DISTANCE
	var best := INF
	for at in _tag_positions(tag):
		best = minf(best, p.global_position.distance_to(at))
	return 0.0 if best == INF else best


func vm_ally_distance() -> float:
	var p: Herc = battle.player
	var best := BIG_DISTANCE
	if p == null or not is_instance_valid(p):
		return best
	for b in allies:
		if is_instance_valid(b) and is_instance_valid(b.soldier) and b.soldier.alive:
			best = minf(best, p.global_position.distance_to(b.soldier.global_position))
	return best


## The closest living enemy to the object tagged `tag`.
func vm_enemy_distance(tag: String) -> float:
	var at := _tag_positions(tag)
	var best := BIG_DISTANCE
	if at.is_empty():
		return best
	for b in enemies:
		if is_instance_valid(b) and is_instance_valid(b.soldier) and b.soldier.alive:
			best = minf(best, at[0].distance_to(b.soldier.global_position))
	return best


## Disabled or destroyed: a base object of that tag that is no longer enabled (an unknown tag is never disabled).
func vm_disabled(tag: String) -> bool:
	var base := TribesBase.of(battle)
	if base == null:
		return false
	for at in _tag_positions(tag):
		var o := _base_object_at(base, at)
		if o != null and (not is_instance_valid(o) or not o.is_enabled()):
			return true
	return false


## Turrets of the map's TURRETn tags destroyed so far.
func vm_destroyed() -> int:
	var n := 0
	for tag in TURRET_TAGS:
		for at in AAScript.make_tag_positions(map, tag):
			for d in _destroyed:
				if d.distance_to(at) < DESTROY_MATCH_METRES:
					n += 1
					break
	return n


func vm_deployed() -> int:
	return _deployed


func vm_switch() -> bool:
	return _switch


func vm_boarded() -> bool:
	var p: Herc = battle.player
	return p != null and is_instance_valid(p) and _near_tag("VSTATION1", BOARD_METRES, p)


func vm_voice_playing() -> bool:
	return _sink.is_voice_playing()


## The strength of an input a training lesson asks for (the remake's input map stands for the PS2 pad's sticks and buttons).
func vm_input(name: String) -> float:
	if name.begins_with("look_"):
		return _look_strength(name.trim_prefix("look_"))
	var action: String = INPUT_ACTIONS.get(name, "")
	return Input.get_action_strength(action) if action != "" and InputMap.has_action(action) else 0.0


## Looking up / down / left / right: the mouse or the right stick moving that way.
func _look_strength(dir: String) -> float:
	var v := Input.get_last_mouse_velocity()
	match dir:
		"up":
			return clampf(maxf(-v.y / LOOK_MOUSE_SPEED, Input.get_action_strength("aim_up")), 0.0, 1.0)
		"down":
			return clampf(maxf(v.y / LOOK_MOUSE_SPEED, Input.get_action_strength("aim_down")), 0.0, 1.0)
		"left":
			return clampf(maxf(-v.x / LOOK_MOUSE_SPEED, Input.get_action_strength("aim_left")), 0.0, 1.0)
		"right":
			return clampf(maxf(v.x / LOOK_MOUSE_SPEED, Input.get_action_strength("aim_right")), 0.0, 1.0)
	return 0.0


func vm_count(_name: String) -> int:
	return 0


## A lesson text (campaign_logic::PrintObjective): shown as the objective line.
func vm_objective(index: int) -> void:
	_objective_text = str(_texts.get(str(index), ""))


## A message (GameInfo / ErrorText): a radio line.
func vm_message(index: int, _is_error: bool) -> void:
	_sink.apply_message(MissionMessage.make_message(str(_texts.get(str(index), ""))))


## Voice at once, cutting the one playing (campaign_logic::GameAudio).
func vm_audio(id: int) -> void:
	kit.announcer.apply_say(MissionMessage.make_voice_only(MissionVoice.make_voice(id, 0.0, true)))


## A scripted loss of a base object (campaign_logic::DestroyItem): the object at the tag takes lethal damage.
func vm_destroy(tag: String) -> void:
	var base := TribesBase.of(battle)
	if base == null:
		return
	for at in _tag_positions(tag):
		var o := _base_object_at(base, at)
		if o != null and is_instance_valid(o) and o.alive:
			o.apply_hit(1.0e9, 1.0e9)


## SetInventCount: the spawn kit already holds the lessons' grenades, mines and repair items; nothing is given.
func vm_give(_item: String, _count: int) -> void:
	pass


## A prompt (campaign_logic::GamePrompt): plays now, or after the one playing (the latest waiting one replaces an older).
func vm_prompt(id: int) -> void:
	if kit.ender.has_verdict():
		return
	kit.announcer.apply_say(MissionMessage.make_voice_only(MissionVoice.make_voice(id)))


## The closing prompt (Failed / Success): cuts the one playing, then the mission ends after it and END_DELAY.
func vm_end(success: bool, id: int) -> void:
	kit.announcer.apply_say(MissionMessage.make_voice_only(MissionVoice.make_voice(id, 0.0, true)))
	var verdict := MissionVerdict.make_win(CODE_SUCCESS, "Mission complete.", END_DELAY, true) if success \
		else MissionVerdict.make_loss(CODE_FAILED, "Mission failed.", END_DELAY, true)
	kit.ender.apply_verdict(verdict.apply_grace_after_voice())


func vm_spawn(team: int, wave: int) -> void:
	if team == ENEMY_TEAM:
		_spawn_wave(wave)
	else:
		_spawn_allies(wave)


## An order (campaign_logic::OrderBots): kept on the soldier it names (slot -1 = all of the side), applied by _aim_soldiers.
func vm_order(team: int, task: int, target: String, slot: int) -> void:
	var list: Array = enemies if team == ENEMY_TEAM else allies
	var order := AIOrder.new()
	order.kind = TASK_KINDS.get(task, AIOrder.ATTACK)
	order.tag = target
	order.source = task
	if slot < 0:
		for b in list:
			if is_instance_valid(b):
				b.set_meta(ORDER_META, order)
	elif slot < list.size() and is_instance_valid(list[slot]):
		list[slot].set_meta(ORDER_META, order)
	_aim_soldiers()


## The waypoints the script shows: the first object of each active tag.
func vm_waypoint(tag: String, on: bool) -> void:
	if on:
		_waypoints[tag] = true
	else:
		_waypoints.erase(tag)
	nav_points = []
	for t in _waypoints:
		var at := _tag_positions(str(t))
		if not at.is_empty():
			nav_points.append(at[0])
	nav_index = 0


## Positions of the objects a script tag names: "TURRETS" / "GENS" are the turret / generator tags, "player" the player.
func _tag_positions(tag: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var tags: Array = [tag]
	if tag == "TURRETS":
		tags = TURRET_TAGS
	elif tag == "GENS":
		tags = GENERATOR_TAGS
	elif tag == "player":
		var p: Herc = battle.player
		if p != null and is_instance_valid(p):
			out.append(p.global_position)
		return out
	for t in tags:
		out.append_array(AAScript.make_tag_positions(map, str(t)))
	return out


func _near_tag(tag: String, metres: float, p: Node3D) -> bool:
	var at := _tag_positions(tag)
	if at.is_empty():
		return true
	for v in at:
		if p.global_position.distance_to(v) < metres:
			return true
	return false


## The base object standing at `at` (within DESTROY_MATCH_METRES), if any.
func _base_object_at(base: TribesBase, at: Vector3) -> TribesBaseObject:
	var best: TribesBaseObject = null
	var best_d := DESTROY_MATCH_METRES
	for o in base.objects:
		if is_instance_valid(o):
			var d := o.global_position.distance_to(at)
			if d < best_d:
				best_d = d
				best = o
	return best


func count_alive(brains: Array) -> int:
	var n := 0
	for b in brains:
		if is_instance_valid(b) and is_instance_valid(b.soldier) and b.soldier.alive:
			n += 1
	return n


## A soldier of `team` in armour size `size` at `pos` (the host spawns it on every peer with a bot brain).
func _spawn_soldier(team: int, size: String, pos: Vector3) -> InfantryBot:
	var bots: InfantryBots = battle.infantry.bots
	var armor_id := "%s:%s" % [ARMOR.get_slice(":", 0), size]
	if InfantryCatalog.armor(armor_id).is_empty():
		armor_id = ARMOR
	var spot := pos + Vector3(randf_range(-4.0, 4.0), 0.0, randf_range(-4.0, 4.0))
	var xf := Transform3D(Basis(Vector3.UP, randf() * TAU), battle.infantry.make_on_ground(spot))
	var spec: Dictionary = battle.infantry.make_soldier_spec(bots.allocate_bot_id(), team,
		"BioDerm" if team == ENEMY_TEAM else "Ally", xf)
	spec.armor = armor_id
	spec.vehicle = armor_id
	spec.loadout = InfantryCatalog.armor(armor_id).get("default_loadout", [])
	spec["body_shape"] = _make_body(team, armor_id)
	spec["bot"] = true
	return bots.spawn_bot(spec, SOLDIER_SKILL)


## Enemy soldiers are Bioderms (the disc's own, else Tribes 2's), allies Aerial Assault humans, else the armour's own.
static func _make_body(team: int, armor_id: String) -> String:
	if team == ENEMY_TEAM:
		for b in InfantryCatalog.make_aa_bodies(armor_id):          # the disc's own bioderms first
			if bool(b.bioderm):
				return str(b.id)
		for b in InfantryCatalog.make_bodies(armor_id):
			if bool(b.bioderm):
				return str(b.id)
		return ""
	var aa := InfantryCatalog.make_aa_bodies(armor_id)
	return str(aa[0].id) if not aa.is_empty() else ""


## Gives every soldier its objective: its order (scripted missions), else the enemies go for the player and the allies
## follow (the first waypoint, else the player).
func _aim_soldiers() -> void:
	var p: Herc = battle.player
	if p == null or not is_instance_valid(p):
		return
	for b in enemies:
		if is_instance_valid(b):
			b.objective = _make_objective(b, ENEMY_TEAM, p)
	for b in allies:
		if is_instance_valid(b):
			b.objective = _make_objective(b, PLAYER_TEAM, p)


func _make_objective(b: InfantryBot, team: int, p: Herc) -> Dictionary:
	var order: AIOrder = b.get_meta(ORDER_META, null)
	var enemy_side := team == ENEMY_TEAM
	if order == null:
		if enemy_side:
			return _make_plan(AIOrder.ATTACK, p.global_position, false, 25.0, false).to_objective()
		var lead := nav_points[0] if not nav_points.is_empty() else p.global_position
		return _make_plan(AIOrder.MOVE, lead, false, 20.0, false).to_objective()
	var here := b.soldier.global_position
	match int(order.source):
		TASK_DEATHMATCH:                     # the nearest enemy of its side (the player for the BioDerms)
			var foe := p.global_position if enemy_side else _nearest_enemy(here, p.global_position)
			return _make_plan(AIOrder.ATTACK, foe, false, 25.0, false).to_objective()
		TASK_ANTAGONIZE:                     # hunt the player
			return _make_plan(AIOrder.ATTACK, p.global_position, false, 25.0, false).to_objective()
	var at := _pick_target(order.tag, here)
	if at.is_empty():
		return _make_plan(AIOrder.ATTACK, p.global_position, false, 25.0, false).to_objective()
	match order.kind:
		AIOrder.DEFEND:                      # a place
			return _make_plan(AIOrder.DEFEND, at.pos, false, 15.0, true).to_objective()
		AIOrder.MOVE:                        # roam to a place (the player: stay with him)
			return _make_plan(AIOrder.MOVE, at.pos, false, 20.0, false).to_objective()
	# attack / mortar / repair / destroy an object: its base object is the soldiers' target
	return _make_plan(AIOrder.ATTACK, at.pos, true, 25.0, false, at.get("node")).to_objective()


static func _make_plan(kind: String, point: Vector3, urgent: bool, radius: float, hold: bool, target = null) -> AIOrder:
	return AIOrder.make_plan(kind, point, urgent, radius, hold, target as Node3D)


## {pos, node?} of the object an order names; "GENS" the generator still standing nearest to `from`, "TURRETS" a standing turret.
func _pick_target(tag: String, from: Vector3) -> Dictionary:
	var base := TribesBase.of(battle)
	var best := {}
	var best_d := INF
	for at in _tag_positions(tag if tag != "" else "player"):
		var o: TribesBaseObject = _base_object_at(base, at) if base != null else null
		var standing := o == null or (is_instance_valid(o) and o.is_enabled())
		var d := from.distance_to(at) + (0.0 if standing else 100000.0)
		if d < best_d:
			best_d = d
			best = {"pos": at}
			if o != null and is_instance_valid(o) and o.alive:
				best["node"] = o
	return best


func _nearest_enemy(from: Vector3, fallback: Vector3) -> Vector3:
	var best := fallback
	var best_d := INF
	for b in enemies:
		if is_instance_valid(b) and is_instance_valid(b.soldier) and b.soldier.alive:
			var d := from.distance_to(b.soldier.global_position)
			if d < best_d:
				best_d = d
				best = b.soldier.global_position
	return best


# ------------------------------------------------------------------ arena missions

## Kills score `points_per_kill`; the mode's limit wins; the bots come back after ARENA_RESPAWN_SECONDS.
func _step_arena(delta: float) -> void:
	_refresh -= delta
	if _refresh <= 0.0:
		_refresh = OBJECTIVE_REFRESH
		_aim_soldiers()
	_tick_objectives(delta)
	if kit.ender.has_verdict():
		return
	var missing := int(logic.get("enemy_bots", 0)) - count_alive(enemies) - _respawns.size()
	for _k in maxi(missing, 0):
		_respawns.append(0.0 if enemies.is_empty() else ARENA_RESPAWN_SECONDS)
	for k in range(_respawns.size() - 1, -1, -1):
		_respawns[k] -= delta
		if _respawns[k] <= 0.0:
			_respawns.remove_at(k)
			var b := _spawn_soldier(ENEMY_TEAM, AAScript.SIZES[randi() % 2], _make_arena_point())
			if b:
				enemies.append(b)


## An enemy start: the map's spawn of the enemy team, else any spawn.
func _make_arena_point() -> Vector3:
	var best: Array = []
	for s in map.get("spawns", []):
		if str(s.get("kind", "")) == "infantry":
			var p: Array = s.pos
			var v := Vector3(float(p[0]), float(p[1]), float(p[2]))
			if int(s.get("team", 0)) == ENEMY_TEAM:
				best.push_front(v)
			else:
				best.append(v)
	return best[randi() % best.size()] if not best.is_empty() else Vector3.ZERO


func arena_score() -> int:
	return kills * int(logic.get("points_per_kill", 1))


## Host: a soldier died. Enemy soldiers killed count as kills in the arena missions.
func on_unit_destroyed(h: Herc) -> void:
	if h is Infantry and h.team == ENEMY_TEAM:
		kills += 1


## The mission's own objective notes, then the fallback goal's progress.
func make_objective_lines() -> Array:
	var out := []
	for line in String(m.get("texts", {}).get("objective_notes", "")).split("\n", false):
		out.append({"text": line.strip_edges(), "done": false})
	if goal == GOAL_ARENA:
		out.append({"text": "%s: score %d of %d (%d kills)" % [str(logic.get("mode", "")).capitalize(), arena_score(),
			int(logic.get("score_limit", 0)), kills], "done": false})
		return out
	if goal == GOAL_SCRIPT:
		var lesson := _objective_text if _objective_text != "" else (vm.state_text() if vm != null else "")
		if lesson != "":
			out.append({"text": lesson, "done": false})
		return out
	match goal:
		GOAL_GENERATORS:
			var down := _generators_down.size()
			out.append({"text": "Destroy the enemy generators (%d of %d)" % [down, targets.size()], "done": down == targets.size()})
		GOAL_WAYPOINTS:
			var reached := waypoint_index
			out.append({"text": "Reach the waypoints in order (%d of %d)" % [reached, targets.size()], "done": reached == targets.size()})
		_:
			out.append({"text": "Survive (%d s left)" % maxi(0, int(SURVIVE_SECONDS - elapsed)), "done": false})
	return out


func make_debriefing_text(_code: int, text: String) -> String:
	return text if text != "" else "Mission over."
