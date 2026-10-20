class_name CallinSupplies
extends RefCounted
## What the pods' crates give (host; docs/design/lobby_loadout_economy.md section 9.2):
##   armour drop  a temporary armour of the match's infantry game for temp_armor_s: the soldier keeps his weapons, the
##                rounds in them and his hand items (nothing comes free: an armour change that would refill them does not),
##                and the old armour returns when the time is up. It is never an item: it does not enter the inventory
##                and a bag never holds it (ExtractionDirector.worn_armor is the armour he came in).
##   ammo drop    refills the rounds of every weapon he carries to the armour's maximum, in three uses per pod.
## Every peer applies the armour change (rpc); the rounds travel in the message because a rebuilt soldier starts full.

const REVERT_HEALTH_FLOOR := 0.05

var callins: CallinDirector
## Host: peer -> {original: armour id, left: seconds}.
var temp_armor := {}


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## The armour of `size` ("light", "medium", "heavy") in `pack` ("" when the game has none).
static func make_armor_id(pack: String, size: String) -> String:
	for a in InfantryCatalog.armors_of(pack):
		if str(a.get("size", "")) == size:
			return str(a.id)
	return ""


## Host: `soldier` (of `peer`) puts on armour `size` for the pod's time. False when his game has no such armour.
func apply_temp_armor(peer: int, soldier: Infantry, size: String) -> bool:
	var new_id := make_armor_id(str(soldier.armor.get("pack", "")), size)
	if new_id == "":
		return false
	var record: Dictionary = temp_armor.get(peer, {"original": soldier.armor_id})
	record["left"] = CallinRules.number(callins.battle.config, CallinRules.rule(CallinRules.KIND_ARMOR), "temp_armor_s", 300.0)
	temp_armor[peer] = record
	_wear(soldier, new_id, 1.0)
	return true


## Host, every physics frame: armours whose time is up are taken off.
func apply_tick(delta: float) -> void:
	for peer in temp_armor.keys():
		var soldier := callins.battle.occupancy.soldier_of(int(peer))
		if soldier == null or not soldier.alive:
			temp_armor.erase(peer)
			continue
		temp_armor[peer].left = float(temp_armor[peer].left) - delta
		if float(temp_armor[peer].left) <= 0.0:
			_wear(soldier, str(temp_armor[peer].original), soldier.integrity)
			temp_armor.erase(peer)
			callins.director.notify(int(peer), "Your temporary armour is gone.")


## Host: `peer` is out of the raid (dead, extracted): nothing to give back.
func apply_forget(peer: int) -> void:
	temp_armor.erase(peer)


func _wear(soldier: Infantry, armor_id: String, health_share: float) -> void:
	var state := {"loadout": soldier.make_loadout(), "rounds": ExtractionLoadout.make_loaded_rounds(soldier),
		"counts": soldier.kit.counts.duplicate(), "grenade": soldier.kit.grenade_id, "pack": soldier.kit.pack_id,
		"health": maxf(health_share, REVERT_HEALTH_FLOOR)}
	callins.send_all("_armor_changed", [soldier.net_id, armor_id, state])


## Every peer: soldier `net_id` wears `armor_id`, keeping the kit that `state` describes.
static func apply_armor_change(battle: Battle, net_id: int, armor_id: String, state: Dictionary) -> void:
	var soldier := battle.vehicles.get(net_id) as Infantry
	if soldier == null:
		return
	soldier.apply_armor(armor_id, state.loadout, str(state.grenade), str(state.pack))
	soldier.kit.counts.clear()
	for id in state.counts:
		soldier.kit.counts[id] = mini(int(state.counts[id]), soldier.kit.make_max_count(soldier.armor, str(id)))
	ExtractionLoadout.apply_loaded_rounds(soldier, state.rounds)
	ExtractionLoadout.apply_weapon_overrides(soldier)
	DownedState.apply_health_fraction(soldier, clampf(float(state.health), 0.0, 1.0))
	if soldier == battle.player:
		battle.refresh_player_view()


## Host: refills the rounds of every weapon `soldier` carries (and the grenades he already holds) to the armour's maximum.
static func apply_ammo_refill(soldier: Infantry) -> void:
	for w in soldier.weapons:
		if w is InfantryWeapon:
			(w as InfantryWeapon).apply_resupply((w as InfantryWeapon).missing_rounds())
	for id in soldier.kit.counts.keys():
		soldier.kit.counts[id] = soldier.kit.make_max_count(soldier.armor, str(id))
