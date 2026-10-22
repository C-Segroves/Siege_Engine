class_name LootText
## The words of the loot window (LootWindow): a row's detail line, the detail plate (ItemTooltip data) and the
## weight / slot readouts of the container and of the kit. Pure functions of an item id and a count.


## "8.0 kg   worth 600 cr   stacks of 20".
static func make_detail(id: String, units: int) -> String:
	var text := "%.1f kg   worth %s" % [float(ExtractionItems.item(id).get("kg", 0.0)) * units,
		ExtractionRules.make_money_text(ExtractionItems.make_sell_price(id, units))]
	var per := make_stack_size(id)
	return text if per <= 1 else "%s   stacks of %d" % [text, per]


## Units that share one slot.
static func make_stack_size(id: String) -> int:
	return maxi(int(ExtractionItems.item(id).get("stack", 1)), 1)


## What one "take the stack" button moves: a full stack, or the whole row when it is smaller.
static func make_stack_units(id: String, units: int) -> int:
	return mini(units, make_stack_size(id))


## " - will not fit: Too heavy: ..." or " - room for 3" when `inv` cannot take all `units` of `id` ("" when it can).
static func make_fit_note(inv: ExtractionInventory, id: String, units: int) -> String:
	var room := inv.make_room_for(id, units)
	if room >= units:
		return ""
	if room <= 0:
		return "  -  will not fit: %s" % inv.make_refusal_for(id)
	return "  -  room for %d" % room


## The ItemTooltip data of an item row; `fit_note` is make_fit_note's answer for a container row.
static func make_tooltip(id: String, units: int, fit_reason := "") -> Dictionary:
	var rec := ExtractionItems.item(id)
	var lines := []
	if float(rec.get("kg", 0.0)) > 0.0:
		lines.append("%.2f kg each, %.1f kg together" % [float(rec.kg), float(rec.kg) * units])
	lines.append("worth %s" % ExtractionRules.make_money_text(ExtractionItems.make_sell_price(id, units)))
	if make_stack_size(id) > 1:
		lines.append("stacks of %d, one slot each stack" % make_stack_size(id))
	return {"title": ExtractionItems.make_stack_text(id, units), "subtitle": ExtractionItems.kind_of(id).capitalize(),
		"lines": lines, "price": "", "warning": fit_reason}


## "Supply cache" pane summary: "5 items   120 cr".
static func make_container_summary(c: LootContainer) -> String:
	var items := c.make_item_count()
	return "%d item%s   %s" % [items, "" if items == 1 else "s", ExtractionRules.make_money_text(c.money)]


## The kit pane summary: "30 cr   12.0 / 40 kg   4 / 10 slots" and the free room below.
static func make_kit_summary(inv: ExtractionInventory) -> String:
	return "%s   %.1f / %.0f kg   %d / %d slots\n%s" % [ExtractionRules.make_money_text(inv.money), inv.make_used_kg(),
		inv.max_kg, inv.make_used_slots(), inv.max_slots, inv.make_capacity_text()]
