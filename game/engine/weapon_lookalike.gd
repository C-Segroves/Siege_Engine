class_name WeaponLookalike
extends RefCounted
## Look-alike models for weapons that have none of their own (every Battledrome weapon off a
## Battledrome bay, ES2 MINE / LAEW, Starsiege EHUL, any future model-less weapon):
## docs/formats/weapon_mounts.md section 7.
##
## Players own any subset of the discs, so nothing is assumed: the chooser is a decision tree over the
## models of the packs that are installed AND have their Herc weapons enabled (Assets.installed_packs,
## Packs.is_enabled). The weapon is classified into an archetype from its own data (make_archetype),
## then the RULES table is walked top to bottom; the first rule with a candidate wins:
##   a) same archetype, same size class, from the host Herc's own pack (looks native there);
##   b) same archetype, same size, any pack - nearest in timeline era to the weapon's pack;
##   c) same archetype, nearest size class (one up/down before two), any pack;
##   d) same visual family (WeaponFit.family_of), same size - closest archetype (AFFINITY) first;
##   e) none: the host's own pod for that hardpoint (HercModel, RULE_HOST_POD);
##   f) none of those: the procedural stand-in pod (RULE_STAND_IN).
## Every rule ranks its candidates by one sort key (make_rank): size distance, host pack first,
## archetype affinity, era distance, stat distance, id - so the pick is deterministic. Choices are
## cached per (weapon, host pack, host side, available-pack set) and cleared on Packs.reload.

const LASER := "laser"                   ## instant beam, shield-heavy (lasers)
const PARTICLE_BEAM := "particle_beam"   ## instant beam, armour ~ shield (PBW, Starsiege PLAS / SGUN)
const DRAIN := "drain"                   ## EMP / ELF: drains shields or energy, disables
const BLASTER := "blaster"               ## energy bolt, quick refire
const PLASMA := "plasma"                 ## energy ball, slow refire or wide splash
const AUTOCANNON := "autocannon"         ## ammo-fed direct-fire projectile, quick refire (ATC, CANON)
const HEAVY_CANNON := "heavy_cannon"     ## ammo-fed direct fire, slow refire (blast cannon, railgun)
const MISSILE := "missile"               ## guided or rocket rack
const ARTILLERY := "artillery"           ## lobbed: grenade, mortar, artillery
const MINE := "mine"                     ## mine layer
const FLAMER := "flamer"
const SPECIAL := "special"               ## ECM and equipment pods (no shot of its own)

## Decision tree, in order. match: "archetype" or "family"; size: "same" or "near"; packs: "host" or "any".
const RULES := [
	{"id": "archetype_size_host", "match": "archetype", "size": "same", "packs": "host"},
	{"id": "archetype_size_era", "match": "archetype", "size": "same", "packs": "any"},
	{"id": "archetype_near_size", "match": "archetype", "size": "near", "packs": "any"},
	{"id": "family_size", "match": "family", "size": "same", "packs": "any"},
]
const RULE_HOST_POD := "host_pod"
const RULE_STAND_IN := "stand_in"

## Rule d: which other archetypes of the same family look most alike (first = closest).
const AFFINITY := {
	LASER: [PARTICLE_BEAM, DRAIN, BLASTER],
	PARTICLE_BEAM: [LASER, DRAIN, PLASMA],
	DRAIN: [PARTICLE_BEAM, LASER],
	BLASTER: [PLASMA, LASER, PARTICLE_BEAM, AUTOCANNON],
	PLASMA: [BLASTER, PARTICLE_BEAM, DRAIN],
	AUTOCANNON: [HEAVY_CANNON, BLASTER],
	HEAVY_CANNON: [AUTOCANNON, PLASMA],
	MISSILE: [ARTILLERY, MINE],
	ARTILLERY: [MISSILE, HEAVY_CANNON],
	MINE: [MISSILE, ARTILLERY],
	FLAMER: [PLASMA, BLASTER],
	SPECIAL: [],
}

