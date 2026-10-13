class_name CockpitTargetImage
extends RefCounted
## The unit picture on the MFD STATUS / TARGET pages (docs/formats/cockpit.md sections 4.1 / 4.2 / 8.2).
## A unit of the cockpit's own game shows the original art: a Herc / Cybrid its small damage diagram
## (PDG image 2, regions recoloured by damage), a flyer the FLYERS picture, a base its BASES picture (no damage
## colours, DBSIM 0x334d9). Any other target (another game's vehicle, soldier or structure) shows its live model in
## the same spot, untextured, rendered by a TargetView in the cockpit palette's damage colours.

const SMALL_DIAGRAM := 2
## PSTATUS (DBSIM 0x335ad): FLYERS.DBA picture 0 at x + 2, its bottom 5 px above the display's bottom.
const FLYER_DBA := "FLYERS"
const FLYER_X := 2.0
const FLYER_BOTTOM_GAP := 5.0
## PSTATUS (DBSIM 0x334d9): BASES.DBA[base type] at the same place as the flyer picture.
const BASE_DBA := "BASES"
## An Earthsiege base shape id ("es1:BASES_3", "es1:BASES_E_2") -> its type, the BASES.DBA index.
const BASE_SHAPE_PATTERN := "^%s:BASES_(E_)?([0-9]+)$"

var canvas: CockpitCanvas
var pack := "es1"
var view: TargetView
## Where the pictures sit, relative to the MFD display (skin "status_picture" [x, y, w, h]): Earthsiege 1
## left of the text column, over the display's height (image-2 origins are 1..7, 1..14); Earthsiege 2
## PSTATUS.BND's picture box.
var picture_area: Rect2
## Native diagrams are placed at the display + their PDG origin + this offset (skin "diagram_offset").
var diagram_offset: Vector2


func _init(p_canvas: CockpitCanvas, p_pack: String) -> void:
	canvas = p_canvas
	pack = p_pack
	var skin := canvas.assets.skin
	var pa := skin.list("mfd", "status_picture")
	picture_area = Rect2(float(pa[0]), float(pa[1]), float(pa[2]), float(pa[3]))
	var off := skin.list("mfd", "diagram_offset")
	diagram_offset = Vector2(float(off[0]), float(off[1]))
	view = TargetView.new(Vector2i(picture_area.size),
		TargetRampPaint.new(canvas.assets.palette, canvas.assets.damage_bases(), canvas.assets.damage_shades()))


## True when the cockpit has the original damage diagram of `u`.
func has_diagram(u: Node3D) -> bool:
	if not (u is Herc and _is_own_game(u)):
		return false
	var pdg := canvas.assets.load_pdg(CockpitPainter.make_unit_key(u))
	return not pdg.is_empty() and pdg.images.size() > SMALL_DIAGRAM


func _is_own_game(u: Herc) -> bool:
	return str(u.def.get("pack", "")) == pack


func _is_own_flyer(u: Node3D) -> bool:
	return u is Flyer and _is_own_game(u)


## The BASES.DBA picture index of an own-game base `u`, -1 for anything else.
func make_base_picture(u: Node3D) -> int:
	if u is Herc or u.get("shape_id") == null:
		return -1
	var re := RegEx.create_from_string(BASE_SHAPE_PATTERN % pack)
	var m := re.search(str(u.get("shape_id")))
	if m == null or canvas.dba(BASE_DBA, int(m.get_string(2))) == null:
		return -1
	return int(m.get_string(2))


## True when `u` is drawn as a rendered 3D model (no original picture of it).
func is_rendered(u: Node3D) -> bool:
	return not has_diagram(u) and not _is_own_flyer(u) and make_base_picture(u) < 0


## Keeps the 3D view on `target` (any node; null or an original-art unit: no rendering).
func follow(target: Node, delta: float) -> void:
	var t := target as Node3D if target != null and is_instance_valid(target) else null
	view.apply_target(t if t != null and is_rendered(t) else null)
	view.advance(delta)


## Draws the picture of `u` in MFD display rect `d`.
func draw(d: Rect2, u: Node3D) -> void:
	if has_diagram(u):
		var im: Dictionary = canvas.assets.load_pdg(CockpitPainter.make_unit_key(u)).images[SMALL_DIAGRAM]
		canvas.blit(canvas.assets.diagram(CockpitPainter.make_unit_key(u), SMALL_DIAGRAM, u),
			d.position.x + float(im.origin[0]) + diagram_offset.x, d.position.y + float(im.origin[1]) + diagram_offset.y, d)
	elif _is_own_flyer(u):
		_draw_picture(d, canvas.dba(FLYER_DBA, 0))
	elif make_base_picture(u) >= 0:
		_draw_picture(d, canvas.dba(BASE_DBA, make_base_picture(u)))
	elif view.target == u and view.has_target():
		canvas.blit(view.get_texture(), d.position.x + picture_area.position.x, d.position.y + picture_area.position.y, d)


## A flyer / base picture: at x + 2, its bottom 5 px above the display's bottom (DBSIM 0x334d9, 0x335ad).
func _draw_picture(d: Rect2, tex: Texture2D) -> void:
	if tex:
		canvas.blit(tex, d.position.x + FLYER_X, d.end.y - 1.0 - canvas.size_of(tex).y - FLYER_BOTTOM_GAP, d)
