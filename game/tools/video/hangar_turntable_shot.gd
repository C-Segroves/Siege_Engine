class_name HangarTurntableShot
extends Control
## Trailer shot: the 3D hangar (HangarView) showing Hercs from different games in turn, each with
## weapons from the other games, while the camera orbits slowly and eases in.

const SETTLE_SECONDS := 1.0
const PITCH_START := deg_to_rad(4.0)
const PITCH_END := deg_to_rad(14.0)
const ZOOM_START := 0.92
const ZOOM_END := 1.08
const ARC_YAW := 0.45               # each Herc gets a sweep of +-ARC_YAW round its front
const PORTRAIT_CROP := 0.9          # tall frames: weapons may reach a little past the edges

var spec: Dictionary
var _view: HangarView
var _clock := 0.0
var _shown := -1
var _playing := false


func _ready() -> void:
	size = get_viewport_rect().size   # the parent is a plain Node: anchors alone give no size
	_view = HangarView.new()
	add_child(_view)
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.set_interactive(false)
	_view.set_caption("")
	_view.highlight_hardpoint(-1)


func prepare() -> void:
	_show(0)
	await get_tree().create_timer(SETTLE_SECONDS).timeout


func play() -> void:
	_playing = true


func _process(delta: float) -> void:
	if not _playing:
		return
	_clock += delta
	var hercs: Array = spec.hercs
	var per := float(spec.per_herc)
	var i := mini(int(_clock / per), hercs.size() - 1)
	if i != _shown:
		_show(i)
	_apply_camera(clampf((_clock - i * per) / per, 0.0, 1.0))


## Herc i of the shot, framed fresh (the orbit carries on from where it was).
func _show(i: int) -> void:
	_shown = i
	var vid := String(spec.hercs[i])
	_view.show_herc(vid, VideoShots.make_foreign_loadout(vid))
	_view.bay.reset_view(true)
	_apply_camera(0.0)


## Sweeps round the Herc's front (alternating direction per Herc) while easing the camera up and
## in, over the Herc's time `k` (0..1).
func _apply_camera(k: float) -> void:
	var e := smoothstep(0.0, 1.0, k)
	var bay := _view.bay
	var sweep := -1.0 if _shown % 2 == 0 else 1.0
	bay.orbit_yaw = lerpf(-ARC_YAW, ARC_YAW, k) * sweep
	bay.orbit_pitch = lerpf(PITCH_START, PITCH_END, e)
	bay.zoom = lerpf(ZOOM_START, ZOOM_END, e) * _make_portrait_zoom()


## Tall frames: HangarBay fits the Herc's width, which leaves it small; fit its height instead.
func _make_portrait_zoom() -> float:
	var bay := _view.bay
	var vs := get_viewport_rect().size
	var aspect := vs.x / maxf(vs.y, 1.0)
	if aspect >= 1.0:
		return 1.0
	var t := tan(deg_to_rad(bay.camera.fov * 0.5))
	var by_height := bay.herc_height * 0.5 / bay.frame_fill / t
	var by_width := bay.herc_radius * 1.15 / 0.8 / (t * aspect)
	return maxf(1.0, by_width / by_height * PORTRAIT_CROP)
