class_name CharacterSlot
extends RefCounted
## One of the operator's character slots (docs/design/lobby_loadout_economy.md section 2.2): an armour with its body
## and skin, the infantry kit, a preferred vehicle with its skin and weapons. It replaced the old loadout presets. A slot is
## kept as the player built it; make_resolved gives the build a match will use, with what the match forbids or the
## operator does not own replaced by the free default, and never edits the slot (so a bought-back unlock or an
## installed pack restores the look).

const MAX_LABEL := 24
const DEFAULT_LABEL := "Slot %d"

var index := 0
var label := ""
var pack := ""
var armor := ""
var body := ""
var skin := ""
var vehicle := ""
var herc_skin := ""
var infantry := {"weapons": [], "ammo": {}, "gear": {}, "pack": ""}
var herc_loadout: Array = []
## The component per free slot of a Starsiege Herc (HercMounts: 0 factory fit, -1 emptied, else a component id).
var herc_mounts: Array = []


## A new slot `i`: the free armour, its default look and kit, the starter vehicle.
static func make_default(i: int) -> CharacterSlot:
	var s := CharacterSlot.new()
	s.index = i
	s.label = DEFAULT_LABEL % (i + 1)
	s.apply_armor_defaults(make_free_armor_id(""))
	s.apply_vehicle_defaults(FreeUnlocks.make_default_vehicle())
	return s


## The free armour of infantry game `for_pack` ("" = the first free armour installed); "" when none is installed.
static func make_free_armor_id(for_pack: String) -> String:
	var free: Array = EconomyRules.free_unlocks().get("armor", [])
	for id in free:
		if not InfantryCatalog.armor(str(id)).is_empty() and (for_pack == "" or str(id).begins_with(for_pack + ":")):
			return str(id)
	if for_pack != "":
		return InfantryCatalog.light_armor_id(for_pack)
	return InfantryCatalog.light_armor_id(InfantryCatalog.make_default_pack())


## Puts on `armor_id` with its default body, skin and kit (spawn weapons with their ammunition, the first grenade).
func apply_armor_defaults(armor_id: String) -> void:
	armor = armor_id
	pack = armor_id.get_slice(":", 0) if armor_id != "" else ""
	body = ""
	skin = ""
	var a := InfantryCatalog.armor(armor_id)
	var weapons: Array = (a.get("default_loadout", []) as Array).duplicate()
	var ammo := {}
	for w in weapons:
		var load := int((a.get("ammo", {}) as Dictionary).get(w, 0))
		if load > 0:
			ammo[str(w)] = load
	var gear := {}
	for g in InfantryGear.grenades_of(a).slice(0, 1):
		gear[str(g)] = int((a.get("hand_items", {}) as Dictionary).get(g, 1))
	infantry = {"weapons": weapons, "ammo": ammo, "gear": gear, "pack": ""}


## Prefers vehicle `vehicle_id` with its standard weapons and the default skin.
func apply_vehicle_defaults(vehicle_id: String) -> void:
	vehicle = vehicle_id
	herc_skin = ""
	herc_loadout = []
	herc_mounts = HercMounts.make_sanitized(Packs.vehicle(vehicle_id), [])
	var v := Packs.vehicle(vehicle_id)
	if not v.is_empty():
		for w in Packs.default_loadout(v):
			herc_loadout.append(str(w) if w != null else "")


func is_complete() -> bool:
	var needs_armor := InfantryCatalog.make_default_pack() != ""
	var needs_vehicle := not Packs.pilotable().is_empty()
	return (armor != "" or not needs_armor) and (vehicle != "" or not needs_vehicle)


# ------------------------------------------------------------------ the match's view

## The roster keys of the build `ctx` allows (the legacy keys the battle reads, plus the compact "slot" snapshot).
func make_roster_fields(ctx: LoadoutContext) -> Dictionary:
	var built: CharacterSlot = make_resolved(ctx, ctx.unlocks).slot
	return {"vehicle": built.vehicle, "loadout": built.herc_loadout.duplicate(), "mounts": built.make_mounts(), PlayerProfile.ARMOR_KEY: built.armor,
		PlayerProfile.BODY_KEY: built.body, PlayerProfile.SKIN_KEY: built.skin, PlayerProfile.HERC_SKIN_KEY: built.herc_skin,
		"slot": built.make_roster_snapshot()}


