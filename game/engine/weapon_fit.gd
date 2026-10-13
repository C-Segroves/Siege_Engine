class_name WeaponFit
extends RefCounted
## Hardpoint size classes shared by every Herc-family game, and the rule for which weapon fits which
## hardpoint (docs/formats/campaign_availability.md section 4).
##
## Every game states sizes as a hardpoint mask (ES1/ES2 GL byte 25, Battledrome bay type, Starsiege
## newHardPoint size letter), and the masks of all four games share one ladder: 7 small, 15 medium,
## 31 large, 63 extra large (Starsiege only). A weapon fits a hardpoint when its size class is not
## larger than the hardpoint's - for masks on the ladder this is exactly the original
## "hardpoint mask >= weapon mask" test, so every game keeps its native combinations.

const SIZES := ["S", "M", "L", "X"]
const SIZE_MASKS := {"S": 7, "M": 15, "L": 31, "X": 63}
## Starsiege turret-only / internal weapons (exporter NO_FIT_MASK 127): never on a hardpoint.
const INTERNAL := "I"
const INTERNAL_RANK := 99
const NO_SIZE_RANK := -1
## Hardpoint mask assumed when a vehicle lists none (LoadoutEditor.DEFAULT_MASK).
const DEFAULT_MASK := 15
## Only Herc-family weapons and hardpoints get size classes; infantry/vehicle families never mix.
const HERC_FAMILY := "herc"
## Match rule: Cybrid-only weapons fit any Herc or tank by size alone (default false = original).
const RULE_CYBRID_WEAPONS_ON_HERCS := "cybrid_weapons_on_hercs"
## Visual families for reference boxes and stand-in pods (weapon schema "kind").
const LAUNCHER_KINDS := ["missile", "mine", "grenade"]
## Battledrome bay type 3 (bd_weapons.md section 6): the mine launcher at the Herc's back, its muzzle behind
## the hull (MINE POD, muzzle y -1200). Only mines go there: anything aimed would fire through the Herc.
const MINE_BAY := "MINE LNCHR"
const POD_KINDS := ["ecm", "other"]


## Size class of a weapon mask: the smallest class whose mask covers it ("I" above X).
static func size_for_weapon_mask(mask: int) -> String:
	for s in SIZES:
		if mask <= int(SIZE_MASKS[s]):
			return s
	return INTERNAL


## Size class of a hardpoint mask: the largest class it covers ("" when it covers none).
static func size_for_hardpoint_mask(mask: int) -> String:
	var out := ""
	for s in SIZES:
		if mask >= int(SIZE_MASKS[s]):
			out = s
	return out


## Order of size classes (S 0 … X 3); internal weapons rank above everything.
static func rank(size: String) -> int:
	if size == INTERNAL:
		return INTERNAL_RANK
	return SIZES.find(size)


## The smaller of two size classes.
static func smaller(a: String, b: String) -> String:
	return a if rank(a) <= rank(b) else b


## Original hardpoint mask a weapon needs (catalog "hardpoint_mask", else by its size_class).
static func weapon_mask(w: Dictionary) -> int:
	return int(w.get("hardpoint_mask", PackWeaponLoader.SIZE_MASK.get(w.get("size_class", "light"), 7)))


## Size class of a weapon (catalog "size", set by PackWeaponLoader; else from its mask).
static func size_of(w: Dictionary) -> String:
	var s := str(w.get("size", ""))
	return s if s != "" else size_for_weapon_mask(weapon_mask(w))


## Visual family of a weapon: "gun", "launcher" or "pod".
static func family_of(w: Dictionary) -> String:
	var kind := str(w.get("kind", ""))
	if kind in LAUNCHER_KINDS:
		return "launcher"
	if kind in POD_KINDS:
		return "pod"
	return "gun"


## Hardpoint masks of a vehicle, from its guns or (older data) from its default weapons.
static func hardpoint_masks(v: Dictionary) -> Array:
	var out := []
	for g in v.get("guns", []):
		out.append(int(g.get("hardpoint_mask", DEFAULT_MASK)))
	if out.is_empty():
		for id in v.get("loadout", []):
			var w: Dictionary = Packs.weapon(str(id)) if id != null else {}
			out.append(weapon_mask(w) if not w.is_empty() else DEFAULT_MASK)
	return out


## Size class of hardpoint i of vehicle v ("" when it has no such hardpoint).
static func hardpoint_size(v: Dictionary, i: int) -> String:
	var guns: Array = v.get("guns", [])
	if i >= 0 and i < guns.size() and str(guns[i].get("size", "")) != "":
		return str(guns[i].size)
	var masks := hardpoint_masks(v)
	return size_for_hardpoint_mask(int(masks[i])) if i >= 0 and i < masks.size() else ""


## True if weapon `w` fits a hardpoint with the given original mask. `include_cybrid` = Cybrid-only
## weapons may be mounted there (see allows_cybrid_weapons); true checks the size alone.
static func fits_mask(w: Dictionary, hardpoint_mask: int, include_cybrid := true) -> bool:
	if w.get("cybrid_only", false) and not include_cybrid:
		return false
	var need := rank(size_of(w))
	return need != NO_SIZE_RANK and need <= rank(size_for_hardpoint_mask(hardpoint_mask))


## Whether Cybrid-only weapons may go on vehicle v: always on Cybrids; on Hercs and tanks only
## when the match sets RULE_CYBRID_WEAPONS_ON_HERCS (arena / versus / skirmish; campaign and
## co-op keep the original Cybrid-only rule, campaign_availability.md section 2).
static func allows_cybrid_weapons(v: Dictionary, rules := {}) -> bool:
	return v.get("side", "herc") == "cybrid" or bool(rules.get(RULE_CYBRID_WEAPONS_ON_HERCS, false))


## True if weapon `w` may be mounted on hardpoint i of vehicle v: same weapon family, Cybrid-only
## weapons only where allowed (allows_cybrid_weapons), and the size class fits. Nothing fits a mount of
## a fixed-loadout vehicle (PackVehicleLoader.has_fixed_loadout).
static func fits(w: Dictionary, v: Dictionary, i: int, rules := {}) -> bool:
	if PackVehicleLoader.has_fixed_loadout(v):
		return false
	if str(w.get("category", HERC_FAMILY)) != str(v.get("category", HERC_FAMILY)):
		return false
	var masks := hardpoint_masks(v)
	if i < 0 or i >= masks.size() or not fits_bay(w, v, i):
		return false
	return fits_mask(w, int(masks[i]), allows_cybrid_weapons(v, rules))


## A mine launcher bay takes mines only (MINE_BAY); every other hardpoint goes by size.
static func fits_bay(w: Dictionary, v: Dictionary, i: int) -> bool:
	var guns: Array = v.get("guns", [])
	if i >= guns.size() or str((guns[i] as Dictionary).get("bay", "")) != MINE_BAY:
		return true
	return str(w.get("kind", "")) == "mine"


## Stores each Herc-family hardpoint's size class in the vehicle definition (guns[i].size).
static func apply_hardpoint_sizes(v: Dictionary) -> void:
	if str(v.get("category", HERC_FAMILY)) != HERC_FAMILY:
		return
	for g in v.get("guns", []):
		if str(g.get("size", "")) == "":
			g["size"] = size_for_hardpoint_mask(int(g.get("hardpoint_mask", DEFAULT_MASK)))
