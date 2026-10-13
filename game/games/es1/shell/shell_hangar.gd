class_name ShellHangar
extends RefCounted
## The career's hangar in the original shell. The hub screens (1700 / 1710) show the garage's selected
## Herc standing in the 3D hangar under the menus, with its name plate. ARMING, REPAIR and BUILD
## open the app's Hangar screen (HangarScreen, the same one every campaign uses) over the shell, on the
## career's garage (its Campaign, career.campaign_state); CREW opens it on its Crew tab. Every change
## is saved with the career.

const HUB_MENUS := [EsShell.HANGAR_HUB, EsShell.HANGAR_HUB_DEBRIEFED]
## Hub buttons that open the Hangar screen: ARMING (1700), REPAIR and BUILD (1710).
const HANGAR_COMMANDS := [1800, 1900, 2000]
## Hub button that opens it on the Crew tab: CREW (1700, the original's crew screen 1610).
const CREW_COMMAND := 1610
## Where the Herc's centre sits in the 3D hangar (screen fractions) above the hub's button bar.
const BAY_FRAME_HUB := Vector2(0.5, 0.46)
const BAY_FRAME_FILL := 0.72
const PLATE_MARGIN := 6
const MOUSE_ORBIT := Vector2(0.008, 0.006)   # radians per mouse pixel (yaw, pitch)

var shell: EsShell
var view: HangarView                # 3D hangar under the hub screens (pixelated, 320x200)
var _router: HangarRouter           # the open Hangar screen (null when closed)
var _campaign: Campaign
var _campaign_career: Dictionary


func _init(p_shell: EsShell) -> void:
	shell = p_shell


## The current career's campaign (cached while the same career is loaded).
func career_campaign() -> Campaign:
	if _campaign == null or not is_same(_campaign_career, EsShell.career):
		_campaign_career = EsShell.career
		_campaign = MissionLaunch.campaign_for(EsShell.career)
	return _campaign


## The garage's selected Herc ({} without a career).
func selected_entry() -> Dictionary:
	return career_campaign().garage.selected_entry() if not EsShell.career.is_empty() else {}


func is_open() -> bool:
	return _router != null


# ------------------------------------------------------------------ the Hangar screen

## Opens the Hangar screen over the shell on the career's garage, on `tab` ("hercs" / "crew").
func open_hangar(tab := HangarScreen.TAB_HERCS) -> void:
	if is_open() or EsShell.career.is_empty():
		return
	var campaign := career_campaign()
	_router = HangarRouter.new()
	shell.add_child(_router)
	_router.go("hangar", {"garage": campaign.garage, "availability": campaign.availability_context,
		"wingman_slots": campaign.wingman_slots({}), "tab": tab, "player_name": str(EsShell.career.get("name", "")),
		"heading": "Career of %s  -  campaign %d" % [EsShell.career.get("name", ""), int(EsShell.career.get("campaign", 0)) + 1],
		"done_text": "Back to the service bay", "on_done": close_hangar, "on_changed": _save_career})


func close_hangar() -> void:
	if not is_open():
		return
	_save_career()
	_router.queue_free()
	_router = null
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	shell.refresh(shell.top())


func _save_career() -> void:
	EsShell.career["campaign_state"] = career_campaign().to_dict()
	shell.careers.save(EsShell.career)


# ------------------------------------------------------------------ the hub bay

## Draws the selected Herc in the 3D hangar behind the hub screens (hidden elsewhere) plus its plate.
func draw_bay() -> void:
	var base := shell.base_menu()
	var active := not shell.busy and shell.scene == null and base != null and base.id in HUB_MENUS and not is_open()
	var e := selected_entry() if active else {}
	if e.is_empty():
		if view:
			view.visible = false
		return
	_ensure_view()
	shell.screen.image.fill(Color(0, 0, 0, 0))
	view.visible = true
	view.show_herc(str(e.vehicle), e.loadout)
	_draw_plate(base, make_plate_lines(e))


func _ensure_view() -> void:
	if view != null:
		return
	view = HangarView.new()
	view.interactive = false
	view.pixel_height = ShellScreen.H
	view.pixelated = true
	shell.screen.set_underlay(view)
	view.bay.frame_fill = BAY_FRAME_FILL
	view.set_frame_center(BAY_FRAME_HUB)


## Turns the 3D bay by a mouse drag (pixels) while it is shown.
func apply_mouse_orbit(relative: Vector2) -> void:
	if view and view.visible:
		view.bay.orbit(-relative.x * MOUSE_ORBIT.x, relative.y * MOUSE_ORBIT.y)


## Turns the 3D bay by the right stick (orbit_* actions) while it is shown.
func apply_stick_orbit(delta: float) -> void:
	var stick := SiegeInput.make_stick_orbit(delta)
	if view and view.visible and stick != Vector2.ZERO:
		view.bay.orbit(-stick.x, stick.y)


static func make_plate_lines(e: Dictionary) -> Array[String]:
	var v := Packs.vehicle(str(e.get("vehicle", "")))
	var lines: Array[String] = ["HERC: %s" % str(e.get("name", "")).to_upper(),
		"PILOT: %s" % str(EsShell.career.get("name", "")).to_upper(),
		"WEAPONS: %d OF %d" % [Garage.make_armed_count(e), (e.get("loadout", []) as Array).size()],
		"CONDITION: %d%%" % HercCondition.make_percent(str(e.get("vehicle", "")), e.get("condition", []))]
	var pack := str(v.get("pack", "es1"))
	if pack != "es1":
		lines.insert(1, Packs.pack_name(pack).to_upper())
	return lines


func _draw_plate(m: ShellMenu, lines: Array) -> void:
	var f := ShellData.font("NM_GREEN")
	var w := 0
	for l in lines:
		w = maxi(w, f.width(l))
	var r := Rect2i(PLATE_MARGIN, PLATE_MARGIN, w + 10, lines.size() * (f.height + 1) + 5)
	m.draw_box(shell.screen.image, r, ShellMenu.STYLE_FIELD)
	var y := r.position.y + 3
	for l in lines:
		f.draw(shell.screen.image, r.position.x + 5, y, l)
		y += f.height + 1
