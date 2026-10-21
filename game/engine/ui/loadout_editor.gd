class_name LoadoutEditor
extends VBoxContainer
## Armory: one weapon picker per hardpoint, listing every enabled game's Herc-family weapons that
## fit the hardpoint's size (Packs.weapons_for_mask(..., "herc")). In a campaign the list is limited
## by the campaign's availability context (CampaignAvailability): unlocked / older / equivalent
## weapons are unlimited, counted stock shows the units left in the garage's armory ("x2") and is
## greyed out at 0 (the Hangar screen moves units between armory and hardpoints, Garage.apply_arm).
## A fixed-loadout vehicle (Tribes) shows its standard armament read-only: nothing to pick, `changed`
## never fires.
##   setup(vehicle_id, current, availability)   rebuild for a vehicle; `current` is used when it fits
##   changed(loadout)                weapon ids in hardpoint order ("" = empty)
##   hardpoint_focused(index)        the player is looking at hardpoint `index` (for the hangar)
##   mounts_changed(mounts)          a Starsiege Herc's component slots (HercMounts), one picker per slot below the
##                                   weapons: the factory fit, empty, or a cloak that fits the slot's size
##   focus_hardpoint(index)          moves keyboard / gamepad focus to that hardpoint's picker

signal changed(loadout: Array)
signal hardpoint_focused(index: int)
signal mounts_changed(mounts: Array)

## Hardpoint masks (WeaponFit ladder): 7 small / missile, 15 medium, 31 large, 63 extra large (Starsiege).
const MOUNT_NAMES := {7: "small", 15: "medium", 31: "large", 63: "extra large"}
const DEFAULT_MASK := 15
const WEAPON_FAMILY := "herc"
const EMPTY_SLOT := ""
const STANDARD_ARMAMENT := "Standard armament  -  fixed, as in %s"
const COMPONENTS_TITLE := "Components  -  %d slots"
const UNARMED := "Unarmed  -  no weapons of its own (AI only)"

var vehicle_id := ""
var loadout: Array = []
var mounts: Array = []           # HercMounts value per component slot ([] = the vehicle has none)
var availability := {}           # CampaignAvailability context ({} = no limits)
var _choices: Array = []         # per hardpoint: Array of weapon ids, index = picker item
var _pickers: Array = []         # per hardpoint: its OptionButton
var _mount_pickers: Array = []   # per component slot: its OptionButton
var _mount_ids: Array = []       # per component slot: the value of each picker item


func setup(p_vehicle_id: String, current: Array = [], p_availability := {}, p_mounts: Array = []) -> void:
	vehicle_id = p_vehicle_id
	availability = p_availability
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_choices.clear()
	_pickers.clear()
	_mount_pickers.clear()
	_mount_ids.clear()
	var v := Packs.vehicle(vehicle_id)
	mounts = HercMounts.make_sanitized(v, p_mounts)
	if PackVehicleLoader.has_fixed_loadout(v):
		_build_standard_armament(v)
		return
	var masks := hardpoint_masks(v)
	loadout = current.duplicate() if current.size() == masks.size() else v.get("loadout", []).duplicate()
	loadout.resize(masks.size())
	add_child(Widgets.section("Armory  -  %d hardpoints" % masks.size()))
	for i in masks.size():
		add_child(_build_row(v, i, masks[i]))
	_apply_stock_limits()
	_build_component_rows(v)


## Hardpoint masks of a vehicle (WeaponFit.hardpoint_masks).
static func hardpoint_masks(v: Dictionary) -> Array:
	return WeaponFit.hardpoint_masks(v)


