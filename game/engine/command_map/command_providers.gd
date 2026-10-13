class_name CommandProviders
extends RefCounted
## Which game's command map a battle gets (docs/COMMAND_MAP.md section 3): the battle's game is the mission's
## (Earthsiege 1 / 2, Starsiege, Tribes campaign and training), else its map's pack (versus, co-op, extraction on a
## Tribes / Starsiege map), else its world's (an Earthsiege world, a Battledrome arena). Every battle gets one; games
## without an order system of their own get the remake's set (CommandProvider).


## Builds the battle's orders (CommandOrders), the command_map key handler (CommandMapInput) and the game's squad
## keys (SquadKeys, Starsiege).
static func build_for(battle: Node3D) -> CommandOrders:
	var orders := CommandOrders.build_for(battle, make_for(battle))
	CommandMapInput.build_for(battle)
	SquadKeys.build_for(battle, orders.provider)
	return orders


static func make_for(battle: Node) -> CommandProvider:
	var pack := make_game_pack(battle)
	match pack:
		"tribes", "tribes2":
			return TribesCommandProvider.make(pack)
		"es1", "es2":
			return WingmanCommandProvider.make(pack)
		"starsiege":
			return StarsiegeCommandProvider.make()
	return CommandProvider.new()


## The pack of the game the battle plays.
static func make_game_pack(battle: Node) -> String:
	var mission = battle.get("mission")
	if mission is TribesMissionRuntime:
		return str((mission as TribesMissionRuntime).pack)
	if mission is StarsiegeMissionRuntime:
		return "starsiege"
	if mission is MissionRuntime:
		return (mission as MissionRuntime).radio_pack()
	var config: Dictionary = battle.get("config") if battle.get("config") is Dictionary else {}
	if str(config.get("map", "")).contains(":"):
		return str(config.map).get_slice(":", 0)
	if config.has("arena"):
		return "bd"
	return str(config.get("world_pack", "es1"))
