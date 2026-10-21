extends Node
## The cubemap sky orientation (MapEnvironment): Torque skies (Tribes 2, Varuna's Fall) give six pictures as seen from inside
## the box; Godot samples cubemap layers the OpenGL way, so each must be turned or the faces meet in a hard seam.
##   godot --headless --audio-driver Dummy --path game res://tests/sky_check.tscn
## Synthetic pictures whose touching edges carry the same colour: after the orientation the touching edges of the Godot layers
## (+X right, -Z front, -X left, +Z back, +Y top) must still carry the same colour.
const SIZE := 8
const SIDE_ORDER := ["front", "right", "back", "left"]

var _failures := 0


func _ready() -> void:
	_check_layout_choice()
	_check_side_edges()
	_check_top_edges()
	print("sky_check: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", what])


func _check_layout_choice() -> void:
	_expect(MapEnvironment.make_skybox_layout({"skybox_source": "x.dml"}) == MapEnvironment.LAYOUT_TORQUE, "a Tribes 2 export names its source: torque")
	_expect(MapEnvironment.make_skybox_layout({"skybox_layout": "torque"}) == MapEnvironment.LAYOUT_TORQUE, "Varuna says torque")
	_expect(MapEnvironment.make_skybox_layout({"skybox_faces": {}}) == MapEnvironment.LAYOUT_CUBE, "the Tribes AA baker's faces stay as they are")
	var a := _make_picture(Color.RED, Color.BLUE)
	var before := a.get_pixel(0, 0)
	MapEnvironment.apply_torque_orientation(a, "bottom")
	_expect(a.get_pixel(0, 0) == before, "the flat bottom is left alone")


## Side pictures: the right column of each is the left column of the next (clockwise from above); the Godot layers
## front(-Z) -> left(-X) -> back(+Z) -> right(+X) must touch the same way (right column of a layer = left column of the next).
func _check_side_edges() -> void:
	var colors := [Color.RED, Color.GREEN, Color.BLUE, Color.YELLOW]
	var layers := {}
	for i in SIDE_ORDER.size():
		var picture := _make_picture(colors[i], colors[(i + 1) % 4])
		MapEnvironment.apply_torque_orientation(picture, SIDE_ORDER[i])
		layers[SIDE_ORDER[i]] = picture
	var godot_ring := ["front", "left", "back", "right"]
	for i in godot_ring.size():
		var here: Image = layers[godot_ring[i]]
		var next: Image = layers[godot_ring[(i + 1) % 4]]
		_expect(here.get_pixel(SIZE - 1, 3) == next.get_pixel(0, 3), "layer %s meets %s" % [godot_ring[i], godot_ring[(i + 1) % 4]])


## The top picture's bottom row touches the front picture's top row left to right; Godot's +Y layer meets the -Z layer
## along its first row, running the other way round.
func _check_top_edges() -> void:
	var front := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	var top := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for x in SIZE:
		var c := Color(float(x) / SIZE, 0.5, 0.25)
		front.set_pixel(x, 0, c)
		top.set_pixel(x, SIZE - 1, c)
	MapEnvironment.apply_torque_orientation(front, "front")
	MapEnvironment.apply_torque_orientation(top, "top")
	var meets := true
	for x in SIZE:
		meets = meets and front.get_pixel(x, 0) == top.get_pixel(SIZE - 1 - x, 0)
	_expect(meets, "layer top meets layer front along the front's top row, reversed")


## A picture whose left column is `left` and whose right column is `right`.
func _make_picture(left: Color, right: Color) -> Image:
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	img.fill(Color.BLACK)
	for y in SIZE:
		img.set_pixel(0, y, left)
		img.set_pixel(SIZE - 1, y, right)
	return img
