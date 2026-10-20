class_name CommandMapCallins
extends RefCounted
## Ordering a call-in on the command map (docs/design/lobby_loadout_economy.md section 9.3; CommandMap owns one in an
## extraction raid). Pick a call-in in the side list, click the point on the map and, for a kind that flies a line (a bombing
## run), click the direction too; it becomes a CallinRequest with source "map" that goes to the host like a laser designation,
## with the same validation (CallinChecks.make_plan: raid points, cooldowns, caps, the spot itself), costs and cooldowns.
## The spot under the cursor is judged live: a green ring when the call-in can land there, a red one with the reason in the
## status line. Right click, menu_back or picking the same call-in again cancels the order (a second menu_back closes the map).

enum Step { NONE, POINT, DIRECTION }

const REFRESH_SECONDS := 0.1
## An unmoved cursor is judged again after this long (the raid points and the cooldowns change), not every step.
const REJUDGE_MSEC := 500
const MOVED_M := 0.5
const GREEN := CallinLaserLook.VALID_COLOR
const RED := CallinLaserLook.INVALID_COLOR
const ZONE_COLOR := Color(1.0, 0.7, 0.2)
const RING_MIN_PX := 5.0
const ARROW_HEAD_PX := 9.0
const LABEL_SIZE := 13
const TEXT_PICK := "Pick a call-in to order on the map."
const TEXT_POINT := "%s: click the point on the map (right click or back cancels)."
const TEXT_DIRECTION := "%s: click the direction (click close to the point = the way you face)."

var map: CommandMap
var callins: CallinDirector
var step := Step.NONE
var kind := ""
var variant := ""
var first_point := Vector3.ZERO
## The spot under the cursor and the verdict on it: {ok, pos, reason}.
var point := Vector3.ZERO
var verdict := {"ok": false, "pos": Vector3.ZERO, "reason": ""}
## The request sent last (tests read it).
var last_request: CallinRequest
var _box: VBoxContainer
var _judged_msec := 0
var _shown_key := ""
var _age := 0.0


## The call-in director of the raid `battle` is part of (null when it is not an extraction raid).
static func find_callins(battle: Node) -> CallinDirector:
	var raid = battle.get("extraction")
	return raid.callins if raid is ExtractionDirector and (raid as ExtractionDirector).callins != null else null


static func make_for(p_map: CommandMap) -> CommandMapCallins:
	var director := find_callins(p_map.battle)
	if director == null:
		return null
	var c := CommandMapCallins.new()
	c.map = p_map
	c.callins = director
	return c


func is_ordering() -> bool:
	return step != Step.NONE


# ------------------------------------------------------------------ the side list

## The "Call-ins" section of the command map's side panel.
func build_panel(side: VBoxContainer) -> void:
	side.add_child(Widgets.section("Call-ins"))
	_box = VBoxContainer.new()
	side.add_child(_box)
	apply_refresh(true)


## The list follows the raid points and the cooldowns (about four times a second, rebuilt when they changed).
func apply_frame(delta: float) -> void:
	_age += delta
	if _age < REFRESH_SECONDS:
		return
	_age = 0.0
	apply_refresh(false)
	if step != Step.NONE:
		var at := map.view.to_world(map.view.cursor)
		if at.distance_to(point) > MOVED_M or Time.get_ticks_msec() - _judged_msec > REJUDGE_MSEC:
			_judge(at)
			map.set_status(make_status())


func apply_refresh(force: bool) -> void:
	if _box == null:
		return
	var key := JSON.stringify([callins.points.mine, int(Time.get_ticks_msec() / 1000.0), callins.views.size(), kind, variant, step])
	if key == _shown_key and not force:
		return
	_shown_key = key
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	for offer in CallinRules.make_offers():
		_box.add_child(_make_offer_button(offer))


func _make_offer_button(offer: Dictionary) -> Button:
	var o_kind := str(offer.kind)
	var o_variant := str(offer.variant)
	var cost := CallinRules.make_cost(o_kind, o_variant, callins.make_vehicle_id(callins.multiplayer.get_unique_id()))
	var why := callins.make_local_refusal(o_kind, o_variant)
	var chosen := step != Step.NONE and o_kind == kind and o_variant == variant
	var text := "%s   %s" % [offer.label, ("%d RP" % cost) if cost >= 0 else "-"]
	var button := Widgets.small_button(text if not chosen else "> " + text, func() -> void: begin(o_kind, o_variant), Widgets.PRIMARY)
	button.disabled = why != "" and not chosen
	button.tooltip_text = why if why != "" else str(offer.text)
	return button


