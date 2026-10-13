extends Node
## Playtest 2026-10-11 group C (docs/PLAYTEST_2026-10-11.md), headless:
##   C1 Tribes 2 armour animations (.dsq through the TSShapeConstructor): run / back / side / fall / jet / land and
##      the eleven deaths are in the shapes; a dead soldier plays a death (every peer the same one)
##   C2 the hand weapons' image sequences: draw, fire, reload, ambient / spin roles, at the authored speed
##   C3 footsteps on the run cycle's foot triggers, the move cycle capped at MAX_TIME_SCALE; the originals' sound
##      profiles (T2 AudioClosest3d 5-30 m)
##   C4 items in the maps: exported, drawn, taken by touch when they give something, by interact (swap) when not;
##      one interact action (no loot_pickup)
##   C5 no infantry pack enabled: pilots cannot get out and see no exit hint; one pack: that one
##   godot --headless --audio-driver Dummy --path game res://tests/fix_c_check.tscn [-- --shots=<dir>]
## --shots (needs a window): fix_c_*.png (a Tribes 2 death, the run, the items of a map, the view model firing);
## the body poses and the weapon models: tests/infantry_strip.tscn.

const PICKUP_MAP := "tribes2:DustToDust"
const SETTLE_FRAMES := 30
## A light armour runs 14 m/s; its run cycle travels 4.02 m in 0.767 s (5.24 m/s): played 1.5 x (capped), two
## foot triggers per cycle -> 3.9 steps a second (the old rule, one step per 1.6 m, gave 8.75).
const RUN_SPEED := 14.0
const STEP_WINDOW := Vector2(3.0, 4.8)

