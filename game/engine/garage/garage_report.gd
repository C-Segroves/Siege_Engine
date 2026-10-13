class_name GarageReport
extends RefCounted
## What a campaign mission's result does to the garage (docs/formats/campaign_availability.md
## section 7), the same for every game; the economy and the rules of the game decide the amounts.
## Original order (VSHELL 0x40eae7): results.dat salvage joins the pool, each squad Herc's condition and
## pilot are read back, Hercs at <= 29 % are written off for their scrap value, dead pilots are counted
## and replaced, the factory works on the Hercs being built.
##
## result keys used (BattleSalvage.make_result_fields; the recovered weapons are the provider's,
## apply_salvage):
##   salvage_kg  salvage from destroyed enemies
##   squad       [{uid, pilot_id, alive, condition, kills}] the garage Hercs that flew (player, wingmen)
## Returns the debriefing summary {salvage_kg, written_off: [names], killed: [names], replaced: [names]}.

## Games without an economy (Starsiege) keep no damage between missions, as their originals.
static func apply(g: Garage, ctx: Dictionary, result: Dictionary, bonus_kg := 0) -> Dictionary:
	var economy := GarageEconomy.of_context(ctx)
	var summary := {"salvage_kg": 0, "written_off": [], "killed": [], "replaced": []}
	if economy.is_enabled():
		summary.salvage_kg = int(result.get("salvage_kg", 0)) + bonus_kg
		g.salvage_kg += summary.salvage_kg
	for row in result.get("squad", []):
		_apply_squad_row(g, ctx, row, summary)
	_apply_factory(g)
	SquadRoster.apply_auto_assign(g)
	return summary


## One Herc that flew: its condition, its pilot's mission, and a write-off when it came back a wreck.
static func _apply_squad_row(g: Garage, ctx: Dictionary, row: Dictionary, summary: Dictionary) -> void:
	var i := g.find_uid(int(row.get("uid", 0)))
	var pilot_id := str(row.get("pilot_id", ""))
	var before := g.crew.pilot(pilot_id)
	if not before.is_empty():
		g.crew.apply_mission(pilot_id, int(row.get("kills", 0)), bool(row.get("alive", true)))
		if not bool(row.get("alive", true)):
			summary.killed.append(str(before.name))
			summary.replaced.append(str(g.crew.pilot_in_slot(int(before.slot)).get("name", "")))
	var economy := GarageEconomy.of_context(ctx)
	if i < 0 or not economy.is_enabled():
		return
	var e: Dictionary = g.vehicles[i]
	e.condition = (row.get("condition", []) as Array).duplicate()
	if (not bool(row.get("alive", true)) or HercCondition.make_integrity(str(e.vehicle), e.condition) <= economy.make_write_off_fraction()) \
			and g.can_scrap():
		summary.written_off.append(str(e.name))
		g.salvage_kg += economy.make_scrap_value(e)
		_apply_keep_weapons(g, ctx, e)
		g.apply_remove(i)


## Weapons still good enough (>= 80 %) go back to the armory when a wreck is written off.
static func _apply_keep_weapons(g: Garage, ctx: Dictionary, e: Dictionary) -> void:
	for part in GarageEconomy.of_context(ctx).make_parts(e):
		if part.kind == "weapon" and float(part.percent) >= GarageEconomy.KEEP_WEAPON_FRACTION * GarageEconomy.PERCENT:
			var base := CampaignAvailability.base_weapon(str(part.name))
			g.stock[base] = int(g.stock.get(base, 0)) + 1


## Hercs in the factory are a mission closer to ready.
static func _apply_factory(g: Garage) -> void:
	for e in g.vehicles:
		e.build_left = maxi(0, int(e.get("build_left", 0)) - 1)

