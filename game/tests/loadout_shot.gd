extends Node
## Spawns Hercs in a row with their default loadouts, prints which weapons got a model, screenshots.
## Args: -- --ids=es1:SCORPION,es1:RAPTOR --shot=path.png

func _ready() -> void:
	var ids := ["es1:SCORPION", "es1:RAPTOR", "es1:TOMAHAWK", "es1:PANTHER", "es1:HERCULES", "es1:COLOSSUS"]
	var shot := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ids="): ids = Array(a.substr(6).split(","))
		if a.begins_with("--shot="): shot = a.substr(7)
	var battle: Node = load("res://games/es1/battle.tscn").instantiate()
	var cfg: Dictionary = battle.default_config("es1:RAPTOR")
	cfg["ai"] = []
	battle.config = cfg
	add_child(battle)
	await get_tree().create_timer(0.5).timeout
	var p: Herc = battle.player
	var base := p.global_transform
	var fwd := -base.basis.z
	var right := base.basis.x
	var hs := []
	for i in ids.size():
		var xf := Transform3D(base.basis.rotated(Vector3.UP, PI), base.origin + fwd * 45.0 + right * (float(i) - (ids.size() - 1) * 0.5) * 16.0)
		var h: Herc = battle.spawn_ai(ids[i], 1, xf, [], "", {"skill": 0.0})
		h.set_physics_process(false)
		for c in h.get_children():
			if c is AIPilot: c.queue_free()
		hs.append(h)
	await get_tree().process_frame
	for h in hs:
		var models: Array = h.shape.find_children("weapon*", "ShapeInstance", true, false)
		var info := []
		for i in h.weapons.size():
			var g: Dictionary = h.def.get("guns", [])[i] if i < h.def.get("guns", []).size() else {}
			var m: Array = h.shape.find_children("weapon%d" % i, "", true, false)
			info.append("%s node=%s grp=%s shapes=%s model=%s at=%s" % [h.weapons[i].weapon_name, g.get("mount_node"), g.get("mount_group"), h.weapons[i].def.get("shapes"), not m.is_empty(), (m[0].get_parent().name if not m.is_empty() else "-")])
		print(h.vehicle_id, " models=", models.size(), "\n   ", "\n   ".join(info))
	if shot != "":
		var cam := Camera3D.new()
		add_child(cam)
		cam.look_at_from_position(base.origin + Vector3.UP * 14.0 - fwd * 5.0, base.origin + fwd * 45.0 + Vector3.UP * 5.0)
		cam.make_current()
		for c in battle.get_children():
			if c is CanvasLayer: c.visible = false
		for mi in p.shape.find_children("*", "MeshInstance3D", true, false): mi.visible = false
		await get_tree().create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shot)
	get_tree().quit()
