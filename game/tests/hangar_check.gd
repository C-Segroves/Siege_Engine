extends Node
## Headless check of the hangar every campaign uses: the Earthsiege start garage from CAR_INIT.DAT
## (Hercs, weapons per hardpoint, missile racks with their guidance), the loadout editor only offering
## Herc-family weapons on Herc hardpoints - and the 3D hangar (HangarBay) every Herc selection screen
## renders: Hercs of every pack standing on the floor at true size, weapon pods, hardpoints, camera
## framing, infantry armor shapes, and the mission Herc that briefings offer first.
## The garage model itself (build, scrap, arm, saga carry) is tests/garage_check.
##   godot --headless --audio-driver Dummy --path game res://tests/hangar_check.tscn


func _ready() -> void:
	_check_start_garage()
	_check_weapon_families()
	_check_original_colours()
	await _check_bay()
	_check_mission_herc()
	get_tree().quit()


func _check_start_garage() -> void:
	var g := Es1Tech.make_start_garage()
	for e in g.vehicles:
		print("garage: %s %s loadout=%s" % [e.vehicle, e.name, e.loadout])
	print("armory: ", g.stock)
	print("battle entry: ", g.make_battle_entry())


## Herc hardpoints only list "herc" weapons (weapon families never mix).
func _check_weapon_families() -> void:
	var bad := 0
	var editor := LoadoutEditor.new()
	for v in Packs.pilotable([], "herc"):
		editor.setup(str(v.id), [], {})
		for ids in editor._choices:
			for wid in ids:
				if str(wid) != "" and str(Packs.weapon(str(wid)).get("category", "herc")) != "herc":
					bad += 1
	editor.free()
	print("non-herc weapons offered on Herc hardpoints: ", bad)


## Herc skins use the original colour lookups (docs/formats/world.md section 4, es2.md section 3.3):
## Earthsiege 2 shade slots go through WORLD<n>.DPL's lists and texels through WORLD<n>.RMP, never to the
## DPL's green placeholders; colourless TSPolys (RAPTOR's black plate, part id 13) build no mesh.
func _check_original_colours() -> void:
	var fails := 0
	var es2_palette := Packs.default_palette("es2")
	for vid in ["es2:OUTLAW", "es2:APOCA", "es2:OGRE"]:
		var off_ramp := _off_ramp_shades(Assets.shape(vid), es2_palette)
		fails += off_ramp
		print("colours: %s shaded polys outside the shade ramps %d" % [vid, off_ramp])
	var green := _placeholder_texels(es2_palette)
	fails += green
	print("colours: %s texel light levels on green placeholders %d" % [es2_palette, green])
	var raptor := ShapeInstance.new()
	raptor.build(Assets.shape("es1:RAPTOR"), 0, Packs.default_palette("es1"))
	var black := _solid_black_surfaces(raptor)
	fails += black
	print("colours: es1:RAPTOR solid black surfaces %d" % black)
	raptor.free()
	print("colours check: %d failures" % fails)


## Shaded polys whose lit colour falls in the UI / VGA block 0x00-0x1F instead of an object shade ramp
## (the symptom of a missing shade-list table: slot 2 drew palette[2], VGA green).
func _off_ramp_shades(sdef: Dictionary, palette_id: String) -> int:
	var shade: Image = (Palette.look(palette_id).shade as ImageTexture).get_image()
	var bad := 0
	for piece in sdef.lods[0].pieces:
		for poly in piece.polys:
			if ShapeInstance.is_drawn(poly) and poly.m.kind == "shade":
				bad += int(shade.get_pixel(shade.get_width() - 1, int(poly.m.index)).r8 < FIRST_RAMP_INDEX)
	return bad


## Texel light remaps (Herc texels 0x60-0xFF, every light level) that land on a bright-green placeholder.
func _placeholder_texels(palette_id: String) -> int:
	var texlight: Image = (Palette.look(palette_id).texlight as ImageTexture).get_image()
	var bad := 0
	for level in texlight.get_height():
		for c in range(FIRST_HERC_TEXEL, 256):
			bad += int(_is_placeholder(palette_id, texlight.get_pixel(c, level).r8))
	return bad


## Palette layout (docs/formats/world.md 3.1): 0x00-0x1F UI and grey ramp; shade ramps sit above.
const FIRST_RAMP_INDEX := 0x20
## Lowest palette index in the Earthsiege 2 Herc texture sets (scan of textures/*/*.png).
const FIRST_HERC_TEXEL := 0x60


static func _is_placeholder(palette_id: String, index: int) -> bool:
	var c := Assets.palette_color(palette_id, index)
	return c.g8 > 200 and c.r8 < 60 and c.b8 < 60