## The compact form that travels in the roster (about 250 bytes, section 7.1).
func make_roster_snapshot() -> Dictionary:
	return {"i": index, "a": armor, "b": body, "s": skin, "v": vehicle, "hs": herc_skin,
		"w": (infantry.weapons as Array).duplicate(), "am": (infantry.ammo as Dictionary).duplicate(),
		"g": (infantry.gear as Dictionary).duplicate(), "p": str(infantry.pack), "hl": herc_loadout.duplicate(),
		"hm": make_mounts()}


## The component slots of the preferred vehicle filled from `herc_mounts` (factory fit where nothing was chosen).
func make_mounts() -> Array:
	return HercMounts.make_sanitized(Packs.vehicle(vehicle), herc_mounts)


static func make_from_snapshot(d: Dictionary) -> CharacterSlot:
	var s := CharacterSlot.new()
	s.apply_snapshot(d)
	return s


func apply_snapshot(d: Dictionary) -> void:
	index = int(d.get("i", 0))
	label = DEFAULT_LABEL % (index + 1)
	armor = str(d.get("a", ""))
	pack = armor.get_slice(":", 0) if armor != "" else ""
	body = str(d.get("b", ""))
	skin = str(d.get("s", ""))
	vehicle = str(d.get("v", ""))
	herc_skin = str(d.get("hs", ""))
	infantry = {"weapons": make_strings(d.get("w", [])), "ammo": make_counts(d.get("am", {})), "gear": make_counts(d.get("g", {})),
		"pack": str(d.get("p", ""))}
	herc_loadout = make_strings(d.get("hl", []))
	herc_mounts = make_ints(d.get("hm", []))


## What `ctx` forbids or the operator does not own: [{part, id, text}]. `part` names the slot field.
func make_blocks(ctx: LoadoutContext) -> Array:
	return SlotCheck.make_blocks(self, ctx, ctx.unlocks)


## The build the match will use: {slot: CharacterSlot, dropped: [text]}. Parts the context forbids or `owned` lacks
## are replaced by the free default; the saved slot is not touched.
func make_resolved(ctx: LoadoutContext, owned: Unlocks) -> Dictionary:
	return SlotCheck.make_resolved(self, ctx, owned)


func make_copy() -> CharacterSlot:
	var s := CharacterSlot.new()
	s.apply_dict(to_dict())
	return s


# ------------------------------------------------------------------ save form

func to_dict() -> Dictionary:
	return {"index": index, "label": label, "pack": pack, "armor": armor, "body": body, "skin": skin, "vehicle": vehicle,
		"herc_skin": herc_skin, "infantry": {"weapons": (infantry.weapons as Array).duplicate(),
		"ammo": (infantry.ammo as Dictionary).duplicate(), "gear": (infantry.gear as Dictionary).duplicate(),
		"pack": str(infantry.pack)}, "herc_loadout": herc_loadout.duplicate(), "herc_mounts": herc_mounts.duplicate()}


func apply_dict(d: Dictionary) -> void:
	index = int(d.get("index", 0))
	label = str(d.get("label", DEFAULT_LABEL % (index + 1))).strip_edges().left(MAX_LABEL)
	armor = str(d.get("armor", ""))
	pack = str(d.get("pack", armor.get_slice(":", 0) if armor != "" else ""))
	body = str(d.get("body", ""))
	skin = str(d.get("skin", ""))
	vehicle = str(d.get("vehicle", ""))
	herc_skin = str(d.get("herc_skin", ""))
	var inf: Dictionary = d.get("infantry", {}) if d.get("infantry") is Dictionary else {}
	infantry = {"weapons": make_strings(inf.get("weapons", [])), "ammo": make_counts(inf.get("ammo", {})),
		"gear": make_counts(inf.get("gear", {})), "pack": str(inf.get("pack", ""))}
	herc_loadout = make_strings(d.get("herc_loadout", []))
	herc_mounts = make_ints(d.get("herc_mounts", []))


## JSON arrays hold nulls and numbers where strings were saved: always strings.
static func make_strings(list: Variant) -> Array:
	var out := []
	if list is Array:
		for x in list:
			out.append(str(x) if x != null else "")
	return out


## JSON numbers come back as floats: component ids are ints.
static func make_ints(list: Variant) -> Array:
	var out := []
	if list is Array:
		for x in list:
			out.append(int(x) if x != null else 0)
	return out


## JSON numbers come back as floats: counts are ints.
static func make_counts(table: Variant) -> Dictionary:
	var out := {}
	if table is Dictionary:
		for key in table:
			out[str(key)] = int(table[key])
	return out
