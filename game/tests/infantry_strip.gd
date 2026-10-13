extends Node
## Windowed render strips of the Tribes armour and weapon shapes (no battle needed):
##   fix_c_poses.png    Tribes 2 light male run cycle at four phases, then deaths of three bodies (PLAYTEST C1)
##   fix_c_weapons.png  every Tribes 2 hand weapon and the Tribes 1 ones with muzzle flashes (Chaingun, Mortar,
##                      ELF gun) from both sides, drawn and ready: no flash may show (PLAYTEST W1)
##   fix_c_spinfusor.png the Spinfusor from both sides, loaded (its disc shows in DiscSpin)
##   godot --audio-driver Dummy --path game res://tests/infantry_strip.tscn -- --shots=<dir>

var _shots := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	if _shots == "" or DisplayServer.get_name() == "headless":
		print("infantry_strip: needs a window and --shots=<dir>")
		get_tree().quit(1)
		return
	await _shoot_pose_strip()
	get_tree().quit(0)


func _shot(tag: String) -> void:
	for i in 4:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "%s/fix_c_%s.png" % [_shots, tag]
	get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


static func _shape(id: String) -> ShapeInstance:
	var inst := ShapeInstance.new()
	inst.build(Assets.shape(id), 0, Packs.default_palette(id.get_slice(":", 0)))
	return inst


static func _seq_names(id: String) -> Array:
	return (Assets.shape(id).get("ds_sequences", []) as Array).map(func(q: Dictionary) -> String: return str(q.name).to_lower())


## Windowed runs only: a strip of Tribes 2 / Tribes 1 bodies on a plain floor - the run cycle at four phases, then
## deaths held on their last frame (fix_c_poses.png).
func _shoot_pose_strip() -> void:
	var stage := Node3D.new()
	add_child(stage)
	var cam := Camera3D.new()
	cam.position = Vector3(5.5, 1.6, 9.0)
	cam.current = true
	stage.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.5, 0.0)
	stage.add_child(sun)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	(floor_mesh.mesh as PlaneMesh).size = Vector2(40, 40)
	stage.add_child(floor_mesh)
	var x := 0.0
	for phase in [0.0, 0.25, 0.5, 0.75]:
		_pose_body(stage, "tribes2:light_male", "run", phase, x)
		x += 1.4
	for body in ["tribes2:light_male", "tribes2:bioderm_light", "tribes:larmor"]:
		_pose_death(stage, body, x)
		x += 2.2
	await _shot("poses")
	stage.queue_free()
	await _shoot_weapon_strip()


## Windowed runs only: every Tribes 2 hand weapon from both sides, three times their size (fix_c_weapons.png, W1).
func _shoot_weapon_strip() -> void:
	var stage := Node3D.new()
	add_child(stage)
	var cam := Camera3D.new()
	cam.position = Vector3(1.5, 1.6, 4.2)
	cam.current = true
	stage.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(-0.7, 0.4, 0.0)
	stage.add_child(sun)
	var ids := ["tribes2:BLASTER", "tribes2:CHAINGUN", "tribes2:SPINFUSOR", "tribes2:GRENADE_LAUNCHER", "tribes2:MORTAR",
		"tribes2:PLASMA_RIFLE", "tribes2:MISSILE_LAUNCHER", "tribes2:LASER_RIFLE", "tribes2:SHOCKLANCE", "tribes2:ELF_PROJECTOR",
		"tribes:CHAINGUN", "tribes:MORTAR", "tribes:ELF_GUN"]
	for i in ids.size():
		for side in 2:
			var w := Packs.weapon(ids[i])
			var model := InfantryHeldWeapon.make_ready_model(str(w.model.mount_shapes[0]), Packs.default_palette(ids[i].get_slice(":", 0)))
			stage.add_child(model)
			var anim := InfantryWeaponAnimation.new(model, w.model.get("animation", {}))
			anim.apply_draw()
			for k in 20:
				anim.update(0.1, false, false)   # drawn and resting: the ready pose (the disc loaded)
			model.position = Vector3(side * 3.0, 3.2 - i * 0.3, 0.0)
			model.rotation.y = PI * 0.5 + PI * side
	await _shot("weapons")
	for c in stage.get_children():
		if c is ShapeInstance:
			c.visible = false
	for side in 2:
		var disc := Packs.weapon("tribes2:SPINFUSOR")
		var m := InfantryHeldWeapon.make_ready_model(str(disc.model.mount_shapes[0]), Packs.default_palette("tribes2"))
		stage.add_child(m)
		var a := InfantryWeaponAnimation.new(m, disc.model.get("animation", {}))
		a.apply_draw()
		for k in 20:
			a.update(0.1, false, false)
		m.scale *= 3.0
		m.position = Vector3(1.5, 2.6 - side * 1.6, 0.0)
		m.rotation = Vector3(side * PI * 0.5, PI * 0.5, 0.0)   # from the side, then from above
	await _shot("spinfusor")
	stage.queue_free()


func _pose_body(stage: Node3D, body: String, seq: String, phase: float, x: float) -> void:
	var inst := _shape(body)
	stage.add_child(inst)
	inst.position = Vector3(x, -inst.lowest_point() * inst.scale.y, 0)
	inst.rotation.y = PI * 0.5
	ShapeCycles.pose(inst, _seq_names(body).find(seq), phase)


func _pose_death(stage: Node3D, body: String, x: float) -> void:
	var inst := _shape(body)
	stage.add_child(inst)
	inst.position = Vector3(x, -inst.lowest_point() * inst.scale.y, 0)
	InfantryAnimation.new(inst).apply_death(10.0, 1)
