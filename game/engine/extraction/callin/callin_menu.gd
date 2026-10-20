class_name CallinMenu
extends InventoryPanel
## The call-in menu (action callin_menu: L on the keyboard, LB + RB together on a pad; docs/design/lobby_loadout_economy.md section 9.3).
## A modal list on the raid panel layer (like the inventory): the raid points and, per call-in, its cost and either a Call in
## button or why it is not available now (cooldown, cap, raid points, the saved vehicle). Mouse, keyboard and
## gamepad all work: the focus moves with ui_up / ui_down, ui_accept calls, menu_back or callin_menu closes. The
## battle keeps running and the player's controls are held while it is open (PlayerHold, as the inventory).
## The Targeting Laser comes up with the menu; picking a row hands over to it (aim, fire to designate the spot).

const TITLE := "CALL-INS"
const SUMMARY := "%s   -   raid points carry over to the next raid (up to %d) and are lost if you die."

var _is_first_build := true


## Opens the menu, or closes it when it is open.
static func toggle(p_director: ExtractionDirector) -> void:
	if not close_open(p_director):
		open(p_director)


## Opens the menu; the Targeting Laser comes up with it (CallinDesignator), whatever opened it.
static func open(p_director: ExtractionDirector) -> CallinMenu:
	var menu := show_panel(p_director, CallinMenu.new()) as CallinMenu
	if menu != null and p_director.callins != null:
		p_director.callins.designator.apply_menu_opened()
	return menu


func _make_title() -> String:
	return TITLE


## What the menu shows: the balance, and the cooldowns by the second.
func _make_shown_key() -> String:
	var callins := director.callins
	return JSON.stringify([callins.points.mine, int(Time.get_ticks_msec() / 1000.0), callins.views.size(), callins.my_state.get("used", {})])


func _rebuild() -> void:
	var callins := director.callins
	_shown_key = _make_shown_key()
	_summary.text = SUMMARY % [callins.points.make_hud_text(), RaidPoints.make_cap()]
	for c in _rows.get_children():
		_rows.remove_child(c)
		c.queue_free()
	for offer in CallinRules.make_offers():
		_rows.add_child(_make_offer_row(callins, offer))
	_link_focus.call_deferred()
	_scroll_to_top.call_deferred()


## The first row is shown whole when the menu opens (the focus would otherwise scroll its title away).
func _scroll_to_top() -> void:
	await get_tree().process_frame
	var scroll := _rows.get_parent() as ScrollContainer if is_inside_tree() else null
	if scroll != null and _is_first_build:
		scroll.scroll_vertical = 0
		_is_first_build = false


func _make_offer_row(callins: CallinDirector, offer: Dictionary) -> ItemRow:
	var kind := str(offer.kind)
	var variant := str(offer.variant)
	var why := callins.make_local_refusal(kind, variant)
	var cost := CallinRules.make_cost(kind, variant, callins.make_vehicle_id(callins.multiplayer.get_unique_id()))
	var title := "%s   %s" % [offer.label, ("%d RP" % cost) if cost >= 0 else "-"]
	if kind == CallinRules.KIND_VEHICLE:
		title += "   (%s)" % _make_vehicle_name(callins)
	var detail := str(offer.text) if why == "" else "Not available: %s" % why
	var button := Widgets.small_button("Call in", func() -> void: _call_in(callins, kind, variant), Widgets.PRIMARY)
	button.disabled = why != ""
	return make_row(title, detail, [button])


static func _make_vehicle_name(callins: CallinDirector) -> String:
	var id := callins.make_vehicle_id(callins.multiplayer.get_unique_id())
	return str(Packs.vehicle(id).get("name", id)) if id != "" else "none saved"


## The pick goes on to the laser: aim at the spot and fire to designate it (CallinDesignator).
func _call_in(callins: CallinDirector, kind: String, variant: String) -> void:
	callins.begin_designation(kind, variant)
	close()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("callin_menu"):
		get_viewport().set_input_as_handled()
		close()
		return
	super._unhandled_input(event)
