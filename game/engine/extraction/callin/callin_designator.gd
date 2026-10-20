class_name CallinDesignator
extends RefCounted
## The local player's call-in designation with the Targeting Laser (docs/design/lobby_loadout_economy.md section 9.3). Whatever
## opens a call-in (the menu key, the pad chord) first raises the laser; then:
##   PICKING    the call-in menu is open and the laser is up (CallinMenu); picking a row goes on to
##   AIMING     the laser paints where he looks, with the verdict live on the spot (green, or red with the reason: out of
##              range, inside a building, too steep, no sky, no approach); fire designates a green spot
##   DIRECTING  a kind that flies a line (a bombing run) takes a second click for the line; a click close to the first
##              leaves it to the way the caller faces
## menu_back, the alt-fire (jet) or the menu key again cancels. The designation becomes a CallinRequest (source "laser") that
## the host judges again. The weapon in hand does not fire while the laser is raised. Teammates see the dot (CallinLaserSync).

enum Phase { IDLE, PICKING, AIMING, DIRECTING }

const RAISED_META := "callin_laser_raised"
const FIRE_ACTION := "fire_group_1"
const CANCEL_ACTIONS := ["fire_group_2", "jet", "callin_menu"]
## The line the laser looks along reaches a little past its range, so a spot out of range is painted red, not lost.
const REACH_SHARE := 1.15
const VERDICT_SECONDS := 0.1
## The verdict of an unmoved spot is judged again after this long (the raid points and the cooldowns change), not every step.
const REJUDGE_MSEC := 500
const MOVED_M := 0.05
const TEXT_PICK := "Choose a call-in"
const TEXT_CLEAR := "Clear"
const TEXT_DIRECTION := "Fire: set the line (close to the first spot = the way you face)"

var callins: CallinDirector
var laser: CallinLaser
var phase := Phase.IDLE
var kind := ""
var variant := ""
## The last verdict: {ok, pos, reason} for the spot painted now, and the spot itself.
var verdict := {"ok": false, "pos": Vector3.ZERO, "reason": ""}
var aim := {"hit": false, "point": Vector3.ZERO, "normal": Vector3.UP, "distance": 0.0}
## The first click of a directional kind.
var first_point := Vector3.ZERO
## The request sent last (tests read it).
var last_request: CallinRequest
## Tests: answers the aim ({hit, point, normal, distance}) instead of the soldier's line of sight.
var aim_override := Callable()
var _verdict_clock := MissionClock.new()
var _judged_point := Vector3.INF
var _judged_phase := Phase.IDLE
var _judged_msec := 0


func _init(p_callins: CallinDirector) -> void:
	callins = p_callins


## The laser node is made when the battle is there (CallinDirector._ready).
func apply_setup() -> void:
	if ServerProfile.is_collision_only():
		return
	laser = CallinLaser.new()
	callins.battle.add_child(laser)


static func is_raised(soldier: Node) -> bool:
	return soldier != null and soldier.has_meta(RAISED_META)


func is_active() -> bool:
	return phase != Phase.IDLE


func is_designating() -> bool:
	return phase == Phase.AIMING or phase == Phase.DIRECTING


# ------------------------------------------------------------------ opening and closing

## The menu opened: the laser comes up.
func apply_menu_opened() -> void:
	if _make_soldier() == null:
		return
	phase = Phase.PICKING
	kind = ""
	variant = ""
	_raise()


## A row of the menu was picked: aim for it.
func begin(p_kind: String, p_variant: String) -> bool:
	var soldier := _make_soldier()
	if soldier == null:
		callins.director.notify(callins.multiplayer.get_unique_id(), CallinSafety.REASON_ON_FOOT)
		apply_lower()
		return false
	kind = p_kind
	variant = p_variant
	phase = Phase.AIMING
	_raise()
	apply_frame(1.0)
	return true


func apply_cancel() -> void:
	if phase != Phase.IDLE:
		CallinLaserLook.play(CallinLaserLook.SOUND_CANCEL)
	apply_lower()


## The laser goes down (the weapon stays blocked until fire is released: apply_frame).
func apply_lower() -> void:
	if phase != Phase.IDLE and callins.laser_sync != null:
		callins.laser_sync.send_paint(false, Vector3.ZERO, false)
	phase = Phase.IDLE
	kind = ""
	if laser != null:
		laser.apply_lower()


func _raise() -> void:
	var soldier := _make_soldier()
	if soldier != null:
		soldier.set_meta(RAISED_META, true)
	if laser != null and not laser.is_raised():
		laser.apply_raise()


# ------------------------------------------------------------------ every frame

## One frame: the laser follows his look, the verdict is judged (about 12 times a second), the team is told.
func apply_frame(delta: float) -> void:
	var soldier := _make_soldier()
	if phase == Phase.IDLE:
		_release_weapon(callins.battle.player)
		return
	if soldier == null or not callins.may_open_menu() or (phase == Phase.PICKING and not _is_menu_open()):
		apply_lower()
		return
	aim = aim_override.call() if aim_override.is_valid() else _make_aim(soldier)
	if (_verdict_clock.make_step(delta, VERDICT_SECONDS) > 0.0 and _is_judgement_due()) or delta >= 1.0:
		verdict = _make_verdict()
		_judged_point = aim.point
		_judged_phase = phase
		_judged_msec = Time.get_ticks_msec()
	_show(soldier)
	if callins.laser_sync.is_send_due(delta):
		var shown: Vector3 = first_point if phase == Phase.DIRECTING else aim.point
		callins.laser_sync.send_paint(true, shown, bool(verdict.ok))


