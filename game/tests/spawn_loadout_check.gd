extends Node
## A character slot with three weapons spawns the soldier with all three, each with ammunition (docs/design/
## lobby_loadout_economy.md sections 2.6 and 13). For every infantry game (Tribes 1, Tribes 2) and every mode of a
## soldier's spawn (skirmish, team deathmatch, co-op, LAN host and a LAN client building the spec the host sent) the
## soldier carries the slot's weapons, also after a respawn. In a raid the kit decides: Operator Setup marks a slot
## weapon that is not in the kit, and the weapons the raid spawn gives are exactly the ones it does not mark.
##   godot --headless --audio-driver Dummy --path game res://tests/spawn_loadout_check.tscn

const GAMES := {"tribes": ["tribes:BLASTER", "tribes:CHAINGUN", "tribes:DISC_LAUNCHER"],
	"tribes2": ["tribes2:CHAINGUN", "tribes2:SPINFUSOR", "tribes2:BLASTER"]}
const MODES := ["skirmish", "team_deathmatch", "coop", "lan_host", "lan_client"]
const FIRST_PEER := 2001
const SETTLE_FRAMES := 8

var _failures := 0
var _shots := ""
var _battle: Battle
var _next_peer := FIRST_PEER


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			_shots = a.substr(8)
	for pack in GAMES:
		var weapons := _installed_weapons(pack)
		if InfantryCatalog.light_armor_id(pack) == "" or weapons.size() < 3:
			print("  skip %s: not installed with three weapons" % pack)
			continue
		_battle = await _start_battle(pack)
		for mode in MODES:
			await _check_mode(pack, mode, weapons)
		_battle.queue_free()
		await _frames(2)
	_check_raid()
	if _shots != "":
		await _save_player_shots()
	_finish()


