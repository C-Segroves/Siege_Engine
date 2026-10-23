extends Node
## The hand weapons of Tribes: Aerial Assault and Tribes: Vengeance (tools/aa_weapons.py, tools/tv_weapons.py;
## docs/formats/aerial_assault.md and tribes_vengeance.md, "Infantry weapons"), for every installed one of the two packs:
##   1. the catalog holds the expected weapons, all of the infantry family, each with a model, a fire sound, an fx block;
##   2. their numbers are sane (refire, damage, range, projectile speed and lifetime, energy);
##   3. the per-armour-size rules (infantry_rules.json) name catalog weapons and are read by InfantryCatalog;
##   4. the free-weapon fallback list of the extraction rules names the pack's blaster;
##   5. each weapon fires from a soldier in a battle: it pays its ammunition or energy, starts its refire, and its
##      projectile flies and ends (impact or lifetime) without script errors.
##   godot --headless --audio-driver Dummy --path game res://tests/aa_tv_weapons_check.tscn [-- --pack=tribes_v]

const MAP := "tribes:Raindance"
const EXPECTED := {
	"tribes_aa": ["DISC_LAUNCHER", "PLASMA_GUN", "LASER_RIFLE", "MORTAR", "GRENADE_LAUNCHER", "CHAINGUN", "BLASTER", "ELF_GUN", "MISSILE_LAUNCHER"],
	"tribes_v": ["SPINFUSOR", "CHAINGUN", "BLASTER", "GRENADE_LAUNCHER", "MORTAR", "SNIPER_RIFLE", "ROCKET_POD", "BURNER"],
}
const BLASTER := "BLASTER"
const SIZES := ["LIGHT", "MEDIUM", "HEAVY"]
const SETTLE_FRAMES := 30
const TIME_SCALE := 4.0
const FLIGHT_MARGIN_S := 3.0
const MIN_REFIRE_S := 0.05
const MAX_REFIRE_S := 5.0
const MAX_DAMAGE_HP := 6000.0
const MIN_RANGE_M := 10.0
const MAX_RANGE_M := 1500.0
const MIN_SPEED_MPS := 20.0
const MAX_SPEED_MPS := 700.0
const MAX_LIFETIME_S := 12.0
const WATCHDOG_SECONDS := 420.0

var _failures := 0
var _checked := 0
var _errors := ErrorCounter.new()
var _only_pack := ""