## Classification thresholds (weapon schema units).
## A beam whose armour damage is at least this share of its shield damage is a particle beam
## (ES1 PBEAM 1000/1000, ES2 PBW 938/938) rather than a laser (ES1 LAS100 1500/600, BD LASER 2:1).
const PARTICLE_ARMOR_SHARE := 0.8
## Ammo-fed guns refiring at least this slowly are heavy cannons (Starsiege BC 1.7 s, RAIL 1.2 s;
## autocannons ES1 ATC 0.47 s, BD CANON 0.3-0.4 s, Starsiege HATC 0.7 s).
const HEAVY_REFIRE_S := 1.0
## Energy bolts refiring at least this slowly, or with a splash at least this wide, are plasma
## (BD PLASMA 1.7-2.9 s / 4.3 m, ES2 PLAS 15.6 m) rather than blasters (BD BLASTER 0.3-0.4 s, 2.1 m).
const PLASMA_REFIRE_S := 1.5
const PLASMA_SPLASH_M := 4.0
## A projectile slower than this with a proximity fuse is a mine (BD GATOR 0 m/s).
const MINE_SPEED_MPS := 1.0
const DRAIN_EFFECTS := ["emp_shield_drain", "elf_leech", "disable_seconds"]
const LOBBED_KINDS := ["artillery", "grenade", "bomb"]
const SPECIAL_KINDS := ["ecm", "other"]
const UNGUIDED := "none"

## Stat distance: sum of |ln(a / b)| over refire, damage per trigger, speed and rounds.
const BEAM_SPEED_MPS := 3000.0
const MIN_REFIRE_S := 0.1
const ROUNDS_WEIGHT := 0.5
const NO_ERA_DISTANCE := 99
const CONTENT_KIND := "herc_weapons"
const CYBRID_SIDE := "cybrid"

static var _choices := {}       # cache key -> choice
static var _archetypes := {}    # weapon id -> archetype
static var _pack_filter := []   # tests: simulate an installed-pack subset ([] = real installation)


## Forgets cached choices (after the catalog is reloaded or packs are switched on/off).
static func clear_cache() -> void:
	_choices.clear()
	_archetypes.clear()


## Tests: pretend only `packs` are installed (candidates only; nothing on disk changes).
static func apply_pack_filter(packs: Array) -> void:
	_pack_filter = packs.duplicate()
	_choices.clear()


static func clear_pack_filter() -> void:
	apply_pack_filter([])


## Packs whose models may be borrowed: installed, Herc weapons enabled (and inside the test filter).
static func make_available_packs() -> Array:
	var out := []
	for p in Assets.installed_packs():
		if Packs.packs.has(p) and Packs.is_enabled(p, CONTENT_KIND) and (_pack_filter.is_empty() or _pack_filter.has(p)):
			out.append(str(p))
	out.sort()
	return out


# ------------------------------------------------------------------ archetype

## Archetype of a weapon from its own data (kind, projectile, guidance, ammo, refire, damage split,
## splash, effects) - first matching row of the table in weapon_mounts.md section 7.1.
static func make_archetype(w: Dictionary) -> String:
	var id := str(w.get("id", ""))
	if id != "" and _archetypes.has(id):
		return _archetypes[id]
	var out := _classify(w)
	if id != "":
		_archetypes[id] = out
	return out


static func _classify(w: Dictionary) -> String:
	var kind := str(w.get("kind", ""))
	if kind == "emp" or _has_drain_effect(w):
		return DRAIN
	if kind == "mine" or _is_resting_fuse(w):
		return MINE
	if kind in LOBBED_KINDS or _gravity(w) > 0.0:
		return ARTILLERY
	if kind == "missile" or (_is_guided(w) and _is_ammo_fed(w)):
		return MISSILE
	if kind == "flame":
		return FLAMER
	if kind in SPECIAL_KINDS:
		return SPECIAL
	if kind == "beam" and not _is_ammo_fed(w):
		return _classify_beam(w)
	return _classify_projectile(w)


