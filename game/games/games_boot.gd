extends Node
## Autoload: every game registers itself with the engine's registries here, so engine/ never names a game class.
## Claim order matters: the first game that claims a mission plays it (Tribes 2 before Tribes 1, Earthsiege last).


func _ready() -> void:
	apply_registrations()


## The registry holds the runtime scripts (which reference each other); dropping them before the engine frees the script
## classes keeps the shutdown from crashing (every headless run exited with a segmentation fault).
func _exit_tree() -> void:
	MissionKinds.clear()


## Idempotent: clears and fills the MissionKinds registry.
static func apply_registrations() -> void:
	MissionKinds.clear()
	MissionKinds.register(func(m: Dictionary) -> bool:
		return TribesMissionRuntime.is_tribes(m) and String(m.get("pack", "")) == "tribes2", Tribes2MissionRuntime)
	MissionKinds.register(TribesMissionRuntime.is_tribes, Tribes1MissionRuntime)
	MissionKinds.register(func(m: Dictionary) -> bool: return String(m.get("pack", "")) == MissionRuntimeES2.PACK,
		MissionRuntimeES2)
	MissionKinds.register(TVMissionRuntime.is_tv, TVMissionRuntime)
	MissionKinds.register(AAMissionRuntime.is_aa, AAMissionRuntime)
	MissionKinds.register(StarsiegeMissionRuntime.is_starsiege, StarsiegeMissionRuntime)
	MissionKinds.register_default(MissionRuntime)