# ------------------------------------------------------------------ ordering

## A call-in was picked: the next click on the map is its point. Picking the same one again cancels.
func begin(p_kind: String, p_variant: String) -> void:
	if step != Step.NONE and p_kind == kind and p_variant == variant:
		apply_cancel()
		return
	kind = p_kind
	variant = p_variant
	step = Step.POINT
	_judge(map.view.to_world(map.view.cursor))
	apply_refresh(true)
	map.set_status(make_status())


## Cancels the order in progress; false when there was none (the map then closes).
func apply_cancel() -> bool:
	if step == Step.NONE:
		return false
	step = Step.NONE
	kind = ""
	variant = ""
	apply_refresh(true)
	map.set_status(TEXT_PICK)
	return true


## A click on the map at world `at`: the point (a red verdict only says why), then the direction of a directional kind.
func apply_click(at: Vector3) -> void:
	if step == Step.NONE:
		return
	_judge(at)
	if step == Step.POINT:
		if not bool(verdict.ok):
			map.set_status(make_status())
			return
		if CallinPlacement.is_directional(kind):
			first_point = point
			step = Step.DIRECTION
			map.set_status(make_status())
			return
		_submit(point, Vector3.ZERO)
	else:
		_submit(first_point, CallinRequest.make_direction_between(first_point, at))


func _submit(at: Vector3, direction: Vector3) -> void:
	last_request = CallinRequest.make(kind, variant, callins.multiplayer.get_unique_id(), at, direction, CallinRequest.SOURCE_MAP)
	var label := CallinRules.make_label(kind)
	var request := last_request
	apply_cancel()
	callins.request_designated(request)
	map.set_status("%s ordered." % label)


## The verdict on world point `at` for the call-in being ordered (the direction click is not judged).
func _judge(at: Vector3) -> void:
	point = at
	_judged_msec = Time.get_ticks_msec()
	if step == Step.DIRECTION:
		verdict = {"ok": true, "pos": at, "reason": ""}
		return
	var request := CallinRequest.make(kind, variant, callins.multiplayer.get_unique_id(), at, Vector3.ZERO, CallinRequest.SOURCE_MAP)
	verdict = callins.checks.make_plan(request, true)
	if bool(verdict.ok):
		point = verdict.pos


func make_status() -> String:
	var label := CallinRules.make_label(kind)
	match step:
		Step.POINT:
			return (TEXT_POINT % label) + ("  OK" if bool(verdict.ok) else "  NO: " + str(verdict.reason))
		Step.DIRECTION:
			return TEXT_DIRECTION % label
	return TEXT_PICK


# ------------------------------------------------------------------ drawing

## Over the map: the ring of the spot under the cursor in the verdict's colour, the line of a directional order, and the
## zones of the caller's call-ins on their way.
func draw(view: CommandMapView) -> void:
	for m in callins.make_markers():
		UnitSymbols.draw_labeled_marker(view, view.to_map(m.pos), str(m.label), ZONE_COLOR, ThemeDB.fallback_font, 13)
	if step == Step.NONE:
		return
	var color := GREEN if bool(verdict.ok) else RED
	var from_world := first_point if step == Step.DIRECTION else point
	var centre := view.to_map(from_world)
	var radius := maxf(CallinChecks.make_footprint(kind, callins.make_vehicle_id(callins.multiplayer.get_unique_id())) \
		* view.size.x / maxf(view.area.size.x, 1.0), RING_MIN_PX)
	view.draw_arc(centre, radius, 0.0, TAU, 24, color, 2.0)
	view.draw_circle(centre, 2.0, color)
	if step == Step.DIRECTION:
		_draw_arrow(view, centre, view.cursor, color)
	elif not bool(verdict.ok):
		view.draw_string(ThemeDB.fallback_font, centre + Vector2(radius + 4.0, 4.0), str(verdict.reason), HORIZONTAL_ALIGNMENT_LEFT, 260, LABEL_SIZE, color)


static func _draw_arrow(view: CommandMapView, from: Vector2, to: Vector2, color: Color) -> void:
	view.draw_line(from, to, color, 2.0)
	var along := (to - from).normalized()
	if along.is_zero_approx():
		return
	var side := along.orthogonal()
	view.draw_colored_polygon(PackedVector2Array([to, to - along * ARROW_HEAD_PX + side * ARROW_HEAD_PX * 0.5,
		to - along * ARROW_HEAD_PX - side * ARROW_HEAD_PX * 0.5]), color)
