class_name StationShopPanel
extends InventoryPanel
## The supply panel of an inventory station in a raid (ExtractionStation; playtest X2): the credits carried and in
## the account, "Reload from your pack", and what the station sells this soldier (ammunition for his weapons, his
## armour's hand items and weapons) with a Buy button each. Same layer, focus chain and closing as the inventory
## panel; stepping off the station closes it.

const CLOSE_CHECK_SECONDS := 0.5

var _check_t := 0.0
## The account balance, read from the profile every CLOSE_CHECK_SECONDS (a purchase charges it on this machine).
var _account := 0


static func open(p_director: ExtractionDirector) -> InventoryPanel:
	return show_panel(p_director, StationShopPanel.new())


func _ready() -> void:
	_account = ExtractionProfile.load_for(Net.player_name).money
	_check_t = CLOSE_CHECK_SECONDS
	super._ready()


func _make_title() -> String:
	return "SUPPLY STATION"


func _process(delta: float) -> void:
	super._process(delta)
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = CLOSE_CHECK_SECONDS
		_account = ExtractionProfile.load_for(Net.player_name).money
		if not director.station.is_at_station(director.battle.player as Infantry):
			close()


func _make_shown_key() -> String:
	return super._make_shown_key() + str(_account)


func _rebuild() -> void:
	_shown_key = _make_shown_key()
	var account := _account
	_summary.text = "Carried %s   account %s" % [ExtractionRules.make_money_text(director.my_inventory.money),
		ExtractionRules.make_money_text(account)]
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	_rows.add_child(make_row("Reload from your pack", "loads your weapons and kit from the ammunition you carry",
		[Widgets.small_button("Reload", director.station.request_reload, Widgets.PRIMARY)]))
	var soldier := director.battle.player as Infantry
	for r in (ExtractionStation.make_offers(soldier) if soldier else []):
		_rows.add_child(_make_offer_row(r, director.my_inventory.money + account))
	_link_focus.call_deferred()


func _make_offer_row(r: Dictionary, can_spend: int) -> ItemRow:
	var id := str(r.id)
	var price := ExtractionShop.make_buy_price(id)
	var buy := Widgets.small_button("Buy  %s" % ExtractionRules.make_money_text(price), func() -> void: director.station.request_buy(id))
	buy.disabled = price > can_spend
	var units := ExtractionShop.make_buy_units(id)
	return make_row(ExtractionItems.make_stack_text(id, units), "%.1f kg" % (float(r.kg) * units), [buy])