static func _solid_black_surfaces(shape: ShapeInstance) -> int:
	var n := 0
	for mi in shape.find_children("*", "MeshInstance3D", true, false):
		var mesh := (mi as MeshInstance3D).mesh
		if not (mi as MeshInstance3D).visible:
			continue
		for s in mesh.get_surface_count():
			var mat := mesh.surface_get_material(s) as StandardMaterial3D
			if mat and mat.albedo_color == Color.BLACK:
				n += 1
	return n


func _check_bay() -> void:
	var bay: HangarBay = load("res://engine/hangar/hangar_bay.tscn").instantiate()
	add_child(bay)
	await get_tree().process_frame
	var fails := 0
	var dist := {}
	for vid in ["es1:RAPTOR", "es1:SCORPION", "bd:THOR", "es2:OGRE", "starsiege:cy_exec", "starsiege:kn_basl", "tribes:larmor", "tribes2:light_male",
			"tribes:SCOUT", "tribes2:SHRIKE", "tribes2:BEOWULF", "tribes2:THUNDERSWORD"]:
		var v := Packs.vehicle(vid)
		if v.is_empty() and Assets.shape(vid).get("lods", [{}])[0].get("pieces", []).is_empty():
			print("bay: %s not installed, skipped" % vid)
			continue
		bay.show_herc(vid, v.get("loadout", []))
		await get_tree().process_frame
		await get_tree().process_frame
		var low := INF
		for mi in bay.model.find_children("*", "MeshInstance3D", true, false):
			var m := mi as MeshInstance3D
			if m.is_visible_in_tree():
				var bb: AABB = m.global_transform * m.mesh.get_aabb()
				low = minf(low, bb.position.y)
		var cam_d := bay.camera.global_position.distance_to(Vector3(0, bay.herc_height * 0.5, 0))
		dist[vid] = cam_d
		var weapons := bay.model.find_children("weapon*", "ShapeInstance", true, false).size()
		var want_h := float(v.get("height_m", bay.herc_height))
		var ok := absf(low) < 0.15 and bay.herc_height > 1.0 and (v.is_empty() or absf(bay.herc_height - want_h) < want_h * 0.25 + 0.5)
		if not ok:
			fails += 1
		print("bay: %-20s h=%5.1f m (catalog %5.1f) feet y=%+.2f  hardpoints %d  weapon pods %d  camera %.1f m  %s" % [vid,
			bay.herc_height, want_h, low, bay.hardpoint_count(), weapons, cam_d, "ok" if ok else "FAIL"])
		if bay.hardpoint_count() > 0:
			bay.highlight_hardpoint(bay.hardpoint_count() - 1)
			await get_tree().process_frame
			var p: Variant = bay.hardpoint_position(bay.hardpoint_count() - 1)
			if not p is Vector3:
				fails += 1
				print("bay:   hardpoint marker missing")
			bay.highlight_hardpoint(-1)
	# loadout change on the same Herc only swaps pods
	bay.show_herc("es1:RAPTOR", Packs.vehicle("es1:RAPTOR").get("loadout", []))
	await get_tree().process_frame
	var before := bay.model
	bay.show_herc("es1:RAPTOR", ["", "", "", ""])
	await get_tree().process_frame
	await get_tree().process_frame
	var pods := bay.model.find_children("weapon*", "ShapeInstance", true, false).filter(func(n): return not (n as Node).is_queued_for_deletion()).size()
	print("bay: emptied loadout -> same model %s, pods %d" % [before == bay.model, pods])
	if dist.has("tribes:larmor") and dist.has("starsiege:cy_exec") and dist["tribes:larmor"] >= dist["starsiege:cy_exec"]:
		fails += 1
		print("bay: camera does not frame by size")
	print("bay check: %d failures" % fails)
	bay.queue_free()


func _check_mission_herc() -> void:
	Session.saga = null
	Session.campaign = CampaignES2.start(1)
	print("mission herc es2 %s: %s" % [Session.campaign.current_mission(), Session.mission_herc()])
	Session.campaign = load("res://games/starsiege/campaign_provider.gd").start("human")
	print("mission herc starsiege %s: %s" % [Session.campaign.current_mission(), Session.mission_herc()])
	Session.start_campaign(0, false)
	print("mission herc es1 %s: %s (player's choice)" % [Session.campaign.current_mission(), Session.mission_herc()])
	var cfg := Session.mission_config({1: {"name": "T", "vehicle": "bd:THOR", "team": 0, "loadout": []}})
	cfg["use_mission_herc"] = false
	print("mission config roster vehicle: ", cfg.roster[1].vehicle)
	Session.campaign = null