## Counts engine and script errors raised while weapons fire (any is a failure).
class ErrorCounter extends Logger:
	var count := 0

	func _log_error(_function: String, _file: String, _line: int, _code: String, _rationale: String,
			_editor_notify: bool, error_type: int, _script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type != ERROR_TYPE_WARNING:
			count += 1


func _ready() -> void:
	get_tree().create_timer(WATCHDOG_SECONDS, true, true).timeout.connect(func() -> void: get_tree().quit(2))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pack="):
			_only_pack = a.substr(7)
	_run.call_deferred()


func _expect(ok: bool, what: String) -> void:
	_checked += 1
	if not ok:
		_failures += 1
		print("FAIL  ", what)


func _run() -> void:
	OS.add_logger(_errors)
	var battle: Battle = null
	for pack in EXPECTED:
		if not Assets.installed_packs().has(pack) or (_only_pack != "" and _only_pack != pack):
			continue
		_check_catalog(pack)
		_check_rules(pack)
		_check_fallback(pack)
		if battle == null:
			battle = await _start_battle()
		await _check_firing(battle, pack)
	_expect(_errors.count == 0, "no engine / script errors while the weapons fire (%d)" % _errors.count)
	OS.remove_logger(_errors)
	Engine.time_scale = 1.0
	print("aa_tv_weapons_check: %s (%d checks, %d failures)" % ["OK" if _failures == 0 else "FAILED", _checked, _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _weapons_of(pack: String) -> Array:
	return Packs.weapons.values().filter(func(w: Dictionary) -> bool: return str(w.pack) == pack and str(w.get("category")) == "infantry")


# ------------------------------------------------------------------ catalog

func _check_catalog(pack: String) -> void:
	var ids := _weapons_of(pack).map(func(w: Dictionary) -> String: return str(w.name))
	ids.sort()
	var want: Array = (EXPECTED[pack] as Array).duplicate()
	want.sort()
	_expect(ids == want, "%s: the catalog holds exactly %s (has %s)" % [pack, want, ids])
	for w in _weapons_of(pack):
		_check_weapon(w)


func _check_weapon(w: Dictionary) -> void:
	var id := str(w.id)
	_expect(not Assets.shape(String((w.model.mount_shapes as Array)[0] if not (w.model.mount_shapes as Array).is_empty() else "")).is_empty(),
		"%s has a held model" % id)
	_expect(Sfx.stream(str(w.sounds.get("fire", ""))) != null, "%s: fire sound %s plays" % [id, w.sounds.get("fire", "")])
	_expect(not FxLibrary.is_fallback(FxLibrary.weapon_fx(w)), "%s has its fx block" % id)
	var refire := float(w.refire)
	_expect(refire >= MIN_REFIRE_S and refire <= MAX_REFIRE_S, "%s: refire %.3f s" % [id, refire])
	var damage := float(w.armor_damage)
	var is_elf := str(w.damage_type) == "elf"
	_expect((damage > 0.0 or is_elf) and damage <= MAX_DAMAGE_HP, "%s: damage %.0f hp" % [id, damage])
	_expect(float(w.range) >= MIN_RANGE_M and float(w.range) <= MAX_RANGE_M, "%s: range %.0f m" % [id, float(w.range)])
	var p = w.get("projectile")
	if p is Dictionary:
		_expect(float(p.speed) >= MIN_SPEED_MPS and float(p.speed) <= MAX_SPEED_MPS, "%s: projectile speed %.0f m/s" % [id, float(p.speed)])
		_expect(float(p.lifetime) > 0.0 and float(p.lifetime) <= MAX_LIFETIME_S, "%s: projectile lifetime %.1f s" % [id, float(p.lifetime)])
		_expect(float(p.speed) * float(p.lifetime) >= float(w.range) * 0.5 or float(p.gravity) > 0.0, "%s: the flight covers the range" % id)
	else:
		_expect(str(w.kind) == "beam", "%s: no projectile means a beam" % id)
	if float(w.min_charge) > 0.0 or float(w.per_shot) > 0.0:
		_expect(float(w.per_shot) >= float(w.min_charge) * 0.0 and float(w.per_shot) <= 60.0, "%s: energy per shot %.1f" % [id, float(w.per_shot)])


# ------------------------------------------------------------------ rules

func _check_rules(pack: String) -> void:
	var light := InfantryCatalog.make_pack_rules(pack, "LIGHT")
	var heavy := InfantryCatalog.make_pack_rules(pack, "HEAVY")
	_expect(not light.is_empty() and not heavy.is_empty(), "%s: carry rules per armour size" % pack)
	for size in SIZES:
		var rules := InfantryCatalog.make_pack_rules(pack, size)
		_expect(int(rules.get("max_weapons", 0)) >= 3, "%s %s: carries at least three weapons" % [pack, size])
		for wid in rules.get("weapons", []):
			_expect(Packs.weapons.has(str(wid)), "%s %s: rule weapon %s is in the catalog" % [pack, size, wid])
		for wid in rules.get("default_loadout", []):
			_expect((rules.weapons as Array).has(wid), "%s %s: default weapon %s is allowed" % [pack, size, wid])
		_expect(not (rules.get("default_loadout", []) as Array).is_empty(), "%s %s has a default loadout" % [pack, size])
		for wid in rules.get("ammo", {}):
			_expect((rules.weapons as Array).has(wid) and int(rules.ammo[wid]) > 0, "%s %s: ammo of %s" % [pack, size, wid])
	_expect((heavy.weapons as Array).size() >= (light.weapons as Array).size() - 2, "%s: heavy armour is not poorer than light" % pack)
	for armor_pack in InfantryCatalog.make_infantry_packs():
		var armor_id := "%s:LIGHT" % armor_pack.pack
		for wid in light.weapons:
			_expect(InfantryCatalog.allows_weapon(armor_id, str(wid)), "%s wears %s" % [armor_id, wid])
		_expect(InfantryCatalog.make_ammo_capacity(armor_id, str((light.weapons as Array)[0])) >= 0, "%s: ammo of %s" % [armor_id, (light.weapons as Array)[0]])
		for wid in heavy.weapons:
			if not (light.weapons as Array).has(wid):
				_expect(not InfantryCatalog.allows_weapon(armor_id, str(wid)), "%s does not wear %s (heavy only)" % [armor_id, wid])


func _check_fallback(pack: String) -> void:
	var blaster := "%s:%s" % [pack, BLASTER]
	_expect((ExtractionRules.data().get("free_weapon_fallbacks", []) as Array).has(blaster), "%s is a free-weapon fallback" % blaster)
	var def := Packs.weapon(blaster)
	_expect(not def.is_empty() and str(def.category) == "infantry" and Packs.is_enabled(pack, "infantry_weapons"), "%s is an enabled infantry weapon" % blaster)


# ------------------------------------------------------------------ firing

func _start_battle() -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT, "frag_limit": 50,
		"ai": [{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.0, "name": "Target"}]}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	get_tree().root.add_child(battle)
	get_tree().current_scene = battle
	for i in SETTLE_FRAMES:
		await get_tree().physics_frame
	return battle


func _check_firing(battle: Battle, pack: String) -> void:
	Engine.time_scale = TIME_SCALE
	for w in _weapons_of(pack):
		await _fire_once(battle, pack, w)
	Engine.time_scale = 1.0


## The armour size that carries `wid` first (light, medium, heavy) of the first installed Tribes game with armours.
func _make_armor_for(pack: String, wid: String) -> String:
	for size in SIZES:
		if (InfantryCatalog.make_pack_rules(pack, size).get("weapons", []) as Array).has(wid):
			return "%s:%s" % [InfantryCatalog.make_default_pack(), size]
	return ""


func _make_body_of(pack: String, armor_id: String) -> String:
	for b in InfantryCatalog.make_bodies(armor_id):
		if str(b.id).begins_with(pack + ":"):
			return str(b.id)
	return ""


func _fire_once(battle: Battle, pack: String, def: Dictionary) -> void:
	var wid := str(def.id)
	var armor_id := _make_armor_for(pack, wid)
	_expect(armor_id != "", "%s: some armour carries it" % wid)
	var s := battle.player as Infantry
	if armor_id == "" or s == null:
		return
	s.apply_armor(armor_id, [])
	var body := _make_body_of(pack, armor_id)
	if body != "":
		s.body_shape = body
		s._rebuild_body()
	s.equip([wid])
	s.end_spawn_protection()
	var w := s.current_weapon() as InfantryWeapon
	_expect(w != null and w.weapon_id == wid, "%s: carried by %s" % [wid, armor_id])
	if w == null:
		return
	s.capacitor = s.capacitor_max
	s.pitch = 0.15
	await get_tree().physics_frame
	var ammo_before := w.ammo
	var energy_before := s.capacitor
	var before := _count_projectiles(battle, wid)
	_expect(w.ready_to_fire(), "%s is ready to fire" % wid)
	w.fire()
	var paid := w.ammo < ammo_before if ammo_before >= 0 else s.capacitor < energy_before
	_expect(paid, "%s pays for the shot (ammo %d -> %d, energy %.1f -> %.1f)" % [wid, ammo_before, w.ammo, energy_before, s.capacitor])
	_expect(w.cooldown > 0.0 or int(def.burst) > 1, "%s starts its refire" % wid)
	if str(def.kind) != "beam":
		_expect(_count_projectiles(battle, wid) > before, "%s launched a projectile" % wid)
		await _await_flight_end(battle, wid, def)
	await get_tree().physics_frame


func _count_projectiles(battle: Battle, wid: String) -> int:
	var n := 0
	for p in battle.find_children("*", "Projectile", true, false):
		if str((p as Projectile).weapon_def.get("id", "")) == wid:
			n += 1
	return n


## Waits for the weapon's projectiles to impact or expire (their lifetime plus a margin, real seconds / time scale).
func _await_flight_end(battle: Battle, wid: String, def: Dictionary) -> void:
	var limit := (float((def.projectile as Dictionary).lifetime) + FLIGHT_MARGIN_S) / Engine.time_scale
	var t := 0.0
	while t < limit and _count_projectiles(battle, wid) > 0:
		await get_tree().physics_frame
		t += get_physics_process_delta_time() / Engine.time_scale
	_expect(_count_projectiles(battle, wid) == 0, "%s: the projectile ends (impact or lifetime)" % wid)
