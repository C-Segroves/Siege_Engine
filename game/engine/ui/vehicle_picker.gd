class_name VehiclePicker
extends OptionRow
## Labelled Herc chooser: every pilotable vehicle of the enabled packs, grouped under a heading
## per game. A vehicle that is not in that list (e.g. a mission's own Herc from a disabled pack)
## is added at the end when it is asked for. In a campaign, set_availability(ctx) limits the list to
## what the campaign offers (CampaignAvailability) and shows why ("older design", "equivalent to X").
##   vehicle_selected(id)      the player picked another vehicle
##   selected_id() -> String   current vehicle id ("" when no packs are installed)
##   select_vehicle(id)        picks `id` (emits vehicle_selected when it changes)
##   set_availability(ctx)     refills the list from a CampaignAvailability context
##   reason_of(id) -> String   why `id` is offered ("" outside a campaign)
##   make_native_default(ctx)  the campaign's own first offered vehicle (default choice)

signal vehicle_selected(vehicle_id: String)

var _options: OptionButton
var _reasons := {}               # vehicle id -> reason it is offered (campaigns only)
var _restricted := false         # a campaign list: vehicles outside it are never added


func _init(label_text := "Herc", selected := "") -> void:
	super(label_text)
	_options = Widgets.option_button([])
	set_control(_options)
	_fill(Packs.pilotable())
	if selected != "":
		_select_silently(selected)
	_options.item_selected.connect(func(_i: int) -> void: vehicle_selected.emit(selected_id()))


func selected_id() -> String:
	var i := _options.selected
	return str(_options.get_item_metadata(i)) if i >= 0 else ""


## Refills the list with the vehicles `ctx` offers (keeps the selection when still offered).
func set_availability(ctx: Dictionary) -> void:
	var keep := selected_id()
	_options.clear()
	_reasons.clear()
	_restricted = CampaignAvailability.is_restricted(ctx)
	var vehicles: Array = []
	for offer in CampaignAvailability.offered_vehicles(ctx):
		vehicles.append(offer.vehicle)
		if CampaignAvailability.is_restricted(ctx):
			_reasons[str(offer.vehicle.id)] = str(offer.reason)
	_fill(vehicles)
	if keep != "" and _index_of(keep) >= 0:
		_select_silently(keep)


## The campaign's own first offered vehicle (its native pack before older or carried designs);
## "" when `ctx` offers none of its own.
static func make_native_default(ctx: Dictionary) -> String:
	var native := str(ctx.get("native_pack", ""))
	for offer in CampaignAvailability.offered_vehicles(ctx):
		if str(offer.vehicle.get("pack", "")) == native:
			return str(offer.vehicle.id)
	return ""


func reason_of(vehicle_id: String) -> String:
	return str(_reasons.get(vehicle_id, ""))


func select_vehicle(vehicle_id: String) -> void:
	var before := selected_id()
	_select_silently(vehicle_id)
	if selected_id() != before:
		vehicle_selected.emit(selected_id())


## Caption for a vehicle: "Name  -  Game" (+ Cybrid).
static func make_caption(v: Dictionary) -> String:
	return "%s  -  %s%s" % [str(v.get("name", v.get("id", ""))), Packs.pack_name(str(v.get("pack", ""))), _side_suffix(v)]


static func _side_suffix(v: Dictionary) -> String:
	return "  (Cybrid)" if v.get("side", "herc") == "cybrid" else ""


func _fill(vehicles: Array) -> void:
	var pack := ""
	for v in vehicles:
		if v.pack != pack:
			pack = v.pack
			_options.add_separator(Packs.pack_name(pack))
		_add_vehicle(v)
	_select_first_vehicle()


func _add_vehicle(v: Dictionary) -> void:
	var reason := reason_of(str(v.id))
	_options.add_item("%s%s%s" % [v.name, _side_suffix(v), "  (%s)" % reason if reason != "" else ""])
	_options.set_item_metadata(_options.item_count - 1, v.id)


func _select_first_vehicle() -> void:
	for i in _options.item_count:
		if not _options.is_item_separator(i):
			_options.select(i)
			return


func _select_silently(vehicle_id: String) -> void:
	var want := Packs.vehicle(vehicle_id)
	if want.is_empty():
		return
	var i := _index_of(want.id)
	if i < 0 and _restricted:
		return
	if i < 0:
		_add_vehicle(want)
		i = _options.item_count - 1
	_options.select(i)


func _index_of(vehicle_id: String) -> int:
	for i in _options.item_count:
		if not _options.is_item_separator(i) and str(_options.get_item_metadata(i)) == vehicle_id:
			return i
	return -1
