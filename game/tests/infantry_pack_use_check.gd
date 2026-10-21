extends Node
## Packs and repair kits used with the real keys (docs/formats/tribes_infantry.md section 6): in an infantry battle of
## each Tribes game the key event is parsed like a keyboard press (InputEventKey through Input.parse_input_event),
## so the whole chain runs: SiegeInput bindings, the Gear director's input, the host rules, the HUD line and sound.
##   1 the defaults: R and P use the backpack (Tribes 2 / Tribes 1), H the repair kit, shown in the HUD kit line;
##   2 the repair kit: heals the original amount over the original time (T1 at once, T2 applyRepair), the count drops,
##     a sound and a line tell it, a full-health or empty kit refuses with a line and keeps the kit;
##   3 every pack the game models: the toggled ones switch on and off and do their job, the passive ones say so,
##     a pack with too little energy refuses, no pack says so, deployables place their object;
##   4 the loadout slot's backpack, grenade type and counts reach the spawn and the respawn.
##   godot --headless --audio-driver Dummy --path game res://tests/infantry_pack_use_check.tscn [-- --shots=<dir>]
## --shots (needs a window): pack_use_*.png of the HUD feedback.

const GAMES := [
	{"pack": "tribes", "map": "tribes:Raindance", "kit": "tribes:REPAIR_KIT", "kit_seconds": 0.0},
	{"pack": "tribes2", "map": "tribes2:Katabatic", "kit": "tribes2:REPAIR_KIT", "kit_seconds": 1.94},
]
const SETTLE_FRAMES := 20
const HURT := 1500.0
const DEPLOY_PITCHES := [-0.35, -0.5, -0.7, -1.0]
const SITE_RINGS := [0, 1, 2, 3, 4, 5, 6]
const SITE_DIRECTIONS := 8
const SITE_RING_STEP_M := 25.0
const SITE_CLEAR_M := 30.0
const SITE_LEVEL_M := 1.5

