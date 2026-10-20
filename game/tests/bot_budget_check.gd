extends Node
## The server's bot cap (engine/bot_budget.gd): "max_bots" limits live AI soldiers plus AI vehicles; a distant garrison is
## refused first, a nearby one next, the match's own bots at the cap, mission units never; the spawners ask the budget.
##   godot --headless --audio-driver Dummy --path game res://tests/bot_budget_check.tscn
## Prints "bot_budget_check: OK" or "FAILED"; exit code 0 / 1.

const MAP := "tribes:Raindance"
const SETTLE_FRAMES := 20
const CAP := 10
const FAR_M := 2000.0

var _failures := 0
var _battle: Battle


func _ready() -> void:
	await get_tree().process_frame
	await _start_battle()
	_check_limits()
	_check_unlimited()
	_check_spawn_all_and_priorities()
	_check_server_config()
	print("bot_budget_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _start_battle() -> void:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": [], BotBudget.CONFIG_KEY: CAP, InfantryBots.CONFIG_KEY: 0}, true)
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)
	get_tree().current_scene = _battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame


func _spawn_bots(n: int) -> int:
	var made := 0
	var bots := _battle.infantry.bots as InfantryBots
	for i in n:
		if bots.spawn_bot(bots.make_bot_spec(_battle.infantry.pack, i), InfantryBots.BOT_SKILL) != null:
			made += 1
	return made


func _check_limits() -> void:
	print("limits:")
	_expect(BotBudget.make_cap(_battle) == CAP, "the cap is read from the battle's config (%d)" % CAP)
	_expect(BotBudget.make_limit(CAP, BotBudget.Priority.DISTANT) == 7, "distant garrisons get 70% of the cap")
	_expect(BotBudget.make_limit(CAP, BotBudget.Priority.NEAR) == 9, "near garrisons get 90%")
	_expect(BotBudget.make_limit(CAP, BotBudget.Priority.MATCH) == CAP, "the match's bots get all of it")
	_expect(BotBudget.count_live(_battle) == 0, "no AI unit is live yet")


func _check_unlimited() -> void:
	print("no cap:")
	_battle.config[BotBudget.CONFIG_KEY] = 0
	_expect(BotBudget.admits(_battle, BotBudget.Priority.DISTANT), "max_bots 0 admits everything")
	_battle.config[BotBudget.CONFIG_KEY] = CAP


func _check_spawn_all_and_priorities() -> void:
	print("spawners:")
	var bots := _battle.infantry.bots as InfantryBots
	_battle.config[InfantryBots.CONFIG_KEY] = InfantryBots.MAX_BOTS
	bots.spawn_all(_battle.infantry.pack)
	_expect(BotBudget.count_live(_battle) == CAP, "spawn_all asked for %d bots and stopped at the cap (%d live)" % [InfantryBots.MAX_BOTS, BotBudget.count_live(_battle)])
	_expect(_spawn_bots(1) == 0, "a further match bot is refused")
	_expect(not BotBudget.admits(_battle, BotBudget.Priority.DISTANT) and not BotBudget.admits(_battle, BotBudget.Priority.NEAR),
		"garrisons are refused at the cap")
	_expect(BotBudget.admits(_battle, BotBudget.Priority.CRITICAL), "a mission unit is never refused")
	_check_reserves()


## Killing bots frees room by priority: distant garrisons come back last.
func _check_reserves() -> void:
	var live: Array = []
	for v in _battle.vehicles.values():
		if is_instance_valid(v) and BotBudget.is_ai_unit(v):
			live.append(v)
	for i in 2:
		live[i].set("alive", false)   # 8 live: below the near limit (9), above the distant one (7)
	_expect(BotBudget.count_live(_battle) == CAP - 2, "dead bots do not count (%d live)" % BotBudget.count_live(_battle))
	_expect(BotBudget.admits(_battle, BotBudget.Priority.NEAR), "with 8 live a nearby garrison is admitted")
	_expect(not BotBudget.admits(_battle, BotBudget.Priority.DISTANT), "...a distant one is not")
	var human := _battle.player as Node3D
	var here := human.global_position
	var far_away := here + Vector3(FAR_M, 0.0, 0.0)
	_expect(BotBudget.make_distance_priority(_battle, here) == BotBudget.Priority.NEAR, "a spot beside the human is NEAR")
	_expect(BotBudget.make_distance_priority(_battle, far_away) == BotBudget.Priority.DISTANT, "a spot %.0f m away is DISTANT" % FAR_M)
	var spec := {"faction": "x", "xf": Transform3D(Basis(), far_away)}
	_expect((_battle.infantry.bots as InfantryBots).spawn_bot(spec, 0.5) == null, "a faction soldier far from the human is refused with 8 live")


func _check_server_config() -> void:
	print("server config:")
	_expect(ServerConfig.DEFAULTS.has("max_bots") and int(ServerConfig.DEFAULTS.max_bots) == 0, "max_bots defaults to 0 (no cap)")
	var cfg := ServerConfig.load_from_args(PackedStringArray(["--max-bots=40"]))
	_expect(int(cfg.max_bots) == 40, "--max-bots=40 is read")
	_expect(int(ServerConfig.make_settings(cfg).get(BotBudget.CONFIG_KEY, -1)) == 40, "the lobby settings carry it")
