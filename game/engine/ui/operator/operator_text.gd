class_name OperatorText
extends RefCounted
## The words of Operator Setup: row names, price marks, the fit line, the detail plate of an entry or a row. Pure
## functions of plain data (docs/design/lobby_loadout_economy.md section 6.1).

const EMPTY_STORE := "(empty - pick from the store)"
const EMPTY_PARTS := "(empty - pick from the parts list)"
const KIND_LABELS := {"weapon": "Hand weapon", "herc_weapon": "Herc weapon", "ammo": "Ammunition", "gear": "Gear",
	"pack": "Backpack", "armor": "Armour", "body": "Model", "skin": "Skin", "vehicle": "Vehicle", "herc_skin": "Vehicle skin"}


## The unlock id the part in `row` stands for ("" for an empty row or one that holds no unlock).
static func make_row_unlock_id(row: Dictionary) -> String:
	var current := str(row.current)
	if current == "":
		return ""
	match str(row.kind):
		"armour":
			return UnlockId.make("armor", current)
		"weapon", "ammo", "gear", "pack":
			return UnlockId.make(str(row.kind), current)
		"hardpoint":
			return UnlockId.make("herc_weapon", current)
	return ""


## The LoadoutLayout row key a SlotCheck block `part` belongs to ("armor" is the "armour" row).
static func make_row_key_of_part(part: String) -> String:
	return "armour" if part == "armor" else part


## What the row shows for its part: the name, or the empty-row prompt.
static func make_row_name(row: Dictionary, has_store: bool) -> String:
	var id := make_row_unlock_id(row)
	if id != "":
		return SlotCheck.make_name(id)
	if str(row.kind) == "gear":
		return "(none)"
	return EMPTY_STORE if has_store else EMPTY_PARTS


## "Fit 2/3 weapons   41.2/50 kg" (a vehicle: "Hardpoints 2/3").
static func make_fit_text(side: String, fit: Dictionary) -> String:
	if side == LoadoutLayout.SIDE_VEHICLE:
		return "Hardpoints %d/%d" % [fit.slots, fit.slots_max]
	return "Fit %d/%d weapons   %.1f/%.0f kg" % [fit.slots, fit.slots_max, fit.kg, fit.kg_max]


## The price mark of a store entry: "" when free, "owned", "3,000 cr", "buy back 100 cr".
static func make_price_text(entry: Dictionary) -> String:
	match str(entry.state):
		StoreCatalog.STATE_OWNED:
			return "owned"
		StoreCatalog.STATE_FOR_SALE:
			return EconomyRules.make_money_text(int(entry.price))
		StoreCatalog.STATE_LOST:
			return "buy back %s" % EconomyRules.make_money_text(int(entry.price))
	return ""


## The detail plate (ItemTooltip data) of a store entry; `fit_reason` is OperatorEquip.make_fit_reason's answer.
static func make_tooltip(entry: Dictionary, fit_reason := "") -> Dictionary:
	var lines := []
	var kind_label := str(KIND_LABELS.get(str(entry.kind), ""))
	if kind_label != "":
		lines.append(kind_label)
	if str(entry.detail) != "":
		lines.append(str(entry.detail))
	lines.append_array(make_stat_lines(entry))
	var data := {"title": str(entry.name), "subtitle": Packs.pack_name(str(entry.pack)) if str(entry.pack) != "" else "", "lines": lines,
		"price": make_price_line(entry), "warning": ""}
	if str(entry.state) == StoreCatalog.STATE_NOT_ALLOWED:
		data.warning = str((EconomyRules.data().get("tooltips", {}) as Dictionary).get("not_allowed", "%s")) % str(entry.reason)
	elif fit_reason != "":
		data.warning = fit_reason
	return data


## "3.1 kg", "uses 1 weapon slot", "rating 4.2" for the numbers an entry has.
static func make_stat_lines(entry: Dictionary) -> Array:
	var out := []
	if float(entry.kg) > 0.0:
		out.append("%.1f kg" % float(entry.kg))
	if int(entry.slots) > 0 and str(entry.kind) == "weapon":
		out.append("uses %d weapon slot" % int(entry.slots))
	if float(entry.rating) > 0.0:
		out.append("rating %.1f" % float(entry.rating))
	return out


static func make_price_line(entry: Dictionary) -> String:
	match str(entry.state):
		StoreCatalog.STATE_FREE:
			return "Free"
		StoreCatalog.STATE_OWNED:
			return "Owned"
		StoreCatalog.STATE_FOR_SALE:
			if bool(entry.get("stock", false)):
				return "Price %s per lot (to the stash)" % EconomyRules.make_money_text(int(entry.price))
			return "Price %s (first purchase)" % EconomyRules.make_money_text(int(entry.price))
		StoreCatalog.STATE_LOST:
			return str((EconomyRules.data().get("tooltips", {}) as Dictionary).get("lost", "%d")) % int(entry.price)
	return ""


## The badge a row of the loadout list can carry: [] or [text, theme variation].
static func make_row_badge(blocked: String, at_risk: bool, lost: bool) -> Array:
	if blocked != "":
		return ["NOT ALLOWED", "BadgeNotAllowed"]
	if lost:
		return ["LOST - %s" % EconomyRules.make_money_text(EconomyRules.rebuy_price()), "BadgeLost"]
	if at_risk:
		return ["AT RISK", "BadgeAtRisk"]
	return []