static func _classify_beam(w: Dictionary) -> String:
	var shield := float(w.get("shield_damage", 0.0))
	return PARTICLE_BEAM if float(w.get("armor_damage", 0.0)) >= shield * PARTICLE_ARMOR_SHARE else LASER


static func _classify_projectile(w: Dictionary) -> String:
	var refire := float(w.get("refire", 0.0))
	if _is_ammo_fed(w):
		return HEAVY_CANNON if refire >= HEAVY_REFIRE_S else AUTOCANNON
	if refire >= PLASMA_REFIRE_S or float(w.get("splash_radius", 0.0)) >= PLASMA_SPLASH_M:
		return PLASMA
	return BLASTER


static func _has_drain_effect(w: Dictionary) -> bool:
	var fx: Dictionary = w.get("effects", {}) if w.get("effects") is Dictionary else {}
	return DRAIN_EFFECTS.any(func(k): return float(fx.get(k, 0.0)) > 0.0)


static func _projectile(w: Dictionary) -> Dictionary:
	return w.projectile if w.get("projectile") is Dictionary else {}


static func _is_resting_fuse(w: Dictionary) -> bool:
	var p := _projectile(w)
	return not p.is_empty() and float(p.get("proximity", 0.0)) > 0.0 and float(w.get("speed", 0.0)) < MINE_SPEED_MPS


static func _gravity(w: Dictionary) -> float:
	return float(_projectile(w).get("gravity", 0.0))


static func _is_guided(w: Dictionary) -> bool:
	return str(_projectile(w).get("guidance", UNGUIDED)) != UNGUIDED


static func _is_ammo_fed(w: Dictionary) -> bool:
	return int(w.get("ammo", -1)) >= 0


# ------------------------------------------------------------------ decision tree

## Look-alike for weapon `w` on host vehicle `host`: {"rule": RULES id ("" = no candidate, the caller
## falls back to RULE_HOST_POD / RULE_STAND_IN), "weapon": id of the weapon whose model is borrowed,
## "archetype": w's archetype}.
static func choose(w: Dictionary, host: Dictionary) -> Dictionary:
	var available := make_available_packs()
	var key := "%s|%s|%s|%s" % [w.get("id", ""), host.get("pack", ""), _allows_cybrid(host), ",".join(available)]
	if not _choices.has(key):
		_choices[key] = _make_choice(w, host, available)
	return _choices[key]


static func _make_choice(w: Dictionary, host: Dictionary, available: Array) -> Dictionary:
	var arch := make_archetype(w)
	var candidates := _make_candidates(w, host, available)
	for rule in RULES:
		var hits := candidates.filter(func(c): return _rule_accepts(rule, w, host, c))
		if hits.is_empty():
			continue
		hits.sort_custom(func(a, b): return _less(make_rank(w, host, a), make_rank(w, host, b)))
		return {"rule": rule.id, "weapon": str(hits[0].id), "archetype": arch}
	return {"rule": "", "weapon": "", "archetype": arch}


## Herc-family weapons of the available packs that have a model, never the weapon itself, never
## turret-only ones, Cybrid-only ones only on Cybrids (or where the rules let them on Hercs).
static func _make_candidates(w: Dictionary, host: Dictionary, available: Array) -> Array:
	var out := []
	for id in Packs.weapons:
		var c: Dictionary = Packs.weapons[id]
		if str(id) == str(w.get("id", "")) or not available.has(str(c.pack)):
			continue
		if str(c.get("category", WeaponFit.HERC_FAMILY)) != WeaponFit.HERC_FAMILY or WeaponFit.size_of(c) == WeaponFit.INTERNAL:
			continue
		if c.get("cybrid_only", false) and not _allows_cybrid(host):
			continue
		if WeaponPodFit.model_shape_id(c, 0) != "":
			out.append(c)
	return out


