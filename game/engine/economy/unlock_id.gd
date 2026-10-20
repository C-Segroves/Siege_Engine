class_name UnlockId
extends RefCounted
## Ids of unlocks (docs/design/lobby_loadout_economy.md section 2.1): "<kind>/<ref>", the shape ExtractionItems uses.
## Refs are pack-qualified ("tribes:DISC"); a skin ref is "<body shape id>#<skin id>". An unlock id and a stash item
## id can be the same string: they live in different containers.
##   armor/tribes:MEDIUM       body/tribes2:bioderm_medium     skin/<body shape id>#<skin id>
##   vehicle/es1:RAPTOR        herc_skin/<vehicle shape id>#<skin id>
##   weapon/tribes:DISC        herc_weapon/es1:LASER           ammo/tribes:DISC
##   gear/tribes:GRENADE       pack/tribes:ENERGY_PACK

const SEPARATOR := "/"
const SKIN_SEPARATOR := "#"
const KINDS := ["armor", "body", "skin", "vehicle", "herc_skin", "weapon", "herc_weapon", "ammo", "gear", "pack"]
## Kinds that change how the soldier or Herc looks or what it is (at risk in extraction, bought back for 100 cr).
const LOOK_KINDS := ["armor", "body", "skin", "vehicle", "herc_skin"]
const INFANTRY_CATEGORY := "infantry"


static func make(kind: String, ref: String) -> String:
	return kind + SEPARATOR + ref


static func make_skin_ref(shape_id: String, skin_id: String) -> String:
	return shape_id + SKIN_SEPARATOR + skin_id


static func kind_of(id: String) -> String:
	return id.get_slice(SEPARATOR, 0)


static func ref_of(id: String) -> String:
	return id.substr(id.find(SEPARATOR) + 1)


static func is_valid(id: String) -> bool:
	return id.contains(SEPARATOR) and KINDS.has(kind_of(id)) and ref_of(id) != ""


## The pack of the id's ref ("tribes2:bioderm#red" -> "tribes2"); "" when the ref carries none.
static func pack_of(id: String) -> String:
	var ref := ref_of(id).get_slice(SKIN_SEPARATOR, 0)
	return ref.get_slice(":", 0) if ref.contains(":") else ""


## The shape a body, skin or herc skin id names (the part before "#").
static func shape_of(id: String) -> String:
	return ref_of(id).get_slice(SKIN_SEPARATOR, 0)


## The skin id of a skin / herc skin id ("" = none).
static func skin_of(id: String) -> String:
	var ref := ref_of(id)
	return ref.get_slice(SKIN_SEPARATOR, 1) if ref.contains(SKIN_SEPARATOR) else ""


## "weapon" for an infantry hand weapon, "herc_weapon" for every other family.
static func make_weapon_kind(weapon_id: String) -> String:
	return "weapon" if str(Packs.weapon(weapon_id).get("category", "herc")) == INFANTRY_CATEGORY else "herc_weapon"


static func make_weapon_id(weapon_id: String) -> String:
	return make(make_weapon_kind(weapon_id), weapon_id)


## What a loadout row takes for `id`: the skin id of a skin, else the ref (weapon id, armour id ...).
static func make_part_of(id: String) -> String:
	return skin_of(id) if kind_of(id) in ["skin", "herc_skin"] else ref_of(id)
