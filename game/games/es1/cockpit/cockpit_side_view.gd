class_name CockpitSideView
extends RefCounted
## Earthsiege 2 look left / look right (docs/formats/cockpit.md section 8.9; ES2 DBSIM.EXE). The side views are
## VUE views 2 (right, pan +320) and 3 (left, pan -320): the panel shows the side art (DB2 / HB2: the right view
## as stored, drawn mirrored for the left, 0x42a261) and nothing else - every gauge, the HUD and the message lines
## scroll off with the panel (0x43271c, 0x435574). The camera does not turn: the projection centre moves
## sideways by the pan (port origin = centre offset + pan, 0x42a1a7), an off-axis view of a three-screen panorama.
## Toggles (request table 0x42a3f4): from the front view look_left / look_right pick a side, the other side key,
## look_up / look_down or an MFD page key goes back to the front; ignored while looking down.
## Only layouts with side art and side views of a pack in SIDE_VIEW_PACKS have them: Earthsiege 1 has DB2 art and
## VUE side views too, but its side keys and which side is mirrored are not decoded (cockpit.md section 1 guesses
## the opposite of Earthsiege 2), so it keeps its front / look-down views.

const FRONT := 0
const LEFT := -1
const RIGHT := 1
## VUE view indices of the side views.
const VIEW_RIGHT := 2
const VIEW_LEFT := 3
const SIDE_VIEW_PACKS := ["es2"]

var side := FRONT
var _pans := {}               # side -> pan in layout pixels


func _init(layout: Dictionary, pack: String) -> void:
	var views: Array = layout.get("views", [])
	if pack in SIDE_VIEW_PACKS and layout.get("panels", {}).has("side") and views.size() > VIEW_LEFT:
		_pans[RIGHT] = float(views[VIEW_RIGHT].get("pan", [0, 0])[0])
		_pans[LEFT] = float(views[VIEW_LEFT].get("pan", [0, 0])[0])


func is_available() -> bool:
	return not _pans.is_empty()


func is_side() -> bool:
	return side != FRONT


## look_left / look_right from the front view; true when `event` was one of them.
func apply_action(event: InputEvent, looking_down: bool) -> bool:
	var wanted := LEFT if event.is_action_pressed("look_left") else (RIGHT if event.is_action_pressed("look_right") else FRONT)
	if wanted == FRONT or not is_available():
		return false
	if not looking_down:
		side = wanted if side == FRONT else (FRONT if side == -wanted else side)
	return true


func apply_front() -> void:
	side = FRONT


## The side's pan in layout pixels (0 in the front view).
func make_pan() -> float:
	return float(_pans.get(side, 0.0))


## Moves frustum camera `cam`'s projection centre sideways by the pan: `canvas_width` layout pixels span the
## camera's `view_aspect`-wide frustum.
func apply_camera(cam: Camera3D, canvas_width: float, view_aspect: float) -> void:
	if cam == null or cam.projection != Camera3D.PROJECTION_FRUSTUM:
		return
	cam.frustum_offset.x = cam.size * view_aspect * make_pan() / canvas_width


## Draws the side panel art on `canvas` over `item` (its window `view_size`, layout-to-window scale `vscale`),
## mirrored for the left view.
func draw(item: CanvasItem, canvas: CockpitCanvas, panel: Texture2D, view_size: Vector2, vscale: Vector2) -> void:
	if side == LEFT:
		item.draw_set_transform(Vector2(view_size.x, 0.0), 0.0, Vector2(-vscale.x, vscale.y))
	canvas.blit(panel, 0, 0)
