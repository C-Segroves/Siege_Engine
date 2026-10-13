extends SceneTree
## Prints the converted vehicle catalog (sizes, speeds) for sanity checking.
func _initialize() -> void:
	await process_frame
	var packs = root.get_node("Packs")
	for v in packs.pilotable():
		print("%-14s %-6s h=%5.1f m  top=%5.1f km/h  rev=%4.1f  turn=%4.1f deg/s  torso=%3.0f deg  stride=%s" % [v.name, v.pack, v.get("height_m", 0.0), v.max_speed * 3.6, v.reverse_speed * 3.6, rad_to_deg(v.turn_rate), rad_to_deg(v.torso_limit), str(snapped(v.get("walk_factor", 0.0), 0.0001))])
	for id in ["es1:LAS100", "es1:ATC35", "es1:MLRS6", "es1:PBEAM"]:
		var w = packs.weapon(id)
		print("%-8s range %5.0f m  refire %.2f s  speed %5.0f m/s" % [w.name, w.range, w.refire, w.speed])
	quit()
