extends Node
## Time-to-kill check: player Herc with its default loadout holds both triggers at a dummy enemy
## placed ahead. Prints enemy shields/integrity each second.  Args: -- --herc=es1:RAPTOR --dist=150

var battle: Node
var enemy: Herc
var t := 0.0
var hits := 0

func _ready() -> void:
	var herc_id := "es1:RAPTOR"
	var target_id := "es1:SCORPION"
	var dist := 150.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--herc="): herc_id = a.substr(7)
		if a.begins_with("--target="): target_id = a.substr(9)
		if a.begins_with("--dist="): dist = float(a.substr(7))
	var scene: PackedScene = load("res://games/es1/battle.tscn")
	battle = scene.instantiate()
	var mission := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mission="): mission = a.substr(10)
	if mission == "":
		var cfg: Dictionary = battle.default_config(herc_id)
		cfg["ai"] = []
		battle.config = cfg
	add_child(battle)
	await get_tree().create_timer(1.0).timeout
	var p: Herc = battle.player
	var xf := p.global_transform
	xf.origin += -xf.basis.z * dist
	xf.basis = xf.basis.rotated(Vector3.UP, PI)
	if mission != "":
		# nearest hostile Herc from the mission, moved in front of the player
		var best: Herc = null
		for n in battle.get_children():
			if n is Herc and n != p and n.team != p.team and n.alive and (best == null or n.global_position.distance_to(p.global_position) < best.global_position.distance_to(p.global_position)):
				best = n
		enemy = best
		print("mission enemy: ", enemy.vehicle_id if enemy else null, " weapons ", enemy.weapons.map(func(w): return w.weapon_name) if enemy else [])
		enemy.global_transform = xf
	else:
		enemy = battle.spawn_ai(target_id, 1, xf, [], "Dummy", {"skill": 0.0})
	enemy.set_physics_process(false)
	for c in enemy.get_children():
		if c is AIPilot: c.queue_free()
	enemy.damaged.connect(func(_h, _a): hits += 1)
	p.target = enemy
	print("weapons: ", p.weapons.map(func(w): return "%s sh=%.0f ar=%.0f per_shot=%s kind=%s" % [w.weapon_name, w.shield_damage, w.armor_damage, w.per_shot, w.kind]))
	print("enemy comps: ", enemy.components.map(func(c): return "%s %.0f%s p%d" % [c.name, c.hp, " F" if c.fatal else "", c.parent]))

func _process(delta: float) -> void:
	if enemy == null:
		return
	var p: Herc = battle.player
	# keep aiming at the dummy
	p.look_at(Vector3(enemy.global_position.x, p.global_position.y, enemy.global_position.z))
	p.rotation.y += PI if false else 0.0
	for w in p.weapons:
		w.trigger = not ("--lasers-only" in OS.get_cmdline_user_args() and w.kind != "beam")
	var old := int(t)
	t += delta
	if int(t) != old:
		print("t=%2d hits=%d alive=%s shF=%.0f shR=%.0f integ=%.2f cap=%.0f dist=%.0f" % [int(t), hits, enemy.alive, enemy.shield_front, enemy.shield_rear, enemy.integrity, p.capacitor, p.global_position.distance_to(enemy.global_position)])
	if not enemy.alive or t > 90:
		print("RESULT killed=%s t=%.1f hits=%d" % [not enemy.alive, t, hits])
		get_tree().quit()