var _failures := 0
var _shots := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	await get_tree().process_frame
	_check_t2_sequences()
	_check_catalog_api()
	_check_animation_timing()
	_check_footstep_sounds()
	_check_weapon_animations()
	_check_interact_action()
	_check_pack_choice()
	_check_fall_heights()
	await _check_pickups()
	await _check_no_infantry()
	print("fix_c_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _shot(tag: String) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	await _frames(4)
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


# ------------------------------------------------------------------ C1

func _check_t2_sequences() -> void:
	print("C1 Tribes 2 armour animations:")
	for body in ["tribes2:light_male", "tribes2:heavy_male", "tribes2:bioderm_light", "tribes2:light_female"]:
		var names := _seq_names(body)
		var deaths := names.filter(func(n: String) -> bool: return n.begins_with("death"))
		_expect(names.has("root") and names.has("run") and names.has("back") and names.has("side") and names.has("fall")
			and names.has("jet") and names.has("land") and deaths.size() >= 10,
			"%s: root run back side fall jet land + %d deaths" % [body, deaths.size()])
	var inst := _shape("tribes2:light_male")
	var anim := InfantryAnimation.new(inst)
	_expect(anim.death_count() == 11 and anim.make_death_name(1) == "death2", "11 deaths, picked by choice (death2)")
	var head := _node_index(inst, "bip01 head")
	var before: Vector3 = _node_world(inst, head)
	anim.apply_death(10.0, 1)
	var after: Vector3 = _node_world(inst, head)
	_expect(after.y < before.y - 0.8, "the death drops the head to the ground (%.2f -> %.2f m)" % [before.y, after.y])
	inst.free()


static func _node_index(inst: ShapeInstance, n: String) -> int:
	var nodes: Array = inst.shape.nodes
	for i in nodes.size():
		if str(nodes[i].name).to_lower() == n:
			return i
	return -1


static func _node_world(inst: ShapeInstance, i: int) -> Vector3:
	var n: Node3D = inst.nodes[i]
	var xf := Transform3D()
	while n != null and n != inst:
		xf = n.transform * xf
		n = n.get_parent() as Node3D
	return (inst.transform * xf).origin


func _check_catalog_api() -> void:
	print("infantry catalog API (agent D):")
	var packs := InfantryCatalog.make_infantry_packs().map(func(p: Dictionary) -> String: return str(p.pack))
	_expect(packs == ["tribes", "tribes2"], "installed infantry games: %s" % [packs])
	var armors := InfantryCatalog.make_armors("tribes2")
	_expect(armors.size() == 3 and str(armors[0].id) == "tribes2:LIGHT", "Tribes 2 armours, light first")
	var bodies := InfantryCatalog.make_bodies("tribes2:LIGHT")
	_expect(not bodies.is_empty() and str(bodies[0].id) == "tribes2:light_male"
		and bodies.any(func(b: Dictionary) -> bool: return bool(b.bioderm) and str(b.id) == "tribes2:bioderm_light"),
		"Tribes 2 light: its body first, a Bioderm body (%d bodies)" % bodies.size())
	_expect(str(InfantryCatalog.make_skins("tribes2:light_male")[0].id) == "", "skins: Default first")
	_expect(Infantry.make_matching_body("tribes2:MEDIUM", "Bioderm") == "tribes2:bioderm_medium",
		"a station's new armour keeps the Bioderm body")


# ------------------------------------------------------------------ C3

func _check_animation_timing() -> void:
	print("C3 footsteps on the foot triggers:")
	for body in ["tribes2:light_male", "tribes:larmor"]:
		var inst := _shape(body)
		var anim := InfantryAnimation.new(inst)
		var steps := 0
		var dt := 1.0 / 60.0
		for i in 120:
			anim.update(Vector3(0, 0, -RUN_SPEED), false, false, dt)
			steps += anim.footsteps.size()
		var per_second := steps / 2.0
		_expect(anim.has_foot_triggers() and per_second >= STEP_WINDOW.x and per_second <= STEP_WINDOW.y,
			"%s at %.0f m/s: %.1f steps a second" % [body, RUN_SPEED, per_second])
		var left := 0
		for i in 120:
			anim.update(Vector3(0, 0, -RUN_SPEED), false, false, dt)
			left += anim.footsteps.count(InfantryAnimation.LEFT_FOOT)
		_expect(left > 0 and left < steps, "%s: left and right feet alternate" % body)
		inst.free()


func _check_footstep_sounds() -> void:
	print("C3 footstep sounds:")
	var sounds: Dictionary = InfantryCatalog.armor("tribes2:LIGHT").get("sounds", {})
	var soft := InfantrySounds.make_footstep(sounds, InfantryAnimation.LEFT_FOOT, false)
	var hard := InfantrySounds.make_footstep(sounds, InfantryAnimation.RIGHT_FOOT, true)
	_expect(str(soft.stem) == "tribes2:light_lf_soft" and soft.range == Vector2(5, 30),
		"T2 left foot on terrain: light_LF_soft, AudioClosest3d 5-30 m")
	_expect(str(hard.stem) == "tribes2:light_rf_hard" and hard.range == Vector2(10, 60),
		"T2 right foot indoors: light_RF_hard, AudioClose3d 10-60 m")
	var t1 := InfantrySounds.make_footstep(InfantryCatalog.armor("tribes:LIGHT").get("sounds", {}), InfantryAnimation.LEFT_FOOT, false)
	_expect(str(t1.stem) == "tribes:lfootlsoft" and t1.range == Vector2(2, 30), "T1: SoundLFootLSoft, Profile3dFoot 2-30 m")


# ------------------------------------------------------------------ G2 (PLAYTEST_2026-10-11b)

## Drop heights (from rest, Tribes gravity 20 m/s^2) that just start to hurt and that kill, per armour, against the
## games' own data: T1 PlayerData minDamageSpeed 25, damageScale 0.005 / 0.006 (counted above the minimum,
## tribes.exe 0x4162d2); T2 minImpactSpeed 45, speedDamageScale 0.004 / 0.006 (the whole speed).
func _check_fall_heights() -> void:
	print("G2 fall damage per armour:")
	var g := Infantry.TRIBES_GRAVITY
	for id in ["tribes:LIGHT", "tribes:MEDIUM", "tribes:HEAVY", "tribes2:LIGHT", "tribes2:MEDIUM", "tribes2:HEAVY"]:
		var a := InfantryCatalog.armor(id)
		var least := float(a.fall_min_speed)
		var scale := float((a.damage_scale as Dictionary).get(str(a.fall_damage_type), 1.0))
		var kill_speed := _make_kill_speed(a, scale)
		print("    %s: hurts from %.1f m (%.0f m/s), kills from %.0f m (%.0f m/s)" % [id, least * least / (2.0 * g), least,
			kill_speed * kill_speed / (2.0 * g), kill_speed])
		_expect(InfantryMotion.make_fall_damage(a, least - 0.1) == 0.0, "%s: no damage below %.0f m/s" % [id, least])
	var t1 := InfantryCatalog.armor("tribes:LIGHT")
	_expect(is_equal_approx(InfantryMotion.make_fall_damage(t1, 30.0), 5.0 * 0.005 * 3000.0),
		"T1 light at 30 m/s: (30 - 25) x 0.005 x 3000 = 75")
	var t2 := InfantryCatalog.armor("tribes2:LIGHT")
	_expect(is_equal_approx(InfantryMotion.make_fall_damage(t2, 50.0), 50.0 * 0.004 * 3000.0),
		"T2 light at 50 m/s: 50 x 0.004 x 3000 = 600")


## The impact speed at which a fall takes the armour's whole health (scaled by its fall damage type).
static func _make_kill_speed(a: Dictionary, scale: float) -> float:
	var per := float(a.fall_damage_per_mps) * scale
	var whole := float(a.hp) / maxf(per, 0.001)
	return whole + float(a.fall_min_speed) if bool(a.get("fall_damage_above_min", false)) else whole


# ------------------------------------------------------------------ C2

func _check_weapon_animations() -> void:
	print("C2 weapon images:")
	var disc := _weapon_anim("tribes2:SPINFUSOR")
	disc.apply_draw()
	_expect(disc.make_action() == "" and disc.has_role("ready"), "T2 disc: no Activated sequence in the shape (as the original), DiscSpin ready loop")
	disc.apply_fired()
	_expect(disc.make_action() == "fire", "a shot plays Fire")
	_advance(disc, 0.5)
	_expect(disc.make_action() == "reload", "then Reload (Fire 0.47 s)")
	_advance(disc, 0.3)
	_expect(disc.make_action() == "", "then rest (Reload 0.2 s)")
	var t1 := _weapon_anim("tribes:DISC_LAUNCHER")
	t1.apply_draw()
	_expect(t1.make_action() == "activate", "T1 disc: the activation plays when drawn")
	_advance(t1, 0.7)
	_expect(t1.make_action() == "", "and ends after its 0.63 s")
	_check_flash_pieces()
	var chain := _weapon_anim("tribes:CHAINGUN")
	_expect(chain.has_role("spin") and str(chain.roles.spin_on) == "trigger", "T1 chaingun spins while firing")
	for a in [disc, t1, chain]:
		a.model.free()


## Every hand weapon of both games: its hidden-by-default pieces (muzzle flashes, effects) stay hidden while the
## weapon rests drawn, and the weapons whose shot shows a flash show it during the shot (F's report: the T1
## Chaingun's flash hung in front of the barrel all the time).
func _check_flash_pieces() -> void:
	var shown_on_fire := ["tribes:CHAINGUN", "tribes:MORTAR", "tribes2:BLASTER", "tribes2:CHAINGUN"]
	for pack in ["tribes", "tribes2"]:
		var j = Assets.load_json("gameplay/weapons_infantry.json", pack)
		for w in j.get("weapons", []):
			var id := "%s:%s" % [pack, w.name]
			var a := _weapon_anim(id)
			a.apply_draw()
			_advance(a, 2.0)
			var resting := _make_loop_shown_pieces(a)
			var hidden := a.model.make_hidden_piece_names().filter(func(n: String) -> bool: return not resting.has(n))
			var stray := hidden.filter(func(n: String) -> bool: return a.model.is_piece_visible(n))
			_expect(stray.is_empty(), "%s at rest: no flash shown %s" % [id, stray])
			if id in shown_on_fire:
				a.apply_fired()
				var seen := false
				for k in 12:
					a.update(0.02, true, false)
					seen = seen or hidden.any(func(n: String) -> bool: return a.model.is_piece_visible(n))
				_advance(a, 2.0)
				var after := hidden.filter(func(n: String) -> bool: return a.model.is_piece_visible(n))
				_expect(seen and after.is_empty(), "%s: the flash shows while firing, gone after" % id)
			a.model.free()


## Pieces a resting weapon's loops show on purpose (the ready / ambient sequences' visibility tracks: the
## Spinfusor's loaded disc, the plasma rifle's glowing core).
static func _make_loop_shown_pieces(a: InfantryWeaponAnimation) -> Array:
	var out := []
	for role in ["ready", "ambient"]:
		var i := InfantryHeldWeapon.find_sequence(a.model, str(a.roles.get(role, "")).to_lower())
		if i >= 0:
			for v in a.model.shape.ds_sequences[i].get("vis", []):
				out.append(str(v.piece))
	return out


func _weapon_anim(weapon_id: String) -> InfantryWeaponAnimation:
	var w := Packs.weapon(weapon_id)
	var model := InfantryHeldWeapon.make_ready_model(str(w.model.mount_shapes[0]), Packs.default_palette(weapon_id.get_slice(":", 0)))
	return InfantryWeaponAnimation.new(model, w.model.get("animation", {}))


static func _advance(a: InfantryWeaponAnimation, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		a.update(0.05, false, false)
		t += 0.05


# ------------------------------------------------------------------ C4

func _check_interact_action() -> void:
	print("C4 one interact action:")
	_expect(InputMap.has_action("interact") and not InputMap.has_action("loot_pickup"), "interact replaces loot_pickup")


func _check_pickups() -> void:
	print("C4 items in the maps:")
	var grants := TribesItemGrants.new("tribes2")
	_expect(str(grants.record("sniperrifle").get("shape", "")) == "tribes2:weapon_sniper", "T2 sniper rifle item: its model")
	var t2: Variant = Assets.load_json(TribesPickups.MAP_ITEMS_FILE % "Training1", "tribes2")
	_expect(t2 is Dictionary and (t2.items as Array).any(func(i: Dictionary) -> bool: return str(i.datablock) == "sniperrifle"),
		"Training1 places the sniper rifle")
	var battle := await _start_battle(PICKUP_MAP, BattleInfantry.START_ON_FOOT)
	var pickups := battle.get_node_or_null(TribesPickups.NODE_NAME) as TribesPickups
	_expect(pickups != null and pickups.items.size() > 10, "%s: items drawn (%d)" % [PICKUP_MAP, pickups.items.size() if pickups else 0])
	var s := battle.player as Infantry
	if pickups == null or s == null:
		_expect(false, "a pickup battle with the player on foot")
		battle.queue_free()
		return
	var rifle := _find_item(pickups, "sniperrifle")
	s.global_position = pickups.items[rifle].pos + Vector3(0, 0.3, 0)
	s.velocity = Vector3.ZERO
	await _frames(12)
	_expect(pickups.is_available(rifle) and not s.make_loadout().has("tribes2:LASER_RIFLE"),
		"touch: three weapons carried, the rifle stays (Player::pickup refuses)")
	var offer := battle.infantry.interaction.make_offer(s)
	_expect(str(offer.get("text", "")).contains("sniper rifle"), "interact offer: '%s'" % offer.get("text", ""))
	await _shot("pickup_offer")
	_press("interact")
	await _frames(4)
	_expect(not pickups.is_available(rifle) and s.current_weapon().weapon_id == "tribes2:LASER_RIFLE",
		"interact swaps the weapon in hand for the rifle, which is gone")
	await _shoot_soldier_views(battle, s)
	var patch := _find_item(pickups, "repairpatch")
	s.end_spawn_protection()
	s.apply_hit(0.0, 500.0, null)
	var hurt := s.integrity
	s.global_position = pickups.items[patch].pos + Vector3(0, 0.3, 0)
	await _frames(12)
	_expect(hurt < 1.0 and not pickups.is_available(patch) and s.integrity > hurt,
		"touch: a hurt soldier takes a repair patch (%.2f -> %.2f)" % [hurt, s.integrity])
	_check_packs_reload(battle, s)
	battle.queue_free()
	await _frames(4)


## X3 (PLAYTEST_2026-10-11b): a pack worn later (the extraction mode loads it from the inventory) raises the full
## loads; pack_use with no pack to switch asks the mode to reload from what is carried.
func _check_packs_reload(battle: Battle, s: Infantry) -> void:
	print("X3 packs and reload:")
	var cg: Weapon = null
	for w in s.weapons:
		if w.weapon_id == "tribes2:CHAINGUN":
			cg = w
	var before := cg.ammo_max if cg else -1
	s.apply_worn_pack("tribes2:AMMO_PACK")
	_expect(cg != null and cg.ammo_max > before, "an ammo pack worn: chaingun load %d -> %d" % [before, cg.ammo_max if cg else -1])
	var asked := []
	battle.infantry.gear.reload_hook = func(peer: int, _soldier: Infantry) -> void: asked.append(peer)
	battle.infantry.gear.apply_pack_toggle(battle.multiplayer.get_unique_id())
	_expect(asked.size() == 1, "pack_use with an ammo pack (nothing to switch) asks for a reload")
	s.apply_worn_pack("tribes2:SHIELD_PACK")
	s.capacitor = s.capacitor_max
	battle.infantry.gear.apply_pack_toggle(battle.multiplayer.get_unique_id())
	_expect(s.kit.pack_active and asked.size() == 1, "pack_use with a shield pack switches it on")


## Windowed runs only (--shots): a soldier running across the view, then dying (C1), and the view model firing (C2).
func _shoot_soldier_views(battle: Battle, s: Infantry) -> void:
	if _shots == "" or DisplayServer.get_name() == "headless":
		return
	var site := s.global_position + Vector3(40, 0, -120)
	site.y = MapBuilder.ground_height(battle, site) + 0.3
	s.global_position = site
	s.velocity = Vector3.ZERO
	await _frames(20)
	var ahead := -s.global_basis.z
	var at := s.global_position + ahead * 6.0
	at.y = MapBuilder.ground_height(battle, at) + 0.3
	var runner := battle.spawn_soldier_for(90, 1, "Runner", Transform3D(Basis(Vector3.UP, s.rotation.y + PI * 0.5), at))
	runner.end_spawn_protection()
	runner.throttle = 1.0
	runner.torso_target = runner.rotation.y
	await _frames(10)
	await _shot("t2_run")
	runner.throttle = 0.0
	runner.apply_hit(0.0, 1.0e6, null)
	await get_tree().create_timer(3.0).timeout
	await _shot("t2_death")
	var w := s.current_weapon()
	w.trigger = true
	await _frames(3)
	await _shot("view_model_fire")
	w.trigger = false
	s.apply_weapon_slot(s.make_loadout().find("tribes2:SPINFUSOR"))
	await get_tree().create_timer(1.0).timeout
	await _shot("view_model_spinfusor")


static func _find_item(pickups: TribesPickups, datablock: String) -> int:
	for id in pickups.items:
		if str(pickups.items[id].datablock) == datablock:
			return id
	return -1


func _press(action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	Input.parse_input_event(ev)
	Input.flush_buffered_events()
	var up := ev.duplicate()
	up.pressed = false
	Input.parse_input_event(up)
	Input.flush_buffered_events()


func _start_battle(map: String, start: String) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "start": start, "ai": []}, true)
	if map != "":
		config.map = map
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	await _frames(SETTLE_FRAMES)
	return battle


# ------------------------------------------------------------------ C5

func _check_pack_choice() -> void:
	print("C5 infantry packs:")
	var saved := Packs.content_enabled.duplicate(true)
	_disable_infantry("tribes")
	_expect(InfantryCatalog.make_default_pack() == "tribes2", "only Tribes 2: its armours")
	_disable_infantry("tribes2")
	_expect(InfantryCatalog.make_default_pack() == "" and InfantryCatalog.make_infantry_packs().is_empty(), "none: no infantry")
	Packs.content_enabled = saved


func _check_no_infantry() -> void:
	var saved := Packs.content_enabled.duplicate(true)
	_disable_infantry("tribes")
	_disable_infantry("tribes2")
	var battle := await _start_battle("", BattleInfantry.START_ON_FOOT)
	var me := battle.multiplayer.get_unique_id()
	var inside := battle.occupancy.vehicle_of(me)
	_expect(battle.infantry.pack == "" and inside != null, "no infantry: the player starts in his vehicle")
	_expect(not battle.occupancy.can_leave_vehicle(me) and OccupancyHint.make_local(battle.occupancy) == "",
		"pilots cannot get out, no exit hint")
	_press("vehicle_enter_exit")
	await _frames(6)
	_expect(battle.occupancy.vehicle_of(me) == inside and battle.occupancy.soldier_of(me) == null, "vehicle_enter_exit keeps him inside")
	battle.queue_free()
	await _frames(4)
	Packs.content_enabled = saved


## Switches a pack's infantry off in memory only (Packs.set_enabled would save the player's library settings).
static func _disable_infantry(pack: String) -> void:
	if not Packs.content_enabled.has(pack):
		Packs.content_enabled[pack] = {}
	Packs.content_enabled[pack]["infantry"] = false
