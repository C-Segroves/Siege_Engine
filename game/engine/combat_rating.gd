class_name CombatRating
extends RefCounted
## Cross-game combat ratings used by campaign availability (docs/formats/campaign_availability.md §2):
## is another game's Herc / tank / weapon "more or less equivalent" to what a campaign has unlocked?
##
## Every game measures armour, shields, speed and damage on its own scale (an Earthsiege LAS100 does
## 16x the raw damage per second of an Earthsiege 2 LAS100), so a raw stat is turned into its
## percentile rank among the comparable entries of the SAME game (0 = weakest, 1 = strongest) and
## the ranks are averaged with the weights below: a rating says where an item stands in its own
## game's line-up, and items at the same place in two games' line-ups count as equivalent. Ranks
## also keep one outlier (a cinematic-only Apocalypse with 300k armour) from flattening the rest.
##   vehicle rating  armour (damage component hit points), shields, weapon hardpoints, top speed;
##                   ranked among the game's pilotable vehicles of the same kind (Hercs vs Hercs,
##                   tanks vs tanks).
##   weapon rating   damage per second, range; ranked among the game's Herc weapons of the same family.
## A factor a vehicle has no data for (Battledrome Hercs have no damage components) is left out
## and the remaining weights are renormalised.

const KIND_HERC := "herc"
const KIND_TANK := "tank"
## Rated vehicle families: Hercs and tanks, and the Tribes vehicles (fliers rated with the Hercs, the
## Beowulf with the tanks) so the "equivalent" rule can offer them in a campaign.
const RATED_VEHICLE_CATEGORIES := ["herc", "vehicle"]
const VEHICLE_WEIGHTS := {"armour": 0.35, "shield": 0.15, "slots": 0.35, "speed": 0.15}
const WEAPON_WEIGHTS := {"dps": 0.75, "range": 0.25}
const MIN_REFIRE := 0.1   # seconds; guards a 0 refire in imported data
const ALONE_RATING := 0.5 # the only item of its group stands in the middle

## Weapon families (campaign_availability.md §2) by catalog weapon kind.
const FAMILY_BY_KIND := {"beam": "beam", "emp": "beam", "plasma": "beam", "cannon": "cannon",
	"grenade": "cannon", "missile": "missile", "artillery": "missile", "mine": "special", "ecm": "special",
	"other": "special"}
const DEFAULT_FAMILY := "special"

static var _cache := {}
static var _cache_key := ""


## "tank" for tracked/hover tanks (Starsiege kind "tank"), else "herc".
static func vehicle_kind(v: Dictionary) -> String:
	return KIND_TANK if str(v.get("kind", KIND_HERC)) == KIND_TANK else KIND_HERC


## beam / cannon / missile / special.
static func weapon_family(w: Dictionary) -> String:
	return str(FAMILY_BY_KIND.get(str(w.get("kind", "")), DEFAULT_FAMILY))


## 0..1 rating of a pilotable vehicle among the vehicles of its kind.
static func vehicle_rating(catalog: Node, v: Dictionary) -> float:
	_ensure_tables(catalog)
	return float(_cache.get("v:" + str(v.get("id", "")), 0.0))


## 0..1 rating of a Herc weapon among the weapons of its family.
static func weapon_rating(catalog: Node, w: Dictionary) -> float:
	_ensure_tables(catalog)
	return float(_cache.get("w:" + str(w.get("id", "")), 0.0))


# ------------------------------------------------------------------ raw stats

static func make_vehicle_stats(v: Dictionary) -> Dictionary:
	var armour := 0.0
	var damage = v.get("damage", {})
	for c in (damage.get("components", []) if damage is Dictionary else []):
		armour += float(c.get("hp", 0.0))
	var stats := {"slots": float(v.get("guns", []).size()), "speed": float(v.get("max_speed", 0.0))}
	if armour > 0.0:
		stats["armour"] = armour
	if float(v.get("shield_max", 0.0)) > 0.0:
		stats["shield"] = float(v.shield_max)
	return stats


static func make_weapon_stats(w: Dictionary) -> Dictionary:
	var hit := float(w.get("shield_damage", 0.0)) + float(w.get("armor_damage", 0.0))
	var volley := hit * maxf(1.0, float(w.get("beams", 1))) * maxf(1.0, float(w.get("burst", 1)))
	return {"dps": volley / maxf(MIN_REFIRE, float(w.get("refire", 1.0))), "range": float(w.get("range", 0.0))}


# ------------------------------------------------------------------ tables

static func _ensure_tables(catalog: Node) -> void:
	var key := "%d|%d|%s" % [catalog.vehicles.size(), catalog.weapons.size(), str(catalog.packs.keys())]
	if key == _cache_key:
		return
	_cache = {}
	_cache_key = key
	var groups := {}
	for id in catalog.vehicles:
		var v: Dictionary = catalog.vehicles[id]
		if v.get("pilotable", false) and RATED_VEHICLE_CATEGORIES.has(str(v.get("category", "herc"))):
			_append(groups, "v:%s:%s" % [vehicle_kind(v), v.pack], [str(id), make_vehicle_stats(v)])
	for id in catalog.weapons:
		var w: Dictionary = catalog.weapons[id]
		if str(w.get("category", "herc")) == "herc":
			_append(groups, "w:%s:%s" % [weapon_family(w), w.pack], [str(id), make_weapon_stats(w)])
	for g in groups:
		var prefix := str(g).substr(0, 2)
		_rate_group(groups[g], prefix, VEHICLE_WEIGHTS if prefix == "v:" else WEAPON_WEIGHTS)


static func _append(groups: Dictionary, key: String, entry: Array) -> void:
	if not groups.has(key):
		groups[key] = []
	groups[key].append(entry)


## Weighted mean of each member's percentile ranks; stores "<prefix><id>" -> rating.
static func _rate_group(members: Array, prefix: String, weights: Dictionary) -> void:
	var columns := {}
	for factor in weights:
		columns[factor] = []
		for m in members:
			if (m[1] as Dictionary).has(factor):
				columns[factor].append(float(m[1][factor]))
		(columns[factor] as Array).sort()
	for m in members:
		var sum := 0.0
		var total := 0.0
		for factor in weights:
			if (m[1] as Dictionary).has(factor):
				sum += float(weights[factor]) * make_percentile(columns[factor], float(m[1][factor]))
				total += float(weights[factor])
		_cache[prefix + str(m[0])] = sum / total if total > 0.0 else 0.0


## Mid-rank percentile of `x` in the sorted `values` (ties share the middle rank), 0..1.
static func make_percentile(values: Array, x: float) -> float:
	if values.size() <= 1:
		return ALONE_RATING
	var below := 0
	var equal := 0
	for value in values:
		if float(value) < x:
			below += 1
		elif is_equal_approx(float(value), x):
			equal += 1
	return (float(below) + maxf(float(equal) - 1.0, 0.0) * 0.5) / float(values.size() - 1)
