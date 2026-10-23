class_name MissionRuntimeBase
extends Node
## What every game's mission runtime is to the Battle (Earthsiege 1 MissionRuntime and its Earthsiege 2 subclass,
## StarsiegeMissionRuntime, TribesMissionRuntime): the one contract the Battle, MissionKinds and the shared screens
## use, with no game's own rules in it.
##
## Battle side: setup (every peer) / spawn_units / player_spawn / formation_offset_local / on_unit_destroyed (host),
## mission_over; reads nav_points / nav_index / structures / mission_vars.
## Launch side (static, MissionKinds): apply_world_to_config, make_mission_herc, is_mission_herc_forced,
## make_area_rule.
## Rules side: make_rules_step (the rules tick in simulation time), make_objective_lines, end_mission with the
## per-game hooks apply_end / make_end_var / make_debriefing_text.

signal mission_over(success: bool, code: int, text: String)

## Mission variables the campaigns carry between missions (Earthsiege 1, Starsiege and Tribes keep 100).
const MISSION_VAR_COUNT := 100
## Debriefing codes the Darkstar-era games (Starsiege, Tribes, Aerial Assault, Vengeance) store in mission var 0.
const CODE_SUCCESS := 1
const CODE_FAILED := 6

var battle: Node3D
var m: Dictionary                 # resolved mission
var mission_vars := PackedInt32Array()
var nav_points: Array[Vector3] = []
var nav_index := 0
var structures := []              # index -> Structure
var _over := false
## The mission blocks (clock, timers, objectives, fail rules, announcer, ender ...) this game fills in.
var kit := MissionKit.new()


# ------------------------------------------------------------------ launch contract (MissionKinds)

## Points battle `config` at `mission`'s world (each game says how).
static func apply_world_to_config(_config: Dictionary, _mission: Dictionary) -> void:
	pass


## The player vehicle `mission` dictates ({vehicle, loadout}); {} leaves the choice to the player.
static func make_mission_herc(_mission: Dictionary) -> Dictionary:
	return {}


## True when the mission's vehicle replaces the player's choice even when the launch keeps it.
static func is_mission_herc_forced() -> bool:
	return false


## Who handles a pilot leaving the battle area (BattleBounds.AREA_*).
static func make_area_rule() -> String:
	return BattleBounds.AREA_DAMAGE


# ------------------------------------------------------------------ battle contract

## True once the mission has ended.
func is_over() -> bool:
	return _over


## Builds what every peer sees (structures, nav points) for `mission`; `vars` = the campaign's mission variables.
func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	battle = p_battle
	m = mission
	mission_vars = vars if vars.size() == MISSION_VAR_COUNT else _default_vars()


func _default_vars() -> PackedInt32Array:
	var v := PackedInt32Array()
	v.resize(MISSION_VAR_COUNT)
	return v


## Host: spawns the mission's units.
func spawn_units() -> void:
	pass


## Where roster pilot `k` starts.
func player_spawn(_k: int) -> Transform3D:
	return Transform3D()


## Formation slot `k`'s offset in its leader's frame (metres), for AI followers.
func formation_offset_local(_k: int) -> Vector3:
	return Vector3.ZERO


## Host: a vehicle of the battle was destroyed.
func on_unit_destroyed(_h: Herc) -> void:
	pass


## The objectives panel's lines ([{text, done}], MissionObjectives).
func make_objective_lines() -> Array:
	return []


# ------------------------------------------------------------------ rules and end

## Every game's rules run every `interval` seconds of simulation time. Returns the simulation time since the
## last rules tick when one is due this physics step (a tick spans whole physics steps, so it is usually a bit
## more than `interval`; timers driven by it then keep game time), else 0.
func make_rules_step(delta: float, interval: float) -> float:
	return kit.clock.make_step(delta, interval)


## The default host tick: advances the clock and runs the kit's blocks in their fixed order (MissionKit.apply_tick) with
## the rules step of `interval` seconds. Returns the payloads of the kit timers that ran out. A game whose rules need
## more than the kit overrides _physics_process and calls this for the shared part.
func apply_kit_tick(world: MissionWorld, delta: float, interval: float) -> Array:
	kit.clock.apply_advance(delta)
	return kit.apply_tick(world, delta, make_rules_step(delta, interval))



## The world the kit's blocks ask about (null: the game has none and fills in no block that needs one).
func make_world() -> MissionWorld:
	return null


## Seconds between the rules ticks of the default tick.
func make_rules_interval() -> float:
	return 0.25


## The default tick of a runtime that needs nothing beyond the kit; a game with more rules overrides it.
func _physics_process(delta: float) -> void:
	if _over or not multiplayer.is_server():
		return
	apply_kit_tick(make_world(), delta, make_rules_interval())

## Ends the mission once, the same way in every game: the game's end bookkeeping (apply_end), its end code in
## mission var 0 (make_end_var), then the result and the debriefing text (make_debriefing_text) to the Battle.
func end_mission(success: bool, code: int, text: String) -> void:
	if _over:
		return
	_over = true
	apply_end(success)
	mission_vars[0] = make_end_var(success, code)
	mission_over.emit(success, code, make_debriefing_text(code, text))


## The game's bookkeeping when its mission ends (radio calls, inventory for the campaign).
func apply_end(_success: bool) -> void:
	pass


## Mission var 0 at the end (the game's end code by default).
func make_end_var(_success: bool, code: int) -> int:
	return code


## Game fields the mission adds to the battle result (MissionOutcome; Earthsiege 2: the debriefing clip).
func make_result_extra() -> Dictionary:
	return {}


## The debriefing text the result screen shows (the end text by default).
func make_debriefing_text(_code: int, text: String) -> String:
	return text
