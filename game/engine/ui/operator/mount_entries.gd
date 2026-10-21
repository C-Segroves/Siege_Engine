class_name MountEntries
extends RefCounted
## The component slots of a Starsiege Herc as Operator Setup shows them (HercMounts has the rules): one loadout row per
## free slot ("mount:<i>") and, with such a row selected, the store entries that fit it - the factory fit, empty, and the
## cloaks no larger than the slot. Pure data; OperatorEquip puts an entry into the slot's `herc_mounts`.

const KIND_ROW := "mount"
const KIND_PART := "mount_part"
const KEY_PREFIX := "mount:"
const KG_PER_TONNE := 1000.0


static func is_mount_row(row_key: String) -> bool:
	return row_key.begins_with(KEY_PREFIX)


static func make_slot_index(row_key: String) -> int:
	return int(row_key.get_slice(":", 1))


## The loadout rows of `slot`'s vehicle for its component slots ([] when it has none), in LoadoutLayout's row shape.
static func make_rows(slot: CharacterSlot, ctx: LoadoutContext) -> Array:
	var v := Packs.vehicle(slot.vehicle)
	var mounts := slot.make_mounts()
	var rows := []
	for r in HercMounts.make_rows(v, mounts):
		var i := make_slot_index(str(r.key))
		rows.append({"key": r.key, "kind": KIND_ROW, "label": r.label, "accepts": KIND_ROW,
			"current": HercMounts.make_label(v, i, int(mounts[i])), "ammo": 0, "ammo_max": 0,
			"locked": ctx.source == LoadoutContext.SOURCE_STASH})
	return rows


## The store entries for row `row_key` of `slot` (StoreCatalog's entry shape, always free): [] when the row is no slot.
static func make_entries(slot: CharacterSlot, row_key: String) -> Array:
	var v := Packs.vehicle(slot.vehicle)
	var mounts := slot.make_mounts()
	for r in HercMounts.make_rows(v, mounts):
		if r.key == row_key:
			return (r.options as Array).map(_make_entry.bind(v, row_key, int(r.current)))
	return []


static func _make_entry(option: Dictionary, v: Dictionary, row_key: String, current: int) -> Dictionary:
	var fitted := "> " if int(option.id) == current else ""
	var size_text := "mount size %s" % option.size if str(option.size) != "" else ""
	return {"id": "%s:%d" % [row_key, int(option.id)], "kind": KIND_PART, "name": fitted + str(option.name),
		"pack": str(v.get("pack", "")), "state": StoreCatalog.STATE_FREE, "price": 0, "reason": "", "detail": size_text,
		"tooltip_lines": [], "kg": float(option.mass_t) * KG_PER_TONNE, "slots": 0, "rating": 0.0, "shape_id": "",
		"skin_ids": [], "mount_row": row_key, "mount_value": int(option.id)}
