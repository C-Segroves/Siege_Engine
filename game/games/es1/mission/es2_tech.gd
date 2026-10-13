class_name Es2Tech
extends RefCounted
## Earthsiege 2 campaign unlocks (docs/formats/es2_campaign_flow.md "After the sim",
## docs/formats/campaign_availability.md), applied by CampaignES2.record_result.
##
## Original VSHELL after a campaign mission, from gamedata/es2/missions/campaign.json
## (tools/mission_es2.py: tech_unlock_rules, script_awards, start_hangar):
##   Hercs 0x4118c5    var60 Raptor II, var61 Maverick, var62 Ogre, var63 Razor when the var == 2;
##                     the var is reset to 0.
##   weapons 0x4126be  var50 LAS400 ... var59 Energy Pod when the var == its value; reset either way.
##   awards 0x412760   vars 21..42 add var[k] copies of a weapon (mission scripts set them to 1 when
##                     a Cybrid carrying that weapon dies). The shell never clears them; here they
##                     are cleared after being counted so one kill is not paid again every mission
##                     (deviation, documented in campaign_availability.md).
##   start             SHELL0/GAM/HERCS.DAT: four armed Outlaws (slot 4 is an empty placeholder), the
##                     campaign's starting garage; WEAPONS.DAT's starting inventory is its armory.
## What the shell offers from the start: the Herc types with HERC_INF.DAT's available flag (Outlaw,
## Tomahawk, Samson, Colossus, Apocalypse) and the weapons with WEAPONS.DAT's (the unlocks above set
## the same flags), from gameplay/economy.json (GarageEconomy). Without that file (older imports):
## HERCS.DAT's types and the first war's weapons (BASE_WEAPONS).

const PACK := "es2"
const BASE_WEAPONS := ["ATC20", "ATC35", "ATC50", "LAS100", "LAS200", "LAS300", "ELF", "EMP", "PBEAM",
	"ECM", "MSL6", "MSL8", "MSL10"]
const RULE_ITEM := 0
const RULE_VALUE := 1


static func _rules() -> Dictionary:
	return MissionCompilerES2.campaign_data()


## Fresh campaign unlock state: {"vehicles": [ids], "weapons": [base ids]}.
static func make_start_state() -> Dictionary:
	var economy := GarageEconomy.make_for_pack(PACK)
	var vehicles: Array = economy.make_start_vehicles()
	for rec in _make_start_records():
		var vid := "%s:%s" % [PACK, str(rec.get("herc", ""))]
		if not vehicles.has(vid):
			vehicles.append(vid)
	var weapons: Array = economy.make_start_weapon_ids()
	if weapons.is_empty():
		weapons = BASE_WEAPONS.map(func(n): return "%s:%s" % [PACK, n])
	return {"vehicles": vehicles, "weapons": weapons}


## The starting garage: the HERCS.DAT Hercs with their weapons (by GL slot), WEAPONS.DAT's starting
## inventory in the armory.
static func make_start_garage() -> Garage:
	var entries: Array = []
	for rec in _make_start_records():
		var vid := ES2UnitCatalog.vehicle_for(rec.get("herc"))
		if not Packs.vehicle(vid).is_empty():
			entries.append(Garage.make_entry(vid, _make_start_loadout(vid, rec.get("weapons", []))))
	return Garage.make(entries, GarageEconomy.make_for_pack(PACK).make_start_weapons())


## HERCS.DAT records of real Hercs (the condition-0 placeholder slot is not one).
static func _make_start_records() -> Array:
	return (_rules().get("start_hangar", []) as Array).filter(func(rec): return int(rec.get("condition", 0)) > 0)


static func _make_start_loadout(vid: String, weapons: Array) -> Array:
	var ids: Array = []
	var ammo: Array = []
	for w in weapons:
		var slot := int(w.get("slot", -1))
		if slot < 0:
			continue
		ids.resize(maxi(ids.size(), slot + 1))
		ammo.resize(ids.size())
		ids[slot] = ES2UnitCatalog.WEAPON_NAMES.find(str(w.get("weapon", "")))
		ammo[slot] = int(w.get("missile_type", ES2UnitCatalog.DEFAULT_AMMO_WORD))
	return ES2UnitCatalog.loadout_for(vid, ids.map(func(x): return x if x != null else -1),
		ammo.map(func(x): return x if x != null else ES2UnitCatalog.DEFAULT_AMMO_WORD))


## Applies the tech unlocks of a finished mission's vars to `state` and its script awards to the
## armory `stock`, and resets the vars the shell resets (plus the counted award vars, see above).
static func apply_mission_vars(state: Dictionary, stock: Dictionary, vars: PackedInt32Array) -> void:
	var rules: Dictionary = _rules().get("tech_unlock_rules", {})
	_apply_unlocks(state.vehicles, rules.get("hercs", {}), vars)
	_apply_unlocks(state.weapons, rules.get("weapons", {}), vars)
	_apply_awards(stock, _rules().get("script_awards", {}), vars)


static func _apply_unlocks(unlocked: Array, rules: Dictionary, vars: PackedInt32Array) -> void:
	for k in rules:
		var i := int(k)
		if i < 0 or i >= vars.size():
			continue
		var rule: Array = rules[k]
		var id := "%s:%s" % [PACK, str(rule[RULE_ITEM])]
		if vars[i] == int(rule[RULE_VALUE]) and not unlocked.has(id):
			unlocked.append(id)
		vars[i] = 0


static func _apply_awards(stock: Dictionary, awards: Dictionary, vars: PackedInt32Array) -> void:
	for k in awards:
		var i := int(k)
		if i < 0 or i >= vars.size() or vars[i] <= 0:
			continue
		var id := "%s:%s" % [PACK, str(awards[k])]
		stock[id] = int(stock.get(id, 0)) + vars[i]
		vars[i] = 0


## Availability context from an unlock state and the garage's armory `stock`.
static func make_context(state: Dictionary, stock: Dictionary) -> Dictionary:
	var ctx := CampaignAvailability.make_context(PACK)
	ctx.unlocked_vehicles = (state.get("vehicles", []) as Array).duplicate()
	ctx.unlocked_weapons = (state.get("weapons", []) as Array).duplicate()
	ctx.salvage_stock = stock
	ctx.economy = GarageEconomy.make_for_pack(PACK)
	return ctx
