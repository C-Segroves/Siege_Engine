class_name Saga
extends RefCounted
## The series campaign: Earthsiege -> Earthsiege 2 -> Starsiege (player chooses the Human or the
## Cybrid campaign). Each stage is run by its game's campaign provider; the saga moves to the next
## stage when a stage ends in victory. Stages whose game isn't imported are skipped with a note.
##
## Provider registry: pack -> script path. A provider script must implement
##   static func start(variant: String) -> Object        (variant: "" or "human"/"cybrid")
##   and the returned object: current_mission(), load_current(options) -> Dictionary (resolved
##   mission), prepared_vars(), record_result(success, vars), is_over(), is_victory(), to_dict(),
##   static from_dict(d)
## Earthsiege's provider is Campaign (game/games/es1/mission/campaign.gd).
## Campaign availability and the garage (docs/formats/campaign_availability.md):
##   var garage: Garage, availability_context() -> Dictionary (CampaignAvailability),
##   apply_salvage(weapon_ids)
## End-of-mission page texts: make_presentation() -> Dictionary (CampaignPresentation).
## When a stage is won its Herc types and weapons are carried into the following stages (`carried`,
## where they count as earlier-era designs) and its garage (owned Hercs and armory) is merged into
## the next stage's garage when that stage starts.

const STAGES := [
	{"pack": "es1", "name": "Metaltech: Earthsiege"},
	{"pack": "es2", "name": "Earthsiege 2"},
	{"pack": "starsiege", "name": "Starsiege", "choice": ["human", "cybrid"]},
]
const PROVIDERS := {
	"es1": "res://games/es1/mission/campaign_provider.gd",
	"es2": "res://games/es2/campaign_provider.gd",
	"starsiege": "res://games/starsiege/campaign_provider.gd",
}

var stage := 0
var variant := ""                 # chosen at the Starsiege stage
var campaign: Object = null       # current stage's campaign
var history := []                 # [{stage, pack, result}]
var carried := {"vehicles": [], "weapons": [], "garage": {}}


static func available_stages() -> Array:
	var out := []
	for i in STAGES.size():
		var s: Dictionary = STAGES[i]
		out.append({"index": i, "name": s.name, "installed": Assets.has_pack(s.pack),
			"playable": ResourceLoader.exists(PROVIDERS.get(s.pack, "")) and Assets.has_pack(s.pack)})
	return out


static func start_new() -> Saga:
	var g := Saga.new()
	g.stage = -1
	g.advance()
	return g


## Current stage needs the player's Human/Cybrid choice before it can start.
func needs_choice() -> bool:
	return stage < STAGES.size() and STAGES[stage].has("choice") and variant == "" and campaign == null


func choose(v: String) -> void:
	variant = v
	_start_stage()


## Moves to the next playable stage. Returns false when the saga is complete.
func advance() -> bool:
	campaign = null
	while true:
		stage += 1
		if stage >= STAGES.size():
			return false
		var s: Dictionary = STAGES[stage]
		if not Assets.has_pack(s.pack) or not ResourceLoader.exists(PROVIDERS.get(s.pack, "")):
			history.append({"stage": stage, "pack": s.pack, "result": "skipped (not available yet)"})
			continue
		if s.has("choice") and variant == "":
			return true   # wait for choose()
		_start_stage()
		return true
	return false


func _start_stage() -> void:
	var s: Dictionary = STAGES[stage]
	var prov = load(PROVIDERS[s.pack])
	campaign = prov.start(variant)
	_apply_carried_garage()


## Merges the carried garage into the running stage's garage.
func _apply_carried_garage() -> void:
	if not (carried.garage as Dictionary).is_empty():
		(campaign.garage as Garage).apply_merge(Garage.from_dict(carried.garage))
		carried.garage = {}


func is_complete() -> bool:
	return stage >= STAGES.size()


func stage_name() -> String:
	if is_complete():
		return "Complete"
	var s: Dictionary = STAGES[stage]
	return s.name + (" - %s campaign" % variant.capitalize() if variant != "" and s.has("choice") else "")


## After a mission: feed the result to the stage campaign; advance the saga on stage victory.
func record_result(success: bool, vars: PackedInt32Array) -> void:
	if campaign == null:
		return
	campaign.record_result(success, vars)
	if campaign.is_over():
		history.append({"stage": stage, "pack": STAGES[stage].pack, "result": "victory" if campaign.is_victory() else "defeat"})
		if campaign.is_victory():
			apply_carry(availability_context(), campaign.garage)
			advance()


## The stage campaign's availability plus everything carried over from earlier stages.
func availability_context() -> Dictionary:
	if campaign == null or not campaign.has_method("availability_context"):
		return {}
	var ctx: Dictionary = campaign.availability_context()
	ctx.carried_vehicles = (carried.vehicles as Array).duplicate()
	ctx.carried_weapons = (carried.weapons as Array).duplicate()
	return ctx


## Keeps a finished stage's Herc types and weapons (`ctx`) and its `garage` for the following stages.
func apply_carry(ctx: Dictionary, garage: Garage) -> void:
	for id in ctx.get("unlocked_vehicles", []) + ctx.get("carried_vehicles", []):
		if not (carried.vehicles as Array).has(id):
			carried.vehicles.append(id)
	for id in ctx.get("unlocked_weapons", []) + ctx.get("carried_weapons", []):
		if not (carried.weapons as Array).has(id):
			carried.weapons.append(id)
	carried.garage = garage.to_dict()


func to_dict() -> Dictionary:
	return {"stage": stage, "variant": variant, "history": history, "carried": carried.duplicate(true),
		"campaign": campaign.to_dict() if campaign else {}}


static func from_dict(d: Dictionary) -> Saga:
	var g := Saga.new()
	g.stage = int(d.get("stage", 0))
	g.variant = String(d.get("variant", ""))
	g.history = d.get("history", [])
	if d.get("carried") is Dictionary:
		g.carried.merge(d.carried, true)
	var old_stock = g.carried.get("stock", {})   # saves from before the garage carried bare stock
	g.carried.erase("stock")
	if old_stock is Dictionary and not (old_stock as Dictionary).is_empty():
		g.carried.garage = Garage.make([], old_stock).to_dict()
	if g.stage < STAGES.size() and not d.get("campaign", {}).is_empty():
		var prov = load(PROVIDERS[STAGES[g.stage].pack])
		g.campaign = prov.restore(d.campaign)
		g._apply_carried_garage()
	return g
