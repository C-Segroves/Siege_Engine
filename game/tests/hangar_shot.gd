extends Control
## Screenshots of the 3D hangar (HangarBay via HangarView) with one or more Hercs.
##   godot --path game res://tests/hangar_shot.tscn -- --hercs=es1:RAPTOR,bd:THOR --out=<dir/prefix>
##   [--point=<hardpoint>] [--pixelated] [--yaw=<radians>] [--size=1280x800]
##   [--zoom=<factor 0.5..3>] [--pitch=<radians>] [--loadout=<weapon id>|<weapon id>|...]   (one per hardpoint, "" = empty; default: the Herc's own)
##   [--packs=bd,es1]   (look-alike models only from these packs: WeaponLookalike.apply_pack_filter)
## Saves <prefix>_<pack>_<name>.png per Herc, then quits.


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var hercs: PackedStringArray = ["es1:RAPTOR"]
	var out := "user://hangar_shot"
	var point := -1
	var pix := false
	var yaw := 0.0
	var loadout: Array = []
	var zoom := 1.0
	var pitch := -1.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--hercs="):
			hercs = a.substr(8).split(",")
		elif a.begins_with("--out="):
			out = a.substr(6)
		elif a.begins_with("--point="):
			point = int(a.substr(8))
		elif a.begins_with("--loadout="):
			loadout = Array(a.substr(10).split("|"))
		elif a.begins_with("--packs="):
			WeaponLookalike.apply_pack_filter(Array(a.substr(8).split(",")))
		elif a.begins_with("--zoom="):
			zoom = float(a.substr(7))
		elif a.begins_with("--pitch="):
			pitch = float(a.substr(8))
		elif a == "--pixelated":
			pix = true
		elif a.begins_with("--yaw="):
			yaw = float(a.substr(6))
		elif a.begins_with("--size="):
			var s := a.substr(7).split("x")
			get_window().size = Vector2i(int(s[0]), int(s[1]))
	var view := HangarView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(view)
	view.pixelated = pix
	for vid in hercs:
		var v := Packs.vehicle(vid)
		view.show_herc(vid, loadout if not loadout.is_empty() else (v.get("loadout", []) as Array))
		view.bay.reset_view(true)
		view.bay.orbit_yaw = yaw
		view.bay.zoom = zoom
		if pitch >= 0.0:
			view.bay.orbit_pitch = pitch
		view.highlight_hardpoint(point)
		view.set_caption("%s  -  %s" % [str(v.get("name", vid)), Packs.pack_name(Assets.split_id(vid)[0])])
		await get_tree().create_timer(1.2).timeout
		await RenderingServer.frame_post_draw
		print("hangar_shot: %s height %.1f m radius %.1f m hardpoints %d" % [vid, view.bay.herc_height, view.bay.herc_radius, view.bay.hardpoint_count()])
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s_%s.png" % [out, vid.replace(":", "_")])
	get_tree().quit()
