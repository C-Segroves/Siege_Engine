extends Node
## Headless smoke test of a Starsiege campaign mission:
##   godot --headless --path game res://tests/test_starsiege_mission.tscn -- HA0 [--ss-debug]
## Loads the mission into a Battle, lets the script run, then plays the objectives the quick way
## (HA0: teleport to Nav Alpha, destroy the downed flyer, go to Nav Bravo) and reports the debrief.
## Other missions: runs 60 s of simulated time and reports script errors / spawned units.

var mid := "HA0"
var battle: Node
var t := 0.0
var stage := 0
var result := {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			mid = a.to_upper()
	Engine.time_scale = 4.0
	battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "mission_name": "starsiege:" + mid, "respawn": false,
		"roster": {1: {"name": "Tester", "vehicle": "starsiege:pi_eman", "team": 0, "loadout": []}}}
	battle.match_finished.connect(func(r): result = r)
	get_tree().root.add_child.call_deferred(battle)


func _process(delta: float) -> void:
	if _step(delta):
		get_tree().quit()


func _step(delta: float) -> bool:
	t += delta
	var ms = battle.get("mission") if battle else null
	if ms == null:
		return t > 30.0
	if t > 1.0 and stage == 0:
		stage = 1
		var n := 0
		for id in ms.objs:
			if ms.objs[id].kind in ["herc", "tank", "flyer"] and ms.objs[id].node != null:
				n += 1
		print("spawn xf ", ms.player_spawn(0).origin, " drops ", ms.m.get("drop_points", []).size())
		print("mission %s: %d objects, %d vehicles spawned, %d structures, map terrain=%s, player at %s" % [
			mid, ms.objs.size(), n, ms.structures.size(), ms.m.get("has_terrain"),
			battle.player.global_position if battle.player else "none"])
	if mid == "HA0":
		_ha0(ms)
	elif t > 60.0 and stage < 9:
		stage = 9
		print("ran 60 s; timers pending %d; inventory calls %d" % [ms.timers.size(), ms.inventory_changes.size()])
		return true
	if not result.is_empty():
		print("RESULT ", result.get("success"), " code ", result.get("code"))
		print(String(result.get("text", "")).left(200))
		return true
	return t > 400.0


func _ha0(ms) -> void:
	var p: Node3D = battle.player
	if p == null:
		return
	if stage == 1 and t > 8.0:
		stage = 2
		var nav: Vector3 = ms._obj_pos(ms.ss_resolve("MissionGroup/navMarkers/navAlpha"))
		p.global_position = nav + Vector3(0, 5, 150)
		print("teleported to Nav Alpha ", nav)
	elif stage == 2 and t > 20.0:
		stage = 3
		var f: int = ms.ss_resolve("MissionGroup/flyerGroup/Flyer1")
		print("destroying flyer ", f)
		ms.ss_builtin("damageobject", [f, 1e9])
	elif stage == 3 and t > 30.0:
		stage = 4
		var g: int = ms.ss_resolve("MissionGroup/guardGroup/guard1")
		ms.ss_builtin("damageobject", [g, 1e9])
		var nav: Vector3 = ms._obj_pos(ms.ss_resolve("MissionGroup/navMarkers/navBravo"))
		p.global_position = nav + Vector3(0, 5, 0)
		print("guard destroyed, teleported to Nav Bravo ", nav)