var _failures := 0
var _shots := ""
var _start := Vector3.ZERO
var _deploys := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_defaults()
	for g in GAMES:
		if not Assets.has_pack(str(g.pack)):
			print("%s not installed: skipped" % g.pack)
			continue
		var battle := await _start_battle(g)
		await _check_kit(battle, g)
		await _check_packs(battle, g)
		await _check_slot_spawn(battle, g)
		battle.queue_free()
		await _frames(5)
	print("infantry_pack_use_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s, true, true).timeout


func _shot(battle: Battle, tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
	await RenderingServer.frame_post_draw
	var path := "%s/pack_use_%s.png" % [_shots, tag]
	battle.get_viewport().get_texture().get_image().save_png(path)
	print("  shot ", path)


## The first keyboard key bound to `action`, pressed and released as a keyboard would deliver it.
func _press_bound_key(action: String) -> void:
	var bound: InputEventKey = null
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			bound = ev
			break
	_expect(bound != null, "%s has a keyboard key" % action)
	if bound != null:
		_send_key(bound.physical_keycode)
	await _frames(2)


func _send_key(code: Key) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.physical_keycode = code
		ev.keycode = code
		ev.pressed = pressed
		Input.parse_input_event(ev)
		Input.flush_buffered_events()


# ------------------------------------------------------------------ 1 defaults

func _check_defaults() -> void:
	print("1 defaults:")
	var keys := {}
	for action in ["pack_use", "repair_kit_use"]:
		keys[action] = InputMap.action_get_events(action).filter(func(e: InputEvent) -> bool: return e is InputEventKey) \
			.map(func(e: InputEventKey) -> int: return e.physical_keycode)
	_expect(keys.pack_use.has(KEY_R) and keys.pack_use.has(KEY_P), "pack_use: R (Tribes 2 useBackpack) and P (Tribes 1 BackPack)")
	_expect(keys.repair_kit_use == [KEY_H], "repair_kit_use: H (Tribes 1 Repair Kit)")
	for context_action in ["pack_use", "repair_kit_use"]:
		for other in BindingContexts.make_peers(context_action):
			if other == context_action or not InputMap.has_action(other):
				continue
			var clash := InputMap.action_get_events(other).any(func(e: InputEvent) -> bool:
				return e is InputEventKey and (keys[context_action] as Array).has((e as InputEventKey).physical_keycode))
			_expect(not clash, "%s does not share its key with %s" % [context_action, other])


# ------------------------------------------------------------------ battle

func _start_battle(g: Dictionary) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": g.map, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 500, "ai": [], InfantryBots.CONFIG_KEY: 0}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	print("%s on %s:" % [g.pack, g.map])
	_start = (battle.player as Infantry).global_position
	_deploys = 0
	return battle


func _soldier_in(battle: Battle, armor_id: String, pack_id: String) -> Infantry:
	var s := battle.player as Infantry
	if not s.alive:
		s.respawn(Transform3D(Basis(), s.global_position))
	s.apply_armor(armor_id, (InfantryCatalog.armor(armor_id).get("default_loadout", []) as Array).duplicate(), "", pack_id)
	s.end_spawn_protection()
	s.velocity = Vector3.ZERO
	s.kit.heal_left = 0.0
	s.capacitor = s.capacitor_max
	var hp: Dictionary = s.components[0]
	hp.hp = hp.max
	s.integrity = 1.0
	return s


func _hurt(s: Infantry, amount: float) -> void:
	var c: Dictionary = s.components[0]
	c.hp = maxf(1.0, float(c.max) - amount)
	s.integrity = HercDamage.integrity_of(s.components)


func _hp(s: Infantry) -> float:
	return float(s.components[0].hp)


func _notice(battle: Battle) -> String:
	return battle.infantry.gear.notice_text if battle.infantry.gear.is_notice_shown() else ""


func _clear_notice(battle: Battle) -> void:
	battle.infantry.gear.notice_text = ""
	battle.infantry.gear.notice_until_ms = 0


# ------------------------------------------------------------------ 2 repair kit

func _check_kit(battle: Battle, g: Dictionary) -> void:
	print(" repair kit:")
	var light := "%s:LIGHT" % g.pack
	var s := _soldier_in(battle, light, "")
	var record := InfantryGear.item(str(g.kit))
	var amount := float(record.repair)
	var n0 := s.kit.count(str(g.kit))
	_expect(n0 >= 1, "spawns with a repair kit (%d)" % n0)
	_expect(is_equal_approx(amount, 600.0) and absf(float(record.repair_s) - float(g.kit_seconds)) < 0.05,
		"original kit: %.0f points (0.2 of 3000) over %.2f s" % [amount, float(record.repair_s)])
	var kit_line := InfantryHud.make_kit_text(s)
	_expect(kit_line.contains("[H] Repair Kit %d" % n0), "HUD kit line shows the key and the count: %s" % kit_line)
	# full health: refused, the kit is kept, the line says why
	_clear_notice(battle)
	await _press_bound_key("repair_kit_use")
	_expect(s.kit.count(str(g.kit)) == n0 and _notice(battle).contains("full"), "full health: kit kept, '%s'" % _notice(battle))
	# hurt: heals, over time in Tribes 2
	_hurt(s, HURT)
	var hp0 := _hp(s)
	_clear_notice(battle)
	await _press_bound_key("repair_kit_use")
	var hp1 := _hp(s)
	_expect(s.kit.count(str(g.kit)) == n0 - 1, "H: the count drops (%d -> %d)" % [n0, s.kit.count(str(g.kit))])
	_expect(_notice(battle).begins_with("Repair Kit used") and _notice(battle).contains("%d left" % (n0 - 1)), "line: '%s'" % _notice(battle))
	_expect(battle.infantry.gear.heal_flash_until_ms > Time.get_ticks_msec(), "the HUD flashes green")
	var sfx := Sfx.stream(InfantryGear.sound(str(g.pack), "kit"))
	_expect(sfx != null and Sfx.ui_player.stream == sfx, "the kit sound plays (%s)" % InfantryGear.sound(str(g.pack), "kit"))
	if float(g.kit_seconds) > 0.0:
		_expect(hp1 > hp0 and hp1 < hp0 + amount, "health rises over time, not at once (%.0f -> %.0f)" % [hp0, hp1])
		await _seconds(float(g.kit_seconds) * 0.5)
		var mid := _hp(s)
		_expect(mid > hp1 + 100.0 and mid < hp0 + amount - 100.0, "half way through: %.0f" % mid)
		await _shot(battle, "%s_kit_mid" % g.pack)
		await _seconds(float(g.kit_seconds) * 0.5 + 0.5)
	else:
		_expect(is_equal_approx(hp1, hp0 + amount), "heals %.0f at once (%.0f -> %.0f)" % [amount, hp0, hp1])
		await _shot(battle, "%s_kit" % g.pack)
	_expect(is_equal_approx(_hp(s), hp0 + amount), "%.0f healed in all (%.0f)" % [amount, _hp(s) - hp0])
	# no kit left
	s.kit.counts[str(g.kit)] = 0
	_hurt(s, HURT)
	_clear_notice(battle)
	await _press_bound_key("repair_kit_use")
	_expect(is_equal_approx(_hp(s), float(s.components[0].max) - HURT) and _notice(battle).contains("No Repair Kit"),
		"no kit: nothing heals, '%s'" % _notice(battle))


# ------------------------------------------------------------------ 3 packs

## The first armour of the game that may wear `pack_id`.
func _armor_for(game: String, pack_id: String) -> String:
	for a in InfantryCatalog.armors_of(game):
		if (a.get("packs", []) as Array).has(pack_id):
			return str(a.id)
	return ""


func _check_packs(battle: Battle, g: Dictionary) -> void:
	print(" packs:")
	var s := _soldier_in(battle, "%s:LIGHT" % g.pack, "")
	_clear_notice(battle)
	await _press_bound_key("pack_use")
	_expect(not s.kit.pack_active and _notice(battle).contains("No backpack"), "no pack: '%s'" % _notice(battle))
	var seen := 0
	for p in InfantryGear.all_packs():
		var pid := str(p.id)
		if not pid.begins_with(str(g.pack) + ":") or not bool(p.get("mapped", false)):
			continue
		var armor_id := _armor_for(str(g.pack), pid)
		if armor_id == "":
			continue
		seen += 1
		s = _soldier_in(battle, armor_id, pid)
		_expect(s.kit.pack_id == pid, "%s worn in %s" % [p.name, armor_id])
		match str(p.effect):
			"shield", "repair", "jammer", "cloak":
				await _check_toggled(battle, s, p)
			"energy", "ammo":
				await _check_passive(battle, s, p)
			"deploy":
				await _check_deploy(battle, s, p)
	_expect(seen >= 5, "%d packs tried" % seen)
	# a switched pack needs its minimum energy
	var shield := "%s:SHIELD_PACK" % g.pack
	s = _soldier_in(battle, _armor_for(str(g.pack), shield), shield)
	s.capacitor = 0.0
	_clear_notice(battle)
	await _press_bound_key("pack_use")
	_expect(not s.kit.pack_active and _notice(battle).contains("not enough energy"), "no energy: stays off, '%s'" % _notice(battle))
	var fail := Sfx.stream(InfantryGear.sound(str(g.pack), "pack_fail"))
	_expect(fail != null and Sfx.ui_player.stream == fail, "the refusal sound plays")
	# P does the same as R
	s.capacitor = s.capacitor_max
	_send_key(KEY_P)
	await _frames(2)
	_expect(s.kit.pack_active, "P switches the pack on as well")
	_send_key(KEY_R)
	await _frames(2)
	_expect(not s.kit.pack_active, "R switches it off")


func _check_toggled(battle: Battle, s: Infantry, p: Dictionary) -> void:
	_clear_notice(battle)
	await _press_bound_key("pack_use")
	_expect(s.kit.pack_active and _notice(battle) == "%s ON" % p.name, "R: %s on, line '%s'" % [p.name, _notice(battle)])
	var sfx := Sfx.stream(str(p.get("use_sound", "")))
	_expect(str(p.get("use_sound", "")) == "" or (sfx != null and Sfx.ui_player.stream == sfx), "its sound plays (%s)" % p.get("use_sound", ""))
	var effect := str(p.effect)
	if effect == "shield":
		var hp0 := _hp(s)
		var e0 := s.capacitor
		s.apply_hit(0.0, 600.0, null)
		_expect(is_equal_approx(_hp(s), hp0) and s.capacitor < e0 - 5.0, "shield: the hit goes out of the energy (%.0f -> %.0f)" % [e0, s.capacitor])
		await _shot(battle, "%s_shield" % s.armor.pack)
	elif effect == "repair":
		_hurt(s, HURT)
		var hp0 := _hp(s)
		await _seconds(1.0)
		_expect(_hp(s) > hp0 + float(p.repair_per_s) * 0.6, "repair pack: heals %.0f in 1 s (%.1f points/s)" % [_hp(s) - hp0, float(p.repair_per_s)])
	elif effect == "jammer":
		_expect(InfantryPack.is_hidden_at(s, float(p.jam_radius) + 20.0) and not InfantryPack.is_hidden_at(s, 3.0), "jammer: hidden beyond %.0f m" % p.jam_radius)
	elif effect == "cloak":
		await _seconds(0.8)
		_expect(s.cloak.is_cloaked(), "cloak: the wearer is cloaked")
	_clear_notice(battle)
	await _press_bound_key("pack_use")
	_expect(not s.kit.pack_active and _notice(battle) == "%s OFF" % p.name, "R again: off, line '%s'" % _notice(battle))
	if effect == "jammer":
		await _frames(2)
		_expect(not s.has_meta("jam_radius"), "jammer off: seen again")
	if effect == "cloak":
		await _seconds(0.8)
		_expect(not s.cloak.is_cloaked(), "cloak off: visible")


func _check_passive(battle: Battle, s: Infantry, p: Dictionary) -> void:
	_clear_notice(battle)
	await _press_bound_key("pack_use")
	_expect(not s.kit.pack_active and _notice(battle).contains("always on"), "%s: passive, line '%s'" % [p.name, _notice(battle)])
	if str(p.effect) == "energy":
		_expect(InfantryPack.make_recharge_bonus(s.kit) > 0.0, "energy pack: recharge +%s/s" % str(InfantryPack.make_recharge_bonus(s.kit)))
	else:
		var w := s.weapons[0] as InfantryWeapon
		_expect(s.kit.make_extra_rounds(w.weapon_id) > 0 or s.kit.make_extra_rounds("%s:GRENADE" % s.armor.pack) > 0, "ammo pack: carries extra rounds")


func _check_deploy(battle: Battle, s: Infantry, p: Dictionary) -> void:
	var deployables := TribesDeployables.of(battle)
	if deployables == null:
		print("  (no deployables in this game)")
		return
	var base := TribesBase.of(battle)
	var before := base.objects.size()
	s.global_position = _test_site(battle, _deploys)
	_deploys += 1
	s.velocity = Vector3.ZERO
	s.torso_target = 0.0
	battle.pilot.set_physics_process(false)   # the pilot would put the look back to the mouse's
	var line := ""
	var placed := 0
	for pitch in DEPLOY_PITCHES:   # at the ground a few metres ahead: far enough to clear the soldier's own box
		s.pitch_target = pitch
		await _frames(10)
		_clear_notice(battle)
		await _press_bound_key("pack_use")
		placed = base.objects.size() - before
		line = _notice(battle)
		if placed > 0:
			break
	_expect(line != "", "%s: the key answers with a line '%s'" % [p.name, line])
	_expect((placed == 1 and line.ends_with("deployed")) or (placed == 0 and line != ""),
		"%s: placed (%d new) or refused with a reason" % [p.name, placed])
	s.pitch_target = 0.0
	battle.pilot.set_physics_process(true)


## The `skip`-th level spot around the first soldier's start (each deployable gets its own, clear of the others).
func _test_site(battle: Battle, skip := 0) -> Vector3:
	var origin := _start
	for ring in SITE_RINGS:
		for k in SITE_DIRECTIONS:
			var a := TAU * float(k) / SITE_DIRECTIONS
			var p: Vector3 = origin + Vector3(cos(a), 0, sin(a)) * ring * SITE_RING_STEP_M
			if not battle.bounds.bounds.is_outside(p) and _is_level_ahead(battle, p):
				if skip > 0:
					skip -= 1
					continue
				p.y = MapBuilder.ground_height(battle, p) + 0.3
				return p
	origin.y = MapBuilder.ground_height(battle, origin) + 0.3
	return origin


func _is_level_ahead(battle: Battle, p: Vector3) -> bool:
	var h0 := MapBuilder.ground_height(battle, p)
	for d in range(0, int(SITE_CLEAR_M) + 1, 5):
		if absf(MapBuilder.ground_height(battle, p + Vector3(0, 0, -d)) - h0) > SITE_LEVEL_M:
			return false
	return true


# ------------------------------------------------------------------ 4 the slot's kit

func _check_slot_spawn(battle: Battle, g: Dictionary) -> void:
	print(" loadout slot kit:")
	var game := str(g.pack)
	var armor_id := "%s:LIGHT" % game
	var armor := InfantryCatalog.armor(armor_id)
	var pack_id := "%s:SHIELD_PACK" % game
	var grenades := InfantryGear.grenades_of(armor)
	var grenade := str(grenades[grenades.size() - 1])
	var slot := {"a": armor_id, "w": armor.default_loadout, "g": {grenade: 2}, "p": pack_id}
	_expect(SpawnLoadout.make_kit({"slot": slot}, armor_id) == {"pack": pack_id, "grenade": grenade, "counts": {grenade: 2}},
		"the slot's gear is the spawn kit")
	_expect(SpawnLoadout.make_kit({"slot": slot}, "%s:HEAVY" % game).is_empty() and SpawnLoadout.make_kit({}, armor_id).is_empty(),
		"another armour or no slot: no kit")
	var peer := 91
	battle.config.roster[peer] = {"name": "Slotted", "team": 0, "slot": slot, "infantry_armor": armor_id}
	var s := battle.spawn_soldier_for(peer, 1, "Slotted", Transform3D(Basis(), (battle.player as Infantry).global_position + Vector3(6, 0, 0)))
	await _frames(3)
	_expect(s != null and s.kit.pack_id == pack_id and s.kit.grenade_id == grenade and s.kit.count(grenade) == 2,
		"spawns wearing %s with %s x2" % [pack_id, grenade])
	_expect(s.kit.count("%s:REPAIR_KIT" % game) >= 1, "and the armour's repair kit")
	s.kit.pack_id = ""
	s.kit.counts.clear()
	s.respawn(Transform3D(Basis(), s.global_position))
	await _frames(2)
	_expect(s.kit.pack_id == pack_id and s.kit.count(grenade) == 2, "the respawn brings the same kit")
	s.queue_free()
