class_name BattleSetup
extends RefCounted
## Battle configuration: the default skirmish, the command-line test flags, the mission definition
## behind a "mission" config and the world (map, arena or Earthsiege world) it is fought on.
##
## Test flags (after `--`): --herc=<vehicle> --world=<n> --zone=<n> --arena=<size> --map=<pack:name>
## --mission=<name> --start=on_foot|vehicle --game_mode=<GameModes id> --team_count=<n>.

const DEFAULT_MISSION := "B0_C0_0A"
const ARENA_AI := [{"vehicle": "bd:THOR", "team": 101, "skill": 0.5}, {"vehicle": "es1:PANTHER", "team": 102, "skill": 0.5},
	{"vehicle": "bd:STRYDER", "team": 103, "skill": 0.5}]
const MAP_AI := [{"vehicle": "es1:RAPTOR", "team": 101, "skill": 0.5}, {"vehicle": "bd:THOR", "team": 102, "skill": 0.5}]


static func make_default_config(vehicle := "es1:RAPTOR") -> Dictionary:
	return {
		"mode": "skirmish", "world": 0, "zone": 0, "frag_limit": 10, "respawn": false, "teams": false,
		"roster": {1: {"name": Net.player_name, "vehicle": vehicle, "team": 0, "loadout": []}},
		"ai": [
			{"vehicle": "es1:TOMAHAWK", "team": 0, "skill": 0.6, "name": "Wingman"},
			{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.35},
			{"vehicle": "es1:MONGOOSE", "team": 1, "skill": 0.4},
			{"vehicle": "es1:BULLDOG", "team": 1, "skill": 0.45},
			{"vehicle": "es1:ACHILLES", "team": 1, "skill": 0.5},
			{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.55},
			{"vehicle": "es1:SKIMMER", "team": 1, "skill": 0.5, "flyer": true},
			{"vehicle": "es1:SKIMMER", "team": 1, "skill": 0.5, "flyer": true},
		],
	}


## The default config with the command-line test flags applied.
static func make_config_from_args(args: PackedStringArray) -> Dictionary:
	var config := make_default_config()
	for a in args:
		_apply_flag(config, a)
	return config


static func _apply_flag(config: Dictionary, a: String) -> void:
	if a.begins_with("--herc="):
		config.roster[1].vehicle = Assets.qualify(a.substr(7))
	elif a.begins_with("--world="):
		config.world = int(a.substr(8))
	elif a.begins_with("--zone="):
		config.zone = int(a.substr(7))
	elif a.begins_with("--arena="):
		config.mode = "vs"
		config.respawn = true
		config.arena = {"size": int(a.substr(8)), "obstacles": "SEVERAL", "turrets": "FEW", "lighting": "BRIGHT"}
		config.ai = ARENA_AI.duplicate(true)
	elif a.begins_with("--map="):
		config.mode = "vs"
		config.respawn = true
		config.map = a.substr(6)
		config.ai = MAP_AI.duplicate(true)
	elif a.begins_with("--game_mode="):
		config[GameModes.CONFIG_KEY] = a.substr(12)   # GameModes.apply_to_config sets mode, teams, respawn
	elif a.begins_with("--team_count="):
		config.team_count = int(a.substr(13))
	elif a.begins_with("--start="):
		config.start = a.substr(8)   # BattleInfantry.START_ON_FOOT / START_IN_VEHICLE
	elif a.begins_with("--mission="):
		config.mode = "mission"
		config.mission_name = a.substr(10)


# ------------------------------------------------------------------ missions

## The mission definition of a "mission" config ({} for other modes).
static func load_mission_def(config: Dictionary) -> Dictionary:
	if config.get("mode") != "mission":
		return {}
	var mdef: Dictionary = config.get("mission", {})
	if mdef.is_empty() and String(config.get("mission_name", "")).begins_with("starsiege:"):
		mdef = StarsiegeMissionRuntime.load_mission(String(config.mission_name))
	if mdef.is_empty() and TribesMissionRuntime.is_mission_name(String(config.get("mission_name", ""))):
		mdef = TribesMissionRuntime.load_mission(String(config.mission_name))
	if mdef.is_empty():
		mdef = MissionRuntime.load_resolved(config.get("mission_name", DEFAULT_MISSION))
	return mdef


## Points the config at the mission's world and, unless use_mission_herc is false, its player Herc (a Tribes
## training mission: the armour the player starts in, on foot). Each game's runtime decides (MissionKinds).
static func apply_mission_to_config(config: Dictionary, mdef: Dictionary) -> void:
	MissionKinds.apply_to_config(config, mdef)


## The mission runtime that plays `mdef` (ES1, ES2, Starsiege, Tribes or Tribes 2).
static func make_mission_runtime(mdef: Dictionary) -> MissionRuntimeBase:
	return MissionKinds.make_runtime(mdef)


# ------------------------------------------------------------------ world

## Builds the battlefield under `battle`: a Darkstar map, a Battledrome arena or an Earthsiege world.
## Returns {"built": <builder result>, "world_info": <Earthsiege world info or {}>}.
static func build_world(battle: Node3D, config: Dictionary) -> Dictionary:
	var built := {}
	if config.has("map"):
		built = MapBuilder.build(battle, String(config.map))
	if built.is_empty() and config.has("arena") and Assets.has_pack("bd"):
		built = ArenaBuilder.build(battle, config.arena)
	if not built.is_empty():
		return {"built": built, "world_info": built.get("world_info", {})}
	built = WorldBuilder.build(battle, int(config.get("world", 0)), int(config.get("zone", 0)),
		String(config.get("world_pack", "es1")))
	return {"built": built, "world_info": built.world}
