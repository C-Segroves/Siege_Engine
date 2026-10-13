class_name BattleSalvage
extends RefCounted
## What a mission brings back for the campaign (docs/formats/campaign_availability.md sections 3, 7):
##
## Weapons recovered on the battlefield: every enemy Herc destroyed during the mission yields the
## weapons that were still intact, i.e. whose damage component ("WEAPON <n>", n = GL loadout slot + 1,
## ES1/ES2 DMG) was not destroyed. This is the Earthsiege 2 sim's rule (results.dat salvaged items,
## DBSIM 0x426ac8: weapons of destroyed enemy Hercs below 50 % damage; weapon components have a single
## hit point, so intact = undamaged) and is used for Earthsiege and Starsiege too (Starsiege's
## vehicle::salvage takes every weapon; its mountpoints have no weapon components, so all its weapons
## count as intact). The campaign adds the list to its stock when the mission is won.
##
## Salvage tonnage (results.dat salvage_kg): the wrecks' worth (GarageEconomy.make_wreck_salvage)
## when the campaign has an economy (battle config "economy_pack"), 0 without one.
##
## The squad: every garage Herc that flew (the player's and the wingmen, meta "garage" from
## BattleSpawner) reports its condition, whether it (and its pilot) came back, and its kills - the
## results.dat per-Herc condition the shell reads back (VSHELL 0x40eae7).

const WEAPON_COMPONENT := "WEAPON %d"

var weapon_ids: Array = []
var salvage_kg := 0


## Records the intact weapons and the wreck's salvage of `h` if it fought against `player_team`.
func apply_destroyed(h: Herc, player_team: int, economy: GarageEconomy) -> void:
	if h.team == player_team:
		return
	weapon_ids.append_array(make_intact_weapons(h))
	if economy.is_enabled():
		salvage_kg += GarageEconomy.make_wreck_salvage(h.vehicle_id, HercCondition.make_from_components(h.components))


## The mission result's salvage and squad fields: {salvage, salvage_kg, squad}.
func make_result_fields(vehicles: Dictionary) -> Dictionary:
	return {"salvage": weapon_ids.duplicate(), "salvage_kg": salvage_kg, "squad": make_squad_report(vehicles)}


## One row per garage Herc in the battle: {uid, pilot_id, alive, condition, kills}.
static func make_squad_report(vehicles: Dictionary) -> Array:
	var rows: Array = []
	for id in vehicles:
		var h: Herc = vehicles[id]
		if not is_instance_valid(h) or not h.has_meta("garage"):
			continue
		var tag: Dictionary = h.get_meta("garage")
		rows.append({"uid": int(tag.get("uid", 0)), "pilot_id": str(tag.get("pilot_id", "")), "alive": h.alive,
			"condition": HercCondition.make_from_components(h.components), "kills": h.kills})
	return rows


## Weapon ids of `h` whose damage component survived. Fixed weapons (Tribes vehicles) are part of
## the vehicle and never salvaged.
static func make_intact_weapons(h: Herc) -> Array:
	var out: Array = []
	if PackVehicleLoader.has_fixed_loadout(h.def):
		return out
	var guns: Array = h.def.get("guns", [])
	for w in h.weapons:
		var slot: int = int(guns[w.mount_index].get("loadout_slot", w.mount_index)) if w.mount_index < guns.size() else w.mount_index
		if not is_component_destroyed(h.components, WEAPON_COMPONENT % (slot + 1)):
			out.append(w.weapon_id)
	return out


## True when the named damage component exists and has no hit points left.
static func is_component_destroyed(components: Array, component_name: String) -> bool:
	for c in components:
		if str(c.get("name", "")) == component_name:
			return float(c.get("hp", 1.0)) <= 0.0
	return false