func _finish() -> void:
	print("spawn_loadout_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


## Three infantry weapons the light armour of `pack` can carry, the blaster, chaingun and disc launcher by preference.
func _installed_weapons(pack: String) -> Array:
	var armor := InfantryCatalog.light_armor_id(pack)
	var out := []
	for w in GAMES[pack]:
		if not Packs.weapon(w).is_empty() and InfantryCatalog.allows_weapon(armor, w):
			out.append(w)
	return out


# ------------------------------------------------------------------ the spawn

func _check_mode(pack: String, mode: String, weapons: Array) -> void:
	print("%s, %s:" % [pack, mode])
	var armor := InfantryCatalog.light_armor_id(pack)
	var slot := CharacterSlot.make_default(0)
	slot.apply_armor_defaults(armor)
	slot.infantry.weapons = weapons.duplicate()
	for w in weapons:
		slot.infantry.ammo[w] = InfantryCatalog.make_ammo_capacity(armor, w)
	var peer := _next_peer
	_next_peer += 1
	_battle.config.mode = "skirmish" if mode == "skirmish" else ("coop" if mode == "coop" else "vs")
	_battle.config.teams = mode == "team_deathmatch"
	_battle.config.roster[peer] = {"name": "Slot %d" % peer, "team": 0, "vehicle": "es1:RAPTOR", "loadout": [],
		"infantry_armor": armor, "slot": slot.make_roster_snapshot()}
	var spec := _battle.infantry.make_soldier_spec(peer, 0, "Slot", Transform3D(Basis(), Vector3(-300 + peer, 60, 300)))
	if mode == "lan_client":
		spec = bytes_to_var(var_to_bytes(spec))   # what the host's spawn message carries to a client
	var s := _battle.infantry.build_soldier(spec)
	await _frames(SETTLE_FRAMES)
	_check_carried(s, weapons, "spawns with")
	s.respawn(Transform3D(Basis(), Vector3(-300 + peer, 60, 300)))
	_check_carried(s, weapons, "respawns with")


func _check_carried(s: Infantry, weapons: Array, verb: String) -> void:
	_expect(s.make_loadout() == weapons, "the soldier %s his slot's %d weapons (%s)" % [verb, weapons.size(), ", ".join(PackedStringArray(s.make_loadout()))])
	var armed := s.weapons.all(func(w: Weapon) -> bool: return w.ammo_max < 0 or w.ammo > 0)
	_expect(armed, "  every weapon has ammunition")
	s.apply_weapon_slot(2)
	_expect(s.current_weapon() != null and s.current_weapon().weapon_id == weapons[2], "  the third weapon can be drawn")


# ------------------------------------------------------------------ the raid

func _check_raid() -> void:
	print("raid:")
	var pack := "tribes"
	var armor := InfantryCatalog.light_armor_id(pack)
	var weapons := _installed_weapons(pack)
	if weapons.size() < 3:
		return
	var slot := CharacterSlot.make_default(0)
	slot.apply_armor_defaults(armor)
	slot.infantry.weapons = weapons.duplicate()
	var ctx := LoadoutContext.make_for({"mode": ExtractionRules.MODE})
	var kit := ExtractionInventory.make_for_size("light")
	kit.apply_add_unchecked(ExtractionItems.make_id("weapon", weapons[1]), 1)   # he brings only the chaingun
	ctx.apply_raid_kit(kit)
	var carried := ExtractionLoadout.make_raid_weapons(armor, kit)
	var marked := []
	for b in slot.make_blocks(ctx):
		if str(b.text).contains(SlotCheck.NOT_IN_KIT):
			marked.append(int(str(b.part).get_slice(":", 1)))
	var unmarked := []
	for i in weapons.size():
		if not marked.has(i):
			unmarked.append(weapons[i])
	_expect(carried == [weapons[1]], "the raid spawn gives the kit's weapon only")
	_expect(marked == [0, 2] and unmarked == carried, "Operator Setup marks the blaster and the disc launcher 'not in your kit'")
	var empty := ExtractionInventory.make_for_size("light")
	ctx.apply_raid_kit(empty)
	var free := ExtractionLoadout.make_raid_weapons(armor, empty)
	_expect(free.size() == 1 and free[0] == "tribes:BLASTER", "an empty kit still gets the free standard-issue blaster, and the screen agrees")
	var s := Infantry.new()
	s.armor_id = armor
	add_child(s)
	s.equip(ExtractionLoadout.make_weapon_loadout(s, kit))
	_expect(s.make_loadout() == carried, "the soldier of a raid carries what the screen calls his kit")
	s.queue_free()


# ------------------------------------------------------------------ windowed

## Windowed (--shots=<dir>): a skirmish with the local player on foot with a three-weapon slot, each weapon drawn in turn.
func _save_player_shots() -> void:
	var pack := "tribes"
	var armor := InfantryCatalog.light_armor_id(pack)
	var weapons := _installed_weapons(pack)
	var slot := CharacterSlot.make_default(0)
	slot.apply_armor_defaults(armor)
	slot.infantry.weapons = weapons.duplicate()
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.ai = []
	config["infantry_pack"] = pack
	config["start"] = "on_foot"
	config.roster[1].merge({"infantry_armor": armor, "slot": slot.make_roster_snapshot()}, true)
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	await _frames(60)
	var player := battle.player as Infantry
	_expect(player != null and player.make_loadout() == weapons, "the local player is on foot with the slot's weapons")
	if player == null:
		return
	DirAccess.make_dir_recursive_absolute(_shots)
	for i in weapons.size():
		player.apply_weapon_slot(i)
		await _frames(30)
		get_viewport().get_texture().get_image().save_png(_shots.path_join("spawn_loadout_%d.png" % i))
		print("  shot %d: %s in hand" % [i, player.current_weapon().weapon_id])


# ------------------------------------------------------------------ helpers

func _start_battle(pack: String) -> Battle:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.ai = []
	config["infantry_pack"] = pack
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = config
	await get_tree().process_frame
	get_tree().root.add_child(battle)
	await _frames(SETTLE_FRAMES)
	return battle


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
		await get_tree().physics_frame
