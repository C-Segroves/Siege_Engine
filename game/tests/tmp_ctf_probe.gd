extends Node

func _ready() -> void:
	await get_tree().process_frame
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"map": "tribes2:Katabatic", "game_mode": "ctf", "team_count": 2, "start": "on_foot", "ai": [],
		InfantryBots.CONFIG_KEY: 4}, true)
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in 30:
		await get_tree().physics_frame
	battle.game_mode.brains.apply_goals()
	var grabber: Infantry = null
	for s in battle.infantry.bots.make_bot_soldiers():
		var b = s.get_node_or_null("Bot")
		if b and not b.objective.is_empty() and bool(b.objective.urgent):
			grabber = s
	grabber.destroyed.connect(func(h, k): print("DIED by ", KillText.make_kill_text(h, k)))
	var brain = grabber.get_node("Bot")
	var goal: Vector3 = brain.objective.point
	Engine.time_scale = 4.0
	for k in 40:
		await get_tree().create_timer(1.0).timeout
		var p: PackedVector3Array = brain._route.make_path()
		print("t=", k, " pos=", grabber.global_position.snapped(Vector3.ONE), " alive=", grabber.alive, " d=", int(grabber.global_position.distance_to(goal)), " task=", brain.task, " urgent=", brain.objective.get("urgent"), " path=", p.size(), " idx=", brain._route._index, " pending=", BattleNavigation.of(battle).pending_tiles(), " jet=", grabber.jetting, " v=", grabber.velocity.snapped(Vector3.ONE))
	get_tree().quit()
