class_name RifleScope
extends RefCounted
## The Laser Rifle's zoom scope (Tribes 1 and Tribes 2 sniper rifle), the local player's state on his soldier.
## Zoom levels, from the originals' scripts:
##   * Tribes 1: IDACTION_SNIPER_FOV (default key E, held) zooms, IDACTION_INC_SNIPER_FOV (Z) steps the
##     magnification; Training_Weapons.cs: "two, five, ten or even twenty times normal vision"; $pref::PlayerFov = 90.
##   * Tribes 2: scripts/controlDefaults.cs toggleZoom (A, held) sets $pref::player::currentFOV, setZoomFOV (T) steps it;
##     hud.cs calcZoomFOV: 90/2 = 45, then 90/5 = 18, then halved: 9, 4.5, below 4 back to 45 degrees. Those FOVs are
##     exactly 2x, 5x, 10x and 20x of the default 90, the same four levels as Tribes 1.
## Stepping the level while not zoomed shows the T2 ZoomHud: a box the size of the zoomed view
## (getZoomExtent: screen / (power * 1.25)), for 5 s (hud.cs: schedule(5000, 0, hideZoomHud)); its profile (guiProfiles.cs
## ZoomHudProfile) is a "40 205 170" border over a "0 64 100 80" fill.
## The reach is the rifle's maxRifleRange (sniperRifle.cs: 1000 m). While zoomed the scope wakes the AI units in the view
## (BotSleep / SiteSpawner wake_area) so units beyond the sleep range act while the player watches them.
## Not from the originals: the sniper crosshair bitmap is compiled into the exe (IDCTG_HUD_SNIPER_CROSS), so the reticle
## is drawn (InfantryHud); the zoomed look is slowed in step with the field of view.

const WEAPON_NAME := "LASER_RIFLE"
const DEFAULT_FOV_ACROSS_DEG := 90.0
const MAGNIFICATIONS := [2.0, 5.0, 10.0, 20.0]
const REACH_M := 1000.0
const PREVIEW_SECONDS := 5.0
const PREVIEW_PAD := 1.25
const PREVIEW_BORDER := Color8(40, 205, 170)
const PREVIEW_FILL := Color8(0, 64, 100, 80)
## The view is searched this often (s) and the units found stay awake for WAKE_HOLD_S.
const WAKE_INTERVAL_S := 0.25
const WAKE_HOLD_S := 1.0
## Wake circles: radius = distance * tan(half view) * WAKE_SPREAD + WAKE_MARGIN_M, the next centre one radius * STEP on.
const WAKE_SPREAD := 1.3
const WAKE_MARGIN_M := 20.0
const WAKE_STEP := 0.9
## Past the first thing the view ray hits the cone goes on this far (a unit in front of a unit).
const WAKE_PAST_HIT_M := 60.0

var level := 0
var zoomed := false
## Seconds left of the ZoomHud preview box.
var preview_left := 0.0
var wake_calls := 0
var _wake_t := 0.0


static func is_scope_weapon(w: Weapon) -> bool:
	return w != null and w.weapon_name == WEAPON_NAME


func magnification() -> float:
	return float(MAGNIFICATIONS[level])


## Horizontal field of view across the 4:3 screen (degrees): 90 unzoomed, 90 / magnification zoomed.
func make_fov_across_deg() -> float:
	return DEFAULT_FOV_ACROSS_DEG / magnification() if zoomed else DEFAULT_FOV_ACROSS_DEG


## The camera's vertical field of view (degrees; BattleCameras keeps the 4:3 screen shape on any window).
func make_vertical_fov_deg() -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(make_fov_across_deg()) * 0.5) / BattleCameras.DARKSTAR_SCREEN_ASPECT))


## Mouse / stick look scale: the zoomed view turns slower in step with its field of view.
func make_look_scale() -> float:
	return 1.0 / magnification() if zoomed else 1.0


## The next magnification (after the last, the first); while not zoomed it shows the ZoomHud preview box.
func cycle_level() -> void:
	level = (level + 1) % MAGNIFICATIONS.size()
	if not zoomed:
		preview_left = PREVIEW_SECONDS


## One frame of `soldier`'s scope; `want_zoom` is the zoom key held. Returns true when zoomed.
func apply_frame(soldier: Infantry, want_zoom: bool, delta: float) -> bool:
	var can := soldier.alive and not soldier.stowed and is_scope_weapon(soldier.current_weapon())
	zoomed = want_zoom and can
	preview_left = 0.0 if zoomed else maxf(preview_left - delta, 0.0)
	if not zoomed:
		_wake_t = 0.0
		return false
	_wake_t -= delta
	if _wake_t <= 0.0:
		_wake_t = WAKE_INTERVAL_S
		apply_wake(soldier)
	return true


## Wakes the AI units in the view cone up to the reach (or just past the first thing the view hits).
func apply_wake(soldier: Infantry) -> int:
	var battle := soldier.get_parent()
	if battle == null or not battle.multiplayer.is_server():
		return 0   # the sleep rule runs on the host only
	var origin := soldier.aim_origin()
	var dir := -soldier.aim_basis().z
	var reach := REACH_M
	var q := PhysicsRayQueryParameters3D.create(origin, origin + dir * REACH_M, 0xFFFFFFFF, [soldier.get_rid()])
	var hit := soldier.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.is_empty():
		reach = minf(REACH_M, origin.distance_to(hit.position) + WAKE_PAST_HIT_M)
	var half := deg_to_rad(make_fov_across_deg()) * 0.5
	var half_diagonal := atan(tan(half) * sqrt(1.0 + 1.0 / pow(BattleCameras.DARKSTAR_SCREEN_ASPECT, 2.0)))
	var woke := 0
	for c in make_wake_circles(origin, dir, reach, half_diagonal):
		woke += _wake(battle, c[0], c[1])
		wake_calls += 1
	return woke


static func _wake(battle: Node, center: Vector3, radius: float) -> int:
	var raid = battle.get("extraction")
	if raid != null and raid.site_spawner != null:
		return raid.site_spawner.wake_area(center, radius, WAKE_HOLD_S)
	var sleeper = battle.get("bot_sleep")
	return sleeper.wake_area(center, radius, WAKE_HOLD_S) if sleeper != null else 0


## Circles [centre, radius] along the view ray that together cover the cone (half angle `half_view` rad) up to `reach`.
static func make_wake_circles(origin: Vector3, dir: Vector3, reach: float, half_view: float) -> Array:
	var out := []
	var t := tan(half_view)
	var d := 0.0
	while true:
		var r := d * t * WAKE_SPREAD + WAKE_MARGIN_M
		out.append([origin + dir * d, r])
		if d >= reach:
			break
		d = minf(d + r * WAKE_STEP, reach)
	return out


## The ZoomHud preview box on a screen of size `s` (T2 getZoomCenter / getZoomExtent), centred.
func make_preview_rect(s: Vector2) -> Rect2:
	if preview_left <= 0.0 or zoomed:
		return Rect2()
	var power := magnification() * PREVIEW_PAD
	var extent := (s / power).floor()
	return Rect2(((s - extent) * 0.5).floor(), extent)
