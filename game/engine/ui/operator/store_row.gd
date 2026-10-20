class_name StoreRow
extends RowButton
## One entry of the store: name, game, weight, and its state (free, owned, a price, buy back, not allowed, does not fit).
## The row's `entry` is a StoreCatalog entry; the panel connects `pressed` to equipping it.

const DIMMED := Color(1, 1, 1, 0.6)
const PACK_WIDTH := 110
const KG_WIDTH := 64
const STATE_WIDTH := 130

var entry := {}
var fit_reason := ""


## A row for `p_entry`; `p_fit_reason` ("" = fits the open slot) marks it "does not fit".
static func make(p_entry: Dictionary, p_fit_reason: String) -> StoreRow:
	var r := StoreRow.new()
	r.entry = p_entry
	r.fit_reason = p_fit_reason
	r.build_content()
	return r


func build_content() -> void:
	add_text(str(entry.name), "", true)
	var pack := str(entry.pack)
	add_text(Packs.pack_name(pack) if pack != "" else "", "DimLabel", false, PACK_WIDTH).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	add_text("%.1f kg" % float(entry.kg) if float(entry.kg) > 0.0 else "", "DimLabel", false, KG_WIDTH)
	_add_state()
	if str(entry.state) == StoreCatalog.STATE_NOT_ALLOWED:
		modulate = DIMMED


func _add_state() -> void:
	if str(entry.state) == StoreCatalog.STATE_NOT_ALLOWED:
		add_text("NOT ALLOWED", "BadgeNotAllowed")
	elif fit_reason != "":
		add_text("DOES NOT FIT", "BadgeNotAllowed")
	elif str(entry.state) == StoreCatalog.STATE_LOST:
		add_text(OperatorText.make_price_text(entry), "BadgeLost")
	else:
		var text := OperatorText.make_price_text(entry)
		var variation := "StatusLabel" if str(entry.state) == StoreCatalog.STATE_FOR_SALE else "DimLabel"
		add_text(text, variation, false, STATE_WIDTH if text != "" else 0).horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
