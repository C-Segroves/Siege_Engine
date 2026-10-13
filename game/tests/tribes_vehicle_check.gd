extends Node
## Headless check of the Tribes / Tribes 2 vehicles and their original fixed weapons
## (docs/formats/tribes_vehicles.md):
##   1. catalog entries (category "vehicle", kind, flyer flag and flight preset, size, fixed loadout);
##   2. their weapons are category "vehicle" and never offered on a Herc hardpoint;
##   3. the fixed loadout is not editable (WeaponFit, Garage, LoadoutEditor, salvage);
##   4. the armed rule (armed vehicles selectable, transports AI only) and campaign availability;
##   5. battles: the Shrike and the Beowulf fire a weapon on an injected fire action and hit a dummy,
##      the Beowulf's mortar fires (QA #4), the Thundersword's bomb hits a dummy below it.
##   godot --headless --audio-driver Dummy --path game res://tests/tribes_vehicle_check.tscn
##   [-- --shot=<png path>]   (windowed run: saves an in-battle screenshot of the Beowulf firing)

const ARMED := ["tribes:SCOUT", "tribes2:SHRIKE", "tribes2:THUNDERSWORD", "tribes2:BEOWULF"]
const UNARMED := ["tribes:LAPC", "tribes:HAPC", "tribes2:HAVOC", "tribes2:WILDCAT", "tribes2:JERICHO"]
const KINDS := {"tribes:SCOUT": "flyer", "tribes:LAPC": "flyer", "tribes:HAPC": "flyer", "tribes2:SHRIKE": "flyer",
	"tribes2:THUNDERSWORD": "flyer", "tribes2:HAVOC": "flyer", "tribes2:BEOWULF": "tank", "tribes2:WILDCAT": "cycle",
	"tribes2:JERICHO": "wheeled"}
## Loadouts as the originals mount them (vehicle.cs: FlierData projectileType; T2 <Vehicle>::onAdd images).
const STANDARD := {"tribes:SCOUT": ["tribes:FLIER_ROCKET"],
	"tribes2:SHRIKE": ["tribes2:SHRIKE_BLASTER", "tribes2:SHRIKE_BLASTER"],
	"tribes2:THUNDERSWORD": ["tribes2:BOMBER_FUSION_GUN", "tribes2:BOMBER_FUSION_GUN", "tribes2:BOMBER_BOMB", "tribes2:BOMBER_BOMB"],
	"tribes2:BEOWULF": ["tribes2:TANK_CHAINGUN", "tribes2:TANK_MORTAR"]}
## Shape sizes (docs/formats/tribes.md section 3, tribes2.md section 3): length in metres.
const LENGTHS := {"tribes:SCOUT": 6.5, "tribes2:SHRIKE": 11.1, "tribes2:BEOWULF": 11.0, "tribes2:HAVOC": 15.4}
const LENGTH_TOLERANCE := 0.3
const HERC_MASKS := [7, 15, 31, 63]
const TARGET := "es1:SCORPION"
const TARGET_DISTANCE := 45.0
const FIRE_SECONDS := 3.0
const BOMB_HEIGHT := 25.0
const BOMB_SECONDS := 5.0

var _failures := 0
var _shot := ""


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shot="):
			_shot = a.substr(7)
	if Packs.vehicle("tribes2:SHRIKE").is_empty() or Packs.vehicle("tribes:SCOUT").is_empty():
		_expect(false, "Tribes packs with vehicles installed (python tools/export_tribes_vehicles.py)")
		_finish()
		return
	_check_catalog()
	_check_weapon_families()
	_check_fixed_loadout()
	_check_selectability()
	await _check_battle_fire("tribes2:SHRIKE", "fire_group_1")
	await _check_battle_fire("tribes2:BEOWULF", "fire_group_1")
	await _check_mortar_fires()
	await _check_bomb_drop()
	_finish()