## True when the spot moved, the phase changed or the last verdict is old.
func _is_judgement_due() -> bool:
	var moved := (aim.point as Vector3).distance_to(_judged_point) > MOVED_M
	return moved or phase != _judged_phase or Time.get_ticks_msec() - _judged_msec > REJUDGE_MSEC


## The line of sight of `soldier` to the first thing it meets within the laser's reach.
func _make_aim(soldier: Infantry) -> Dictionary:
	return CallinAim.make_point(callins.battle, soldier.aim_origin(), -soldier.aim_basis().z, CallinPlacement.make_range() * REACH_SHARE)


## The verdict on the spot painted now.
func _make_verdict() -> Dictionary:
	if phase == Phase.PICKING:
		return {"ok": true, "pos": aim.point, "reason": TEXT_PICK}
	if phase == Phase.DIRECTING:
		return {"ok": true, "pos": aim.point, "reason": TEXT_DIRECTION}
	if not bool(aim.hit):
		return {"ok": false, "pos": aim.point, "reason": CallinPlacement.REASON_NO_POINT}
	if (aim.normal as Vector3).y < CallinSafety.WALKABLE_NORMAL_Y:
		return {"ok": false, "pos": aim.point, "reason": CallinPlacement.REASON_CANNOT % CallinSafety.REASON_STEEP}
	return callins.checks.make_plan(_make_request(aim.point, Vector3.ZERO), true)


func _show(soldier: Infantry) -> void:
	if laser == null:
		return
	var ok := bool(verdict.ok)
	var text := str(verdict.reason) if str(verdict.reason) != "" else TEXT_CLEAR
	var footprint := 0.0
	if phase == Phase.AIMING:
		footprint = CallinChecks.make_footprint(kind, callins.make_vehicle_id(callins.multiplayer.get_unique_id()))
	laser.apply_paint(soldier, aim.point, ok, text, footprint)
	if phase == Phase.DIRECTING:
		laser.apply_arrow(first_point, CallinRequest.make_direction_between(first_point, aim.point), true)
	else:
		laser.hide_arrow()


## Lets go of the weapon block once fire is up again (a held fire button would shoot the instant the laser goes down).
func _release_weapon(player: Node) -> void:
	if is_raised(player) and not Input.is_action_pressed(FIRE_ACTION):
		player.remove_meta(RAISED_META)


# ------------------------------------------------------------------ the buttons

## True when `event` was a designation button (fire, cancel); the director then swallows it.
func apply_input(event: InputEvent) -> bool:
	if not is_designating() or (event is InputEventKey and (event as InputEventKey).echo):
		return false
	if event.is_action_pressed(FIRE_ACTION):
		apply_confirm()
		return true
	if UiActions.is_back(event) or CANCEL_ACTIONS.any(func(a: String) -> bool: return InputMap.has_action(a) and event.is_action_pressed(a)):
		apply_cancel()
		return true
	return false


## Fire: designates the spot when it is green; the second click of a directional kind sets the line.
func apply_confirm() -> void:
	if not is_designating():
		return
	if phase == Phase.DIRECTING:
		_submit(first_point, CallinRequest.make_direction_between(first_point, aim.point))
		return
	if not bool(verdict.ok):
		CallinLaserLook.play(CallinLaserLook.SOUND_CANCEL)
		callins.director.notify(callins.multiplayer.get_unique_id(), str(verdict.reason))
		return
	if CallinPlacement.is_directional(kind):
		first_point = aim.point
		phase = Phase.DIRECTING
		CallinLaserLook.play(CallinLaserLook.SOUND_CONFIRM)
		return
	_submit(aim.point, Vector3.ZERO)


func _submit(point: Vector3, direction: Vector3) -> void:
	last_request = _make_request(point, direction)
	CallinLaserLook.play(CallinLaserLook.SOUND_CONFIRM)
	var request := last_request
	apply_lower()
	callins.request_designated(request)


func _make_request(point: Vector3, direction: Vector3) -> CallinRequest:
	return CallinRequest.make(kind, variant, callins.multiplayer.get_unique_id(), point, direction, CallinRequest.SOURCE_LASER)


# ------------------------------------------------------------------ the HUD

## The designation lines of the raid HUD: what is being designated and the verdict.
func make_hud_lines() -> Array:
	if not is_designating():
		return []
	var verb := "set the line" if phase == Phase.DIRECTING else "designate"
	return ["%s: LASER - fire to %s, back or alt-fire to cancel" % [CallinRules.make_label(kind).to_upper(), verb],
		("OK" if bool(verdict.ok) else "NO") + ": " + str(verdict.reason)]


func _make_soldier() -> Infantry:
	var player := callins.battle.player as Infantry
	return player if player != null and player.alive and not player.stowed else null


func _is_menu_open() -> bool:
	return InventoryPanel.find_open(callins.director) is CallinMenu