## One picker per component slot (HercMounts.make_rows): the factory fit, empty, or a cloak that fits the slot.
func _build_component_rows(v: Dictionary) -> void:
	var rows := HercMounts.make_rows(v, mounts)
	if rows.is_empty():
		return
	add_child(Widgets.section(COMPONENTS_TITLE % rows.size()))
	for i in rows.size():
		var row: Dictionary = rows[i]
		var ids := []
		var labels := []
		for o in row.options:
			ids.append(int(o.id))
			labels.append(make_component_label(o))
		var picker := Widgets.option_button(labels, maxi(ids.find(int(row.current)), 0))
		_mount_ids.append(ids)
		_mount_pickers.append(picker)
		picker.item_selected.connect(func(k: int) -> void: _on_component_picked(i, k))
		add_child(OptionRow.new(str(row.label), picker))


## "Chameleon Cloak  [M, 1.0 t]" - a part with its mount size and mass; the factory / empty choices as they are.
static func make_component_label(option: Dictionary) -> String:
	if str(option.size) == "":
		return str(option.name)
	return "%s  [%s, %.1f t]" % [option.name, option.size, float(option.mass_t)]


func _on_component_picked(slot: int, choice: int) -> void:
	if HercMounts.apply_set(Packs.vehicle(vehicle_id), mounts, slot, int(_mount_ids[slot][choice])):
		mounts_changed.emit(mounts)


func focus_component(slot: int) -> void:
	if is_inside_tree() and slot >= 0 and slot < _mount_pickers.size():
		(_mount_pickers[slot] as OptionButton).grab_focus()


## Read-only rows: one per fixed mount, its weapon and stats.
func _build_standard_armament(v: Dictionary) -> void:
	loadout = (v.get("loadout", []) as Array).duplicate()
	add_child(Widgets.section(STANDARD_ARMAMENT % Packs.pack_name(str(v.get("pack", ""))) if not loadout.is_empty() else UNARMED))
	for i in loadout.size():
		var w := Packs.weapon(str(loadout[i]))
		var text := make_weapon_label({}, w) if not w.is_empty() else "(none)"
		add_child(OptionRow.new("%d. fixed mount" % (i + 1), Widgets.label(text, "DimLabel")))


func _build_row(v: Dictionary, index: int, mask: int) -> OptionRow:
	var ids := [EMPTY_SLOT]
	var labels := ["(empty)"]
	for w in _make_offered(v, index, mask):
		ids.append(w.id)
		labels.append(make_weapon_label(availability, w))
	_choices.append(ids)
	var picker := Widgets.option_button(labels, _initial_choice(index, ids))
	_pickers.append(picker)
	loadout[index] = ids[picker.selected]
	_apply_look_tooltip(index)
	picker.item_selected.connect(func(k: int) -> void: _on_weapon_picked(index, k))
	picker.mouse_entered.connect(func() -> void: hardpoint_focused.emit(index))
	picker.focus_entered.connect(func() -> void: hardpoint_focused.emit(index))
	var mount: String = MOUNT_NAMES.get(mask, str(mask))
	return OptionRow.new("%d. %s mount" % [index + 1, mount], picker)


## Weapons that fit the hardpoint and the campaign offers (the weapon already there always stays).
func _make_offered(v: Dictionary, index: int, mask: int) -> Array:
	var current := str(loadout[index]) if loadout[index] != null else EMPTY_SLOT
	var cybrid_ok := CampaignAvailability.allows_cybrid_weapons(availability, str(v.get("side", "herc")))
	var fitting := Packs.weapons_for_mask(mask, cybrid_ok, WEAPON_FAMILY, make_fit_rules(availability))
	fitting = fitting.filter(func(w): return WeaponFit.fits_bay(w, v, index))
	var allowed := CampaignAvailability.filter_choices(availability, fitting.map(func(w): return str(w.id)))
	return fitting.filter(func(w): return allowed.has(str(w.id)) or str(w.id) == current)


