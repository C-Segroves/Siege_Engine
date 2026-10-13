extends Node3D
## Renders a WorldBuilder world and saves a screenshot (needs a rendering driver: run without --headless).
##
##   Godot --path game res://tests/es2_world_shot.tscn -- --pack=es2 --world=0 --zone=123 \
##         --out=C:/tmp/shot.png [--at=0.4,0.6] [--height=12] [--yaw=30] [--pitch=-8]
##
## --at = fraction of the terrain extent (x east, y north) for the camera; --height = metres above
## the ground there; yaw in degrees (0 = north, 90 = east). ES1: --pack=es1 --world=0 --zone=-1.

func _ready() -> void:
	var a := {"pack": "es2", "world": "0", "zone": "123", "out": "user://es2_world_shot.png",
		"at": "0.5,0.5", "height": "12", "yaw": "30", "pitch": "-6"}
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.find("=") > 0:
			a[s.substr(2, s.find("=") - 2)] = s.substr(s.find("=") + 1)
	var t0 := Time.get_ticks_msec()
	var built := WorldBuilder.build(self, int(a.world), int(a.zone), String(a.pack))
	print("build: %d ms, palette %s" % [Time.get_ticks_msec() - t0, built.get("palette", "?")])
	var at := String(a.at).split(",")
	var pos := Vector3.ZERO
	var ti: Dictionary = built.get("terrain", {})
	if not ti.is_empty():
		var ext: Array = ti.extent_m
		var org: Array = ti.origin
		# origin = engine (x, z) of the north-west sample; original y (north) = -z
		pos.x = float(org[0]) + float(at[0]) * float(ext[0])
		pos.z = float(org[1]) + float(ext[1]) * (1.0 - float(at[1]))
	else:
		pos.x = float(at[0]) * 200.0
		pos.z = -float(at[1]) * 200.0
	var gy := WorldBuilder.ground_height(self, pos)
	pos.y = gy + float(a.height)
	print("camera at ", pos, " ground ", gy)
	var cam := Camera3D.new()
	cam.far = 6000.0
	cam.near = 0.2
	cam.fov = 60.0
	add_child(cam)
	cam.position = pos
	cam.rotation = Vector3(deg_to_rad(float(a.pitch)), -deg_to_rad(float(a.yaw)), 0.0)
	cam.current = true
	for i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(String(a.out))
	print("saved ", a.out)
	get_tree().quit()