static func _allows_cybrid(host: Dictionary) -> bool:
	return str(host.get("side", "herc")) == CYBRID_SIDE


static func _rule_accepts(rule: Dictionary, w: Dictionary, host: Dictionary, c: Dictionary) -> bool:
	if rule.packs == "host" and str(c.pack) != str(host.get("pack", "")):
		return false
	if rule.size == "same" and WeaponFit.size_of(c) != WeaponFit.size_of(w):
		return false
	if rule.match == "archetype":
		return make_archetype(c) == make_archetype(w)
	return WeaponFit.family_of(c) == WeaponFit.family_of(w)


## Sort key of candidate `c` (smaller = more alike): size distance, host pack first, archetype
## affinity, era distance to the weapon's own pack, stat distance, id.
static func make_rank(w: Dictionary, host: Dictionary, c: Dictionary) -> Array:
	return [
		absi(WeaponFit.rank(WeaponFit.size_of(c)) - WeaponFit.rank(WeaponFit.size_of(w))),
		0 if str(c.pack) == str(host.get("pack", "")) else 1,
		make_affinity(make_archetype(w), make_archetype(c)),
		make_era_distance(str(w.get("pack", "")), str(c.pack)),
		make_stat_distance(w, c),
		str(c.id),
	]


static func _less(a: Array, b: Array) -> bool:
	for k in a.size():
		if a[k] != b[k]:
			return a[k] < b[k]
	return false


## 0 for the same archetype, then the position in AFFINITY (unrelated archetypes last).
static func make_affinity(arch: String, other: String) -> int:
	if arch == other:
		return 0
	var near: Array = AFFINITY.get(arch, [])
	return near.find(other) + 1 if near.has(other) else near.size() + 1


static func make_era_distance(pack: String, other: String) -> int:
	var a := Packs.era(pack)
	var b := Packs.era(other)
	return NO_ERA_DISTANCE if a == Packs.ERA_UNKNOWN or b == Packs.ERA_UNKNOWN else absi(a - b)


## How different two weapons fire: |ln| ratios of refire, damage per trigger, speed and rounds.
static func make_stat_distance(a: Dictionary, b: Dictionary) -> float:
	var d := absf(log(_refire(a) / _refire(b)))
	d += absf(log(_damage(a) / _damage(b)))
	d += absf(log(_speed(a) / _speed(b)))
	return d + ROUNDS_WEIGHT * absf(log(_rounds(a) / _rounds(b)))


static func _refire(w: Dictionary) -> float:
	return maxf(float(w.get("refire", 0.0)), MIN_REFIRE_S)


static func _damage(w: Dictionary) -> float:
	var per_shot := float(w.get("shield_damage", 0.0)) + float(w.get("armor_damage", 0.0))
	return maxf(per_shot * maxi(int(w.get("burst", 1)), 1), 1.0)


static func _speed(w: Dictionary) -> float:
	if _projectile(w).is_empty() and str(w.get("kind", "")) == "beam":
		return BEAM_SPEED_MPS
	return maxf(float(w.get("speed", 0.0)), 1.0)


static func _rounds(w: Dictionary) -> float:
	return maxf(float(w.get("ammo", -1)), 1.0)


## "looks like: es1 LAS200 (archetype_size_host)" for tooltips; "" when the weapon shows its own model.
static func make_label(choice: Dictionary) -> String:
	var rule := str(choice.get("rule", ""))
	if rule == "":
		return ""
	var src := Packs.weapon(str(choice.get("weapon", ""))) if str(choice.get("weapon", "")) != "" else {}
	if src.is_empty():
		return "looks like: stand-in pod (%s)" % rule
	return "looks like: %s %s (%s)" % [src.pack, src.name, rule]