## "Name  [Game]  stats"; in a campaign "Name  [Game]  x2 (in stock)  stats" - the stock count and
## why it is offered come before the stats so a clipped picker still shows them.
static func make_weapon_label(ctx: Dictionary, w: Dictionary) -> String:
	var head := "%s  [%s]" % [w.get("display_name", w.name), Packs.pack_name(w.pack)]
	if not CampaignAvailability.is_restricted(ctx):
		return "%s  %s" % [head, make_summary(w)]
	var count := CampaignAvailability.make_count_label(CampaignAvailability.make_weapon_count(ctx, str(w.id)))
	var reason := CampaignAvailability.make_weapon_reason(ctx, str(w.id))
	return "%s  %s(%s)%s  %s" % [head, count + " " if count != "" else "", reason if reason != "" else "mounted",
		make_price_label(ctx, w, reason), make_summary(w)]


## "  fabricate 5 t" for a weapon the campaign builds for salvage (GarageEconomy), else "".
static func make_price_label(ctx: Dictionary, w: Dictionary, reason: String) -> String:
	if reason == CampaignAvailability.REASON_STOCK or reason == "":
		return ""
	var price := GarageEconomy.of_context(ctx).make_weapon_price(str(w.id))
	return "  fabricate %s" % GarageEconomy.make_tons_text(price) if price > 0 else ""


## The current weapon if this hardpoint offers it, else the first real weapon.
func _initial_choice(index: int, ids: Array) -> int:
	var current: String = str(loadout[index]) if loadout[index] != null else EMPTY_SLOT
	if ids.has(current):
		return ids.find(current)
	return 1 if ids.size() > 1 else 0


func _on_weapon_picked(index: int, choice: int) -> void:
	loadout[index] = _choices[index][choice]
	_apply_look_tooltip(index)
	_apply_stock_limits()
	changed.emit(loadout)
	hardpoint_focused.emit(index)


## Debug tooltip on a picker: the model a weapon without its own is drawn with (WeaponLookalike).
func _apply_look_tooltip(index: int) -> void:
	var wid := str(loadout[index]) if loadout[index] != null else EMPTY_SLOT
	var w := Packs.weapon(wid) if wid != EMPTY_SLOT else {}
	(_pickers[index] as OptionButton).tooltip_text = make_look_label(Packs.vehicle(vehicle_id), index, w)


## "looks like: es1 LAS200 (archetype_size_host)" for weapon `w` on hardpoint `index`; "" when it shows
## its own model (or none).
static func make_look_label(v: Dictionary, index: int, w: Dictionary) -> String:
	if w.is_empty():
		return ""
	return WeaponLookalike.make_label(HercModel.mount_plan(v, index, w).get("lookalike", {}))


func focus_hardpoint(index: int) -> void:
	if is_inside_tree() and index >= 0 and index < _pickers.size():
		(_pickers[index] as OptionButton).grab_focus()


## Greys out counted weapons with no unit left in the armory (the mounted one stays pickable).
func _apply_stock_limits() -> void:
	if not CampaignAvailability.is_restricted(availability):
		return
	for row in _pickers.size():
		var picker: OptionButton = _pickers[row]
		for k in picker.item_count:
			var same := CampaignAvailability.base_weapon(str(_choices[row][k])) == CampaignAvailability.base_weapon(str(loadout[row]))
			picker.set_item_disabled(k, not same and not CampaignAvailability.can_mount(availability, str(_choices[row][k]), 0))


## WeaponFit rules of an availability context (the match mode's Cybrid-weapon rule).
static func make_fit_rules(ctx: Dictionary) -> Dictionary:
	return {CampaignAvailability.CYBRID_RULE: bool(ctx.get(CampaignAvailability.CYBRID_RULE, false))}


## One-line stats: kind, range, refire, ammo, shield / armour damage.
static func make_summary(w: Dictionary) -> String:
	var ammo := ", ammo %d" % w.ammo if w.ammo >= 0 else ""
	return "%s, %d m, %.1fs%s, %d/%d dmg" % [w.kind, int(w.range), w.refire, ammo,
		int(w.shield_damage), int(w.armor_damage)]
