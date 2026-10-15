class_name MissionKinds
extends RefCounted
## The one door to "which game plays this resolved mission": picks the game's MissionRuntime script and
## asks it, through the runtimes' shared static launch contract, what the mission dictates before the
## battle starts (MissionRuntime "launch contract"):
##   static func apply_world_to_config(config, mission)   the world / terrain map the battle builds
##   static func make_mission_herc(mission) -> Dictionary  the vehicle the mission issues ({} = player's choice)
##   static func is_mission_herc_forced() -> bool          the issued vehicle replaces the player's choice
##   static func make_area_rule() -> String                 BattleBounds.AREA_*: who handles leaving the area
## Callers (Session, BattleSetup) never branch on the game themselves.


## The MissionRuntime script that plays `mission` (Earthsiege 1 when no other game claims it).
static func runtime_script(mission: Dictionary) -> GDScript:
	if TribesMissionRuntime.is_tribes(mission):
		return Tribes2MissionRuntime if String(mission.get("pack", "")) == "tribes2" else Tribes1MissionRuntime
	if String(mission.get("pack", "")) == MissionRuntimeES2.PACK:
		return MissionRuntimeES2
	if AAMissionRuntime.is_aa(mission):
		return AAMissionRuntime
	if StarsiegeMissionRuntime.is_starsiege(mission):
		return StarsiegeMissionRuntime
	return MissionRuntime


## A new runtime node for `mission`.
static func make_runtime(mission: Dictionary) -> MissionRuntimeBase:
	return runtime_script(mission).new()


## Points battle `config` at `mission`'s world and, unless the launch keeps the player's choice
## ("use_mission_herc": false) and the game does not force it, at the vehicle the mission issues.
static func apply_to_config(config: Dictionary, mission: Dictionary) -> void:
	var kind := runtime_script(mission)
	kind.apply_world_to_config(config, mission)
	var herc: Dictionary = kind.make_mission_herc(mission)
	if herc.is_empty():
		return
	if config.get("use_mission_herc", true) or kind.is_mission_herc_forced():
		for peer in config.roster:
			config.roster[peer].vehicle = str(herc.vehicle)
			config.roster[peer].loadout = (herc.loadout as Array).duplicate()


## The vehicle `mission` issues the player ({vehicle, loadout}), {} when it leaves the choice to the player
## or names a vehicle no installed pack has.
static func make_mission_herc(mission: Dictionary) -> Dictionary:
	if mission.is_empty():
		return {}
	var herc: Dictionary = runtime_script(mission).make_mission_herc(mission)
	if herc.is_empty() or Packs.vehicle(str(herc.vehicle)).is_empty():
		return {}
	return herc


## Who handles a pilot leaving the battle area (BattleBounds.AREA_*): a battle without a mission uses the damage rule.
static func make_area_rule(mission: Dictionary) -> String:
	if mission.is_empty():
		return BattleBounds.AREA_DAMAGE
	return runtime_script(mission).make_area_rule()
