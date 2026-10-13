extends RefCounted
## Saga provider for Starsiege (game/engine/saga.gd): the Human or the Cybrid campaign.
##
## Campaign data: gamedata/starsiege/campaigns/<human|cybrid>.json (tools/export_starsiege_missions.py):
## linear mission order from the original nextMission chain; success -> next mission, failure ->
## replay (the original has no failure branches). Inventory changes reported by the mission scripts
## (Inventory*Adjust from updatePlanetInventory / salvage) are accumulated in `inventory_log` and
## applied to the planet inventories (SSInventory), which decide what the hangar offers
## (docs/formats/campaign_availability.md). The garage starts with the stash's vehicles; counted
## inventory weapons mounted on its Hercs are not in the armory (inventory minus mounted).

const PACK := "starsiege"
## The campaign string table (id -> text) the scripts speak from.
const STRINGS := "scripts/strings.json"

class SSCampaign:
	extends RefCounted
	var variant := "human"
	var order: Array = []
	var index := 0
	var over := false
	var victory := false
	var data := {}
	var inventory_log: Array = []
	var inventory := {}            # SSInventory state
	var garage: Garage
	var results: Array = []

	func current_mission() -> String:
		return String(order[index]) if index < order.size() else ""

	func player_vehicle() -> String:
		var v = data.get("start_vehicle")
		return String(v) if v != null else ""

	func load_current(_options := {}) -> Dictionary:
		var m := StarsiegeMissionRuntime.load_mission(current_mission())
		if m.is_empty():
			return m
		# texts in the shape the shared briefing/debriefing screens read
		var objs := []
		for o in m.get("objectives", []):
			objs.append(("%s%s" % ["" if o.get("primary", true) else "(secondary) ", o.get("short", "")]))
		m["texts"] = {"briefing": "%s\n\n%s" % [m.get("short_brief", ""), m.get("long_brief", "")],
			"objectives": objs, "debriefings": [m.get("debrief_success", ""), m.get("debrief_fail", "")]}
		m["player_vehicle"] = player_vehicle()
		m["runtime"] = "res://games/starsiege/starsiege_mission_runtime.gd"   # Battle routes pack "starsiege" here
		return m

	func prepared_vars(_options := {}) -> PackedInt32Array:
		var v := PackedInt32Array()
		v.resize(100)
		return v

	func record_result(success: bool, _vars := PackedInt32Array()) -> void:
		results.append({"mission": current_mission(), "success": success})
		if success:
			for c in StarsiegeMissionRuntime.last_inventory:
				inventory_log.append(c)
			SSInventory.apply_calls(inventory, StarsiegeMissionRuntime.last_inventory)
			index += 1
			if index >= order.size():
				over = true
				victory = true
		StarsiegeMissionRuntime.last_inventory = []

	func is_over() -> bool:
		return over

	## A failed mission is flown again (the original campaign has no failure branches).
	func replays_failed_missions() -> bool:
		return true

	func is_victory() -> bool:
		return victory

	## Availability context (CampaignAvailability): the current planet's inventory plus the stash.
	func availability_context() -> Dictionary:
		var ctx := CampaignAvailability.make_context(PACK, side())
		ctx.unlocked_vehicles = SSInventory.make_vehicle_ids(inventory, current_planet())
		var counts := SSInventory.make_counts(inventory, current_planet(), "weapons")
		for wid in counts:
			if int(counts[wid]) == SSInventory.INFINITE:
				ctx.unlocked_weapons.append(wid)
			elif int(counts[wid]) > 0:
				ctx.salvage_stock[wid] = int(counts[wid])
		_apply_mounted(ctx.salvage_stock)
		if player_vehicle() != "":
			ctx.mission_vehicles.append(player_vehicle())
		return ctx

	## Counted weapons on the garage's Hercs are not in the armory.
	func _apply_mounted(stock: Dictionary) -> void:
		var mounted := garage.make_mounted_counts()
		for wid in stock:
			stock[wid] = maxi(0, int(stock[wid]) - int(mounted.get(wid, 0)))

	## Weapons recovered from destroyed enemies go to the stash (missionStdLib.cs vehicle::salvage).
	func apply_salvage(weapon_ids: Array) -> void:
		SSInventory.apply_salvage(inventory, weapon_ids)

	## A finished mission's result: a won mission's salvage to the stash; Starsiege has no salvage
	## economy and keeps no damage between missions (GarageReport only counts the crew's missions).
	func apply_battle_result(result: Dictionary) -> Dictionary:
		if bool(result.get("success", false)):
			apply_salvage(result.get("salvage", []))
		return GarageReport.apply(garage, availability_context(), result)

	## Starsiege missions bring their own squadmates (the scripts' playerSquad): no garage wingmen.
	func wingman_slots(_mission: Dictionary) -> int:
		return 0

	## End-of-mission page texts (CampaignPresentation), by side: a Cybrid career wins when humanity falls. The killed
	## page reads the campaign's own IDSTR_PLAYER_KILLED string.
	func make_presentation() -> Dictionary:
		var cybrid := variant == "cybrid"
		return {"killed_prompt": CampaignPresentation.make_or(
				CampaignPresentation.make_table_text(PACK, STRINGS, "IDSTR_PLAYER_KILLED"), "Mission failed."),
			"victory_text": "VICTORY - Prometheus prevails over humanity." if cybrid else "VICTORY - The colonies stand free.",
			"defeat_text": "GAME OVER - Humanity has defeated the Cybrids." if cybrid else "GAME OVER - The colonies have fallen."}

	## The game whose campaign this is (recorded in saves, Session.make_save_dict).
	func pack_id() -> String:
		return PACK

	func side() -> String:
		return "cybrid" if variant == "cybrid" else "herc"

	## Planet of the current mission (missions/<id>.json "planet").
	func current_planet() -> String:
		var m = Assets.load_json("missions/%s.json" % current_mission(), PACK)
		return str(m.get("planet", "")) if m is Dictionary else ""

	func to_dict() -> Dictionary:
		return {"variant": variant, "index": index, "over": over, "victory": victory,
			"inventory_log": inventory_log, "inventory": inventory, "results": results,
			"garage": garage.to_dict()}


static func _make(variant: String) -> SSCampaign:
	var c := SSCampaign.new()
	c.variant = variant if variant in ["human", "cybrid"] else "human"
	var d = Assets.load_json("campaigns/%s.json" % c.variant, PACK)
	c.data = d if d is Dictionary else {}
	for e in c.data.get("missions", []):
		c.order.append(String(e.id))
	c.inventory = SSInventory.make_initial(c.data.get("inventory_init", []))
	c.garage = SSInventory.make_start_garage(c.inventory)
	return c


static func start(variant: String) -> Object:
	return _make(variant)


static func restore(d: Dictionary) -> Object:
	var c := _make(String(d.get("variant", "human")))
	c.index = int(d.get("index", 0))
	c.over = bool(d.get("over", false))
	c.victory = bool(d.get("victory", false))
	c.inventory_log = d.get("inventory_log", [])
	if d.get("inventory") is Dictionary and d.inventory.has("planets"):
		c.inventory = d.inventory
	else:
		SSInventory.apply_calls(c.inventory, c.inventory_log)
	c.results = d.get("results", [])
	if d.get("garage") is Dictionary:
		c.garage = Garage.from_dict(d.garage)
	return c