func _finish() -> void:
	print("tribes_vehicle_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


# ------------------------------------------------------------------ 1. catalog

func _check_catalog() -> void:
	print("catalog:")
	for vid in KINDS:
		var v := Packs.vehicle(vid)
		var shape := Assets.shape(str(v.get("shape", "")))
		var has_geometry: bool = not (shape.get("lods", [{}])[0] as Dictionary).get("pieces", []).is_empty()
		_expect(not v.is_empty() and v.category == "vehicle" and v.kind == KINDS[vid] and has_geometry,
			"%s: %s, category vehicle, kind %s, shape %s" % [vid, v.get("name", "?"), v.get("kind", "?"), v.get("shape", "?")])
		_expect(bool(v.get("flyer", false)) == (KINDS[vid] == "flyer"), "%s flyer flag %s" % [vid, v.get("flyer", false)])
		_expect(PackVehicleLoader.has_fixed_loadout(v), "%s has a fixed loadout" % vid)
	for vid in LENGTHS:
		var length := float(Packs.vehicle(vid).get("length_m", 0.0))
		_expect(absf(length - float(LENGTHS[vid])) < LENGTH_TOLERANCE, "%s is %.1f m long (originals %.1f m)" % [vid, length, LENGTHS[vid]])
	for vid in STANDARD:
		_expect(Packs.vehicle(vid).loadout == STANDARD[vid], "%s standard armament %s" % [vid, Packs.vehicle(vid).loadout])
	var scout := FlightPresets.make_params(Packs.vehicle("tribes:SCOUT"), 1.0)
	var shrike := FlightPresets.make_params(Packs.vehicle("tribes2:SHRIKE"), 1.0)
	_expect(scout.style == FlightPresets.STYLE_HOVER and is_equal_approx(float(scout.max_speed), 50.0), "Scout flies its FlierData (50 m/s)")
	_expect(shrike.style == FlightPresets.STYLE_HOVER and is_equal_approx(float(shrike.max_speed), 100.0)
		and is_equal_approx(float(shrike.hover_height), 5.0), "Shrike flies its flier_data (100 m/s, hover height 5 m)")


# ------------------------------------------------------------------ 2. weapon families

func _check_weapon_families() -> void:
	print("weapon families:")
	var ids: Array = []
	for vid in STANDARD:
		for wid in STANDARD[vid]:
			if not ids.has(wid):
				ids.append(wid)
	for wid in ids:
		_expect(Packs.weapon(wid).get("category", "") == "vehicle", "%s is a vehicle weapon" % wid)
	var leaked: Array = []
	for mask in HERC_MASKS:
		for w in Packs.weapons_for_mask(mask, true, "herc", {WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS: true}):
			if str(w.get("category", "herc")) != "herc" or str(w.pack).begins_with("tribes"):
				leaked.append(w.id)
	_expect(leaked.is_empty(), "weapons_for_mask(..., \"herc\") never returns them %s" % [leaked])
	var offered := CampaignAvailability.offered_weapons({}).map(func(o): return str(o.weapon.id))
	_expect(ids.all(func(wid): return not offered.has(wid)), "the armory never offers them")


# ------------------------------------------------------------------ 3. fixed loadout

func _check_fixed_loadout() -> void:
	print("fixed loadout:")
	var beowulf := Packs.vehicle("tribes2:BEOWULF")
	_expect(not WeaponFit.fits(Packs.weapon("es1:LAS100"), beowulf, 0, {}), "WeaponFit: no Herc weapon fits a fixed mount")
	_expect(not WeaponFit.fits(Packs.weapon("tribes2:TANK_MORTAR"), beowulf, 0, {}), "WeaponFit: not even another vehicle weapon")
	var g := Garage.make([Garage.make_entry("tribes2:BEOWULF", ["es1:LAS100", ""])], {})
	_expect(g.selected_entry().loadout == STANDARD["tribes2:BEOWULF"], "Garage entry keeps the standard armament")
	_expect(not g.can_arm({}, 0, "") and not g.can_arm({}, 1, "es1:LAS100"), "Garage: can't unarm or arm")
	g.apply_arm({}, 0, "")
	_expect(g.selected_entry().loadout == STANDARD["tribes2:BEOWULF"] and g.stock.is_empty(), "apply_arm changes nothing, no stock moves")
	g.apply_build({}, "tribes2:SHRIKE")
	_expect(g.selected_entry().loadout == STANDARD["tribes2:SHRIKE"] and g.make_mounted_counts().is_empty(),
		"a built Shrike comes with its blasters; fixed weapons never count as armory stock")
	var editor := LoadoutEditor.new()
	add_child(editor)
	editor.setup("tribes2:BEOWULF", ["es1:LAS100", ""], {})
	var pickers := editor.find_children("*", "OptionButton", true, false)
	_expect(pickers.is_empty() and editor.loadout == STANDARD["tribes2:BEOWULF"], "LoadoutEditor: standard armament read-only (%d pickers)" % pickers.size())
	editor.queue_free()


# ------------------------------------------------------------------ 4. selectability

func _check_selectability() -> void:
	print("selectability:")
	var open := CampaignAvailability.offered_vehicles({}).map(func(o): return str(o.vehicle.id))
	for vid in ARMED:
		_expect(Packs.vehicle(vid).pilotable and open.has(vid), "%s (armed) is selectable in arena / versus" % vid)
	for vid in UNARMED:
		_expect(not Packs.vehicle(vid).pilotable and not open.has(vid), "%s (unarmed) is AI only" % vid)
	_expect(Packs.era("tribes") == 5 and Packs.era("tribes2") == 5, "Tribes is era 5, after every Herc game")
	var none := CampaignAvailability.make_context("es1")
	_expect(ARMED.all(func(vid): return CampaignAvailability.make_vehicle_reason(none, Packs.vehicle(vid)) == ""),
		"campaign with nothing unlocked: no Tribes vehicle (never an older design)")
	var ctx := CampaignAvailability.make_context("es1")
	for v in Packs.pilotable(["es1"]):
		ctx.unlocked_vehicles.append(str(v.id))
	var reasons := ARMED.map(func(vid): return CampaignAvailability.make_vehicle_reason(ctx, Packs.vehicle(vid)))
	print("    with every Earthsiege Herc unlocked: %s" % [reasons])
	_expect(reasons.all(func(r): return r == "" or str(r).begins_with("equivalent to")), "only offered by the equivalent rule")
	_expect(reasons.any(func(r): return r != ""), "some are offered once strong Hercs are unlocked")


# ------------------------------------------------------------------ 5. battles

## `vid` as the player, a frozen dummy ahead; the fire action held through SiegeInput.
func _check_battle_fire(vid: String, action: String) -> void:
	print("battle (%s):" % vid)
	var battle := await _start_battle(vid)
	var p: Herc = battle.player
	_expect(p != null and p.weapons.size() == STANDARD[vid].size(), "%s spawned with its %d fixed weapons" % [vid, STANDARD[vid].size()])
	if p == null:
		return
	var dummy := _spawn_dummy(battle, p, TARGET_DISTANCE)
	var before := _health(dummy)
	var fired := await _hold_fire(battle, action, FIRE_SECONDS)
	_expect(fired > 0, "%s fired %d shots on %s" % [vid, fired, action])
	_expect(_health(dummy) < before, "the dummy was hit (shields + hull %.0f -> %.0f)" % [before, _health(dummy)])
	if _shot != "" and vid == "tribes2:BEOWULF":
		await _save_shot()
	await _end_battle(battle)


## QA #4: the Beowulf's turret mortar (secondary trigger) fires; its data once had no lifetime.
func _check_mortar_fires() -> void:
	print("battle (tribes2:BEOWULF mortar):")
	var battle := await _start_battle("tribes2:BEOWULF")
	var fired := await _hold_fire(battle, "fire_group_2", FIRE_SECONDS)
	_expect(fired > 0, "the turret mortar fired %d shells on fire_group_2" % fired)
	await _end_battle(battle)


func _check_bomb_drop() -> void:
	print("battle (tribes2:THUNDERSWORD bombs):")
	var battle := await _start_battle("tribes2:THUNDERSWORD")
	var p: Herc = battle.player
	var dummy := _spawn_dummy(battle, p, 0.0)
	await get_tree().physics_frame
	p.global_position = dummy.global_position + Vector3.UP * BOMB_HEIGHT
	var before := _health(dummy)
	var fired := await _hold_fire(battle, "fire_group_2", BOMB_SECONDS)
	_expect(fired > 0 and p.weapons.filter(func(w): return w.kind == "bomb").size() == 2, "two bomb bays released %d bombs" % fired)
	_expect(_health(dummy) < before, "a bomb's blast hit the dummy below (%.0f -> %.0f)" % [before, _health(dummy)])
	await _end_battle(battle)


func _start_battle(vid: String) -> Battle:
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	var config := BattleSetup.make_default_config(vid)
	config.ai = []
	battle.config = config
	await get_tree().process_frame   # the root is busy while _ready runs
	get_tree().root.add_child(battle)
	for i in 10:
		await get_tree().physics_frame
	return battle


func _end_battle(battle: Battle) -> void:
	for a in ["fire_group_1", "fire_group_2"]:
		Input.action_release(a)
	battle.queue_free()
	await get_tree().process_frame


## A hostile Herc `dist` metres ahead of `p`, frozen (no AI, no physics).
func _spawn_dummy(battle: Battle, p: Herc, dist: float) -> Herc:
	var xf := p.global_transform
	xf.origin += -xf.basis.z * dist
	var dummy := battle.spawn_ai(TARGET, 1, xf, [], "Dummy", {"skill": 0.0})
	dummy.set_physics_process(false)
	for c in dummy.get_children():
		if c is AIPilot:
			c.queue_free()
	p.target = dummy
	return dummy


## Holds a fire action as the player would (gamepad active, so firing is allowed without a captured
## mouse); returns the number of shots fired.
func _hold_fire(battle: Battle, action: String, seconds: float) -> int:
	SiegeInput.last_device = SiegeInput.Device.GAMEPAD
	var shots := [0]   # lambdas capture locals by value: count in an array
	var counter := func(n: Node) -> void:
		if n is Projectile:
			shots[0] += 1
	battle.child_entered_tree.connect(counter)
	Input.action_press(action)
	var t := 0.0
	while t < seconds:
		await get_tree().physics_frame
		t += get_physics_process_delta_time()
	Input.action_release(action)
	await get_tree().create_timer(1.0).timeout
	battle.child_entered_tree.disconnect(counter)
	return int(shots[0])


static func _health(h: Herc) -> float:
	var hull := 0.0
	for c in h.components:
		hull += float(c.hp)
	return h.shield_front + h.shield_rear + hull


func _save_shot() -> void:
	Input.action_press("fire_group_1")
	await get_tree().create_timer(0.4).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(_shot)
	print("    screenshot %s" % _shot)
	Input.action_release("fire_group_1")
