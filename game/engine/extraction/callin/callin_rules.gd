class_name CallinRules
extends RefCounted
## The call-in numbers of an extraction raid (extraction_rules.json "callins" and "raid_points";
## docs/design/lobby_loadout_economy.md section 9). Remake design values, no game data. The test flag
## ExtractionRules.FAST_FLAG (or config "extraction_fast") swaps in the short timers of callins.fast.

const KIND_VEHICLE := "vehicle_delivery"
const KIND_ARMOR := "armor_drop"
const KIND_AMMO := "ammo_drop"
const KIND_REPAIR := "repair_station"
const KIND_INVENTORY := "inventory_station"
const KIND_RADAR := "radar_sweep"
const KIND_BOMBING := "bombing_run"
const KIND_ATTACK := "attack_craft"
## Between an air call-in's label and the name of its aircraft.
const AIRCRAFT_SEPARATOR := " - "
## The air call-ins: aircraft that fly to a designated point (CallinAir runs them).
const AIR_KINDS := [KIND_BOMBING, KIND_ATTACK]
## Menu order.
const KINDS := [KIND_VEHICLE, KIND_ARMOR, KIND_AMMO, KIND_REPAIR, KIND_INVENTORY, KIND_RADAR]
## Kinds that fall from orbit in a pod (the vehicle does too when no transport is installed).
const POD_KINDS := [KIND_ARMOR, KIND_AMMO, KIND_REPAIR, KIND_INVENTORY]
const CLASS_LIGHT := "light"
const CLASS_MEDIUM := "medium"
const CLASS_HEAVY := "heavy"
const CLASS_FLYER := "flyer"
## Armour classes of an armour drop (a variant of the call-in).
const ARMOR_SIZES := ["light", "medium", "heavy"]


static func data() -> Dictionary:
	return ExtractionRules.data().get("callins", {})


static func points() -> Dictionary:
	return ExtractionRules.data().get("raid_points", {})


static func lz() -> Dictionary:
	return data().get("lz", {})


static func pod() -> Dictionary:
	return data().get("pod", {})


## The rules of call-in `kind` ({} for an unknown kind).
static func rule(kind: String) -> Dictionary:
	return (data().get("kinds", {}) as Dictionary).get(kind, {})


static func is_kind(kind: String) -> bool:
	return not rule(kind).is_empty()


static func is_air_kind(kind: String) -> bool:
	return kind in AIR_KINDS


## The name of call-in `kind` for the player: the rule's label; an air call-in names the aircraft that flies it too
## ("Bombing run - Thundersword"), whichever airframe CallinAirframes picks from the installed content.
static func make_label(kind: String) -> String:
	var label := str(rule(kind).get("label", kind))
	if is_air_kind(kind):
		return "%s%s%s" % [label, AIRCRAFT_SEPARATOR, CallinAirframes.make_craft_name(kind)]
	return label


## A rule number, in a fast run the callins.fast value of the same key when it has one (config: the battle's).
static func number(config: Dictionary, group: Dictionary, key: String, fallback := 0.0) -> float:
	if ExtractionRules.is_fast(config):
		var fast: Dictionary = data().get("fast", {})
		if fast.has(key):
			return float(fast[key])
	return float(group.get(key, fallback))


## The shared pause between two call-ins of one player (s).
static func shared_cooldown(config: Dictionary) -> float:
	return number(config, data(), "shared_cooldown_s", 20.0)


static func order_timeout(config: Dictionary) -> float:
	return number(config, data(), "order_timeout_s", 90.0)


static func max_active_orders() -> int:
	return int(data().get("max_active_orders", 2))


## Seconds of the flare / ring countdown before a pod falls.
static func marker_seconds(config: Dictionary, kind: String) -> float:
	var s := float(rule(kind).get("marker_s", 0.0))
	return s * (float(data().get("fast", {}).get("marker_scale", 1.0)) if ExtractionRules.is_fast(config) else 1.0)


## Seconds a pod's content (crate, station) lasts.
static func make_ttl(config: Dictionary, kind: String) -> float:
	var s := float(rule(kind).get("ttl_s", 0.0))
	return s * (float(data().get("fast", {}).get("ttl_scale", 1.0)) if ExtractionRules.is_fast(config) else 1.0)


## Seconds a pod takes to fall (visual and impact time): the drop height at the fall speed.
static func make_fall_seconds() -> float:
	var p := pod()
	return float(p.get("drop_height_m", 400.0)) / maxf(float(p.get("fall_speed_mps", 90.0)), 1.0)


## The slower fall of the pod that carries a vehicle when no transport is installed.
static func make_slow_fall_seconds(config: Dictionary) -> float:
	return number(config, pod(), "slow_fall_s", 9.0)


## "light" / "medium" / "heavy" / "flyer": the price class of vehicle `v` (a Packs.vehicle record).
static func make_vehicle_class(v: Dictionary) -> String:
	if bool(v.get("flyer", false)):
		return CLASS_FLYER
	var table: Dictionary = data().get("vehicle_class", {})
	var rating := Packs.combat_rating(v)
	if rating <= float(table.get("light_rating_max", 0.4)):
		return CLASS_LIGHT
	return CLASS_MEDIUM if rating <= float(table.get("medium_rating_max", 0.7)) else CLASS_HEAVY


## Raid points call-in `kind` costs; `variant` is the armour size of an armour drop, `vehicle_id` the vehicle of a
## delivery. -1 when the variant or vehicle is unknown.
static func make_cost(kind: String, variant: String, vehicle_id: String) -> int:
	var cost = rule(kind).get("cost", -1)
	if cost is Dictionary:
		var key := variant
		if kind == KIND_VEHICLE:
			var v := Packs.vehicle(vehicle_id)
			key = make_vehicle_class(v) if not v.is_empty() else ""
		return int(cost[key]) if cost.has(key) else -1
	return int(cost)


## The call-ins in menu order (the air kinds last) with their numbers: [{kind, variant, label, text}] (an armour drop is one
## row per size). The menu and the command map list these.
static func make_offers() -> Array:
	var out := []
	for kind in KINDS + AIR_KINDS:
		var variants: Array = ARMOR_SIZES if kind == KIND_ARMOR else [""]
		for variant in variants:
			var label := make_label(kind) if variant == "" else "%s (%s)" % [make_label(kind), variant]
			out.append({"kind": kind, "variant": variant, "label": label, "text": str(rule(kind).get("text", ""))})
	return out


## Metres within which AIs hear a call-in of `kind` (docs section 9.7).
static func make_alert_radius(kind: String) -> float:
	return float(rule(kind).get("alert_radius_m", 0.0))


## The first of `ids` (shape ids "pack:name") whose shape is imported ("" when none).
static func pick_imported_shape(ids: Array) -> String:
	for id in ids:
		if LootContainer._is_imported(str(id)):
			return str(id)
	return ""


## [lowest, highest] seconds the whole wait of a vehicle delivery lasts (callins.fast.eta_clamp_s in a fast run).
static func make_eta_clamp(config: Dictionary, group: Dictionary) -> Array:
	var pair: Array = group.get("eta_clamp_s", [20.0, 60.0])
	if ExtractionRules.is_fast(config):
		pair = data().get("fast", {}).get("eta_clamp_s", pair)
	return [float(pair[0]), float(pair[1])]
