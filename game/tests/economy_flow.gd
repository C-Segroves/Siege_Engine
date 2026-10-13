extends "res://tests/e2e_driver.gd"
## QA end-to-end flows of the campaign economy and crew (docs/formats/campaign_availability.md
## sections 7-8), played through the real screens:
##   Godot --path game --audio-driver Dummy res://tests/economy_flow.tscn -- --flow=<flow> --shots=<dir>
## Flows:
##   es2_economy  Earthsiege 2 from the launcher, two missions: the wingmen fly with the garage's Hercs
##                and pilots, one dies and is replaced, the player's damage is kept, salvage tonnage
##                changes, repairs cost salvage; screenshots of the Hangar screen's economy and Crew tab
##   es1_crew     the original shell's CREW button opens the Hangar screen on its Crew tab
## Screenshots are named economy_<name>.png in --shots.

## Player condition left after the first mission: every other component at PLAYER_DAMAGE -/+
## DAMAGE_SPREAD (the worse ones show their damaged look in the hangar).
const PLAYER_DAMAGE := 0.6
const DAMAGE_SPREAD := 0.3


func _run() -> void:
	get_tree().current_scene = null
	match flow:
		"es2_economy":
			await flow_es2_economy()
		"es1_crew":
			await flow_es1_crew()
		_:
			fail("unknown flow '%s'" % flow)
	log_line("DONE %d failures (%.0f s)" % [fails, (Time.get_ticks_msec() - _t0) / 1000.0])
	print("E2E DONE %d failures" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func save_shot(file_name: String) -> void:
	if shots == "":
		return
	await RenderingServer.frame_post_draw
	var p := shots.path_join("economy_%s.png" % file_name)
	get_viewport().get_texture().get_image().save_png(p)
	log_line("shot " + p)


# ------------------------------------------------------------------ Earthsiege 2

func flow_es2_economy() -> void:
	var l := open_scene("res://launcher.tscn") as Launcher
	await wait_screen("menu")
	LauncherAutomation._start_campaign_of("es2")
	l.show_campaign()
	if not await wait_screen("briefing", 30):
		return
	await wait(1.0)
	var g := Session.garage()
	var pool0 := g.salvage_kg
	var slots := Session.wingman_slots()
	log_line("ES2 start: pool %d kg, %d Hercs, %d wingman slots, squad %s" % [pool0, g.vehicles.size(), slots,
		SquadRoster.make_squad_config(g, slots).map(func(w): return w.name)])
	expect(pool0 >= 100000 and pool0 <= 110000, "start pool 100..110 t (%d)" % pool0)
	var b := await launch_from_briefing()
	if b == null:
		return
	var wingmen := garage_wingmen(b)
	log_line("wingmen in battle: %s" % wingmen.map(func(h): return "%s %s %.0f%%" % [h.display_name, h.vehicle_id, h.integrity * 100.0]))
	expect(wingmen.size() == mini(slots, SquadRoster.make_squad(g, slots).size()) and wingmen.size() > 0, "the squad's wingmen fly with their garage Hercs (%d)" % wingmen.size())
	expect(b.player != null and b.player.has_meta("garage"), "the player's garage Herc carries its garage tag")
	await save_shot("battle_squad")
	var victim: Herc = wingmen[0] if not wingmen.is_empty() else null
	var victim_pilot := str((victim.get_meta("garage") as Dictionary).get("pilot_id", "")) if victim else ""
	var victim_slot := int(g.crew.pilot(victim_pilot).get("slot", -1))
	var victim_name := str(g.crew.pilot(victim_pilot).get("name", ""))
	while victim and victim.alive:
		victim.apply_hit(1e6, 1e6, null, victim.global_position)
		await get_tree().physics_frame
	await wait(0.5)
	var r := await win_keeping_damage(b)
	log_line("result: success %s salvage_kg %s squad %s" % [r.get("success"), r.get("salvage_kg"),
		(r.get("squad", []) as Array).map(func(row): return "%s alive=%s" % [row.uid, row.alive])])
	await pass_results("es2_m1")
	if not await wait_screen("debrief", 40):
		return
	await click_text("Continue")
	await wait(1.5)
	g = Session.garage()
	var replacement := str(g.crew.pilot_in_slot(victim_slot).get("name", ""))
	log_line("after mission 1: pool %d -> %d kg; losses %d; %s replaced by %s; report %s" % [pool0, g.salvage_kg,
		g.crew.losses(), victim_name, replacement, g.last_report])
	expect(g.salvage_kg != pool0, "salvage tonnage changed (%d -> %d)" % [pool0, g.salvage_kg])
	expect(g.crew.losses() == 1 and replacement != "" and replacement != victim_name, "%s died and was replaced by %s" % [victim_name, replacement])
	var player_pc := HercCondition.make_percent(str(g.selected_entry().vehicle), g.selected_entry().condition)
	expect(player_pc < 100, "the player's Herc came back damaged (%d %%)" % player_pc)
	await hangar_repair_and_shots()
	var pool1 := Session.garage().salvage_kg
	b = await launch_from_briefing()
	if b == null:
		return
	r = await win_keeping_damage(b)
	await pass_results("es2_m2")
	if await wait_screen("debrief", 40):
		await click_text("Continue")
		await wait(1.5)
	log_line("after mission 2: pool %d -> %d kg, salvage %s" % [pool1, Session.garage().salvage_kg, r.get("salvage_kg")])
	expect(Session.garage().salvage_kg != pool1, "tonnage changed again after mission 2 (%d -> %d)" % [pool1, Session.garage().salvage_kg])


## From the briefing: Launch mission, wait for the battle to settle.
func launch_from_briefing() -> Battle:
	if not await wait_screen("briefing", 30):
		return null
	await wait(0.8)
	(cur().current as Object).get("_garage_picker").select_garage()   # the garage's Herc, not the mission's
	await click_text("Launch mission")
	if not await wait_scene_class("Battle", 90):
		return null
	await wait(3.0)
	log_line(describe_battle(battle()))
	return battle()


## The battle's AI garage Hercs (wingmen).
func garage_wingmen(b: Battle) -> Array:
	return b.vehicles.values().filter(func(h): return is_instance_valid(h) and h.has_meta("garage") and h.has_meta("ai"))


## Wins the mission without healing the player: the player is left at PLAYER_DAMAGE, the hostiles are
## destroyed, the nav points visited; the mission's success is forced when it does not end by itself.
func win_keeping_damage(b: Battle, sec := 25.0) -> Dictionary:
	var player := b.player
	var t := Time.get_ticks_msec()
	while not b.is_over() and Time.get_ticks_msec() - t < int(sec * 1000.0):
		if player and is_instance_valid(player) and player.alive:
			for k in player.components.size():
				var c: Dictionary = player.components[k]
				c.hp = c.max * (PLAYER_DAMAGE - DAMAGE_SPREAD if k % 2 == 0 else PLAYER_DAMAGE + DAMAGE_SPREAD)
			player.integrity = HercDamage.integrity_of(player.components)
			player.shield_front = player.shield_max
			player.shield_rear = player.shield_max
			for v in get_tree().get_nodes_in_group("vehicles"):
				if is_instance_valid(v) and v.team != player.team and v.alive:
					v.apply_hit(1e6, 1e6, player, v.global_position)
			_step_to_next_nav(b, player)
		for i in 10:
			await get_tree().physics_frame
	if not b.is_over() and b.mission:
		log_line("forcing the mission's success")
		b.mission.end_mission(true, 2, "QA forced success")
	await wait(1.0)
	return b.result


## Briefing -> Hangar: the economy (pool, condition, Repair) and the Crew tab, screenshots, repair.
func hangar_repair_and_shots() -> void:
	if not await wait_screen("briefing", 30):
		return
	await click_text("Hangar: build, scrap, arm")
	if not await wait_screen("hangar", 5):
		return
	await wait(1.5)
	var hs := cur().current as HangarScreen
	var g := hs.garage
	var cost := g.make_repair_cost(hs.make_context(), g.selected)
	log_line("hangar: pool %d kg, repair %d kg, status '%s'" % [g.salvage_kg, cost, _status(hs)])
	expect(cost > 0, "repairing the damaged Herc costs salvage (%d kg)" % cost)
	await save_shot("hercs")
	var pool := g.salvage_kg
	var repair := find_button("Repair", hs)
	if expect(repair != null and not repair.disabled, "Repair button offered"):
		await click(repair, "Repair")
		await wait(0.6)
		expect(g.salvage_kg < pool, "repair paid (%d -> %d kg)" % [pool, g.salvage_kg])
		await save_shot("hercs_repaired")
	hs.show_tab(HangarScreen.TAB_CREW)
	await wait(1.0)
	await save_shot("crew")
	await click(hs.primary_button, "Back to briefing")
	await wait_screen("briefing", 5)


# ------------------------------------------------------------------ Earthsiege shell

func flow_es1_crew() -> void:
	open_scene("res://library.tscn")
	await wait_screen("home")
	await wait(1.0)
	await click_text("Metaltech: Earthsiege (original game)")
	await wait_scene_class("EsShell", 20)
	if not await shell_wait_menu(EsShell.MAIN_MENU, 120):
		return
	await shell_click(EsShell.CAREER_MENU)
	await wait(0.6)
	await shell_click(EsShell.REGISTER_MENU)
	await wait(0.6)
	ShellDebug._type_text("QACREW")
	await wait(0.3)
	ShellDebug.tap_action("ui_accept")
	await wait(0.8)
	await shell_click(EsShell.HANGAR_HUB)
	if not await shell_wait_menu(EsShell.HANGAR_HUB, 180):
		return
	await shell_click(ShellHangar.CREW_COMMAND)
	await wait(1.0)
	var hs := _find_hangar_screen()
	if expect(hs != null, "CREW opens the Hangar screen"):
		var crew_shown := hs._tabs[HangarScreen.TAB_CREW].visible as bool
		expect(crew_shown, "on its Crew tab")
		await save_shot("es1_crew")
		hs.show_tab(HangarScreen.TAB_HERCS)
		await wait(0.8)
		await save_shot("es1_hercs")
		await click(hs.back_button, "hangar Back")
		await wait(0.6)
	_remove_test_career("QACREW")


## Drops the test career (its pilot's autosave) again.
func _remove_test_career(career_name: String) -> void:
	var sh := shell_node()
	if sh == null:
		return
	var i: int = sh.careers.index_of(career_name)
	if i >= 0:
		sh.careers.remove_at(i)
