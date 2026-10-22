extends Node3D
## Headless check of where drops lie (LootDropPlacement): a drop that fell inside or under a vehicle pad's deck, in a
## wall, in a ceiling or in the air ends on a floor a soldier can stand on, within pickup reach of where it fell:
##   godot --headless --audio-driver Dummy --path game res://tests/loot_drop_check.tscn
const REACH := 3.0
const GROUND_Y := 0.0
const PAD_BOTTOM := 3.0
const PAD_TOP := 3.9
const CRAWL_GROUND := 40.0          # a deck low over a floor: the gap under it is too low to stand in
const CRAWL_BOTTOM := 40.9
const CRAWL_TOP := 41.8
const ROOM_FLOOR := 100.0
const ROOM_CEILING := 102.4

var _failed := 0
var _space: PhysicsDirectSpaceState3D
var _exclude: Array[RID] = []


func _ready() -> void:
	_build_world()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_space = get_world_3d().direct_space_state
	_check_pad()
	_check_crawl_space()
	_check_interior()
	_check_open_ground_and_air()
	_check_caches()
	print("loot_drop_check: %d failed" % _failed)
	get_tree().quit(1 if _failed > 0 else 0)


func _check_pad() -> void:
	print("a pad's deck on stilts over the ground:")
	var inside := _drop(Vector3(0.0, PAD_BOTTOM + 0.4, 0.0))
	_expect_reachable(inside, Vector3(0.0, PAD_BOTTOM + 0.4, 0.0), "a drop inside the slab")
	_expect(absf(inside.y - PAD_TOP) < 0.05, "  it lies on the deck (%.2f)" % inside.y)
	var low := _drop(Vector3(2.0, PAD_BOTTOM + 0.05, -3.0))
	_expect(absf(low.y - PAD_TOP) < 0.05, "a drop at the slab's underside lies on the deck, not under it (%.2f)" % low.y)
	_expect_reachable(low, Vector3(2.0, PAD_BOTTOM + 0.05, -3.0), "  and within reach")
	var on_top := _drop(Vector3(-4.0, PAD_TOP, 4.0))
	_expect(absf(on_top.y - PAD_TOP) < 0.05, "a drop on the deck stays on it")
	var under := _drop(Vector3(0.0, 2.0, 0.0))
	_expect_reachable(under, Vector3(0.0, 2.0, 0.0), "a drop in the open air under the deck")
	_expect(absf(under.y - GROUND_Y) < 0.05, "  it lies on the ground below (%.2f)" % under.y)


func _check_crawl_space() -> void:
	print("a deck low over the ground (no room to stand under it):")
	var p := Vector3(40.0, CRAWL_GROUND + 0.4, 0.0)
	var spot := _drop(p, CRAWL_GROUND)
	_expect(absf(spot.y - CRAWL_TOP) < 0.05, "the drop lies on the deck, not in the crawl space (%.2f)" % spot.y)
	_expect_reachable(spot, p, "  it is within reach")


func _check_interior() -> void:
	print("an interior (floor, four walls, a ceiling):")
	var in_wall := Vector3(5.5, ROOM_FLOOR + 1.0, 0.0)
	var a := _drop(in_wall, ROOM_FLOOR)
	_expect_reachable(a, in_wall, "a drop inside a wall")
	_expect(absf(a.y - ROOM_FLOOR) < 0.05, "  it lies on the floor, out of the wall (%s)" % str(a))
	var in_ceiling := Vector3(0.0, ROOM_CEILING + 0.3, 0.0)
	var b := _drop(in_ceiling, ROOM_FLOOR)
	_expect_reachable(b, in_ceiling, "a drop inside the ceiling")
	var in_room := Vector3(1.0, ROOM_FLOOR + 0.2, 1.0)
	var c := _drop(in_room, ROOM_FLOOR)
	_expect(c.distance_to(Vector3(1.0, ROOM_FLOOR, 1.0)) < 0.05, "a drop in the room stays where it fell")


func _check_open_ground_and_air() -> void:
	print("open ground and the air:")
	var ground := _drop(Vector3(-30.0, 0.3, 20.0))
	_expect(absf(ground.y - GROUND_Y) < 0.05 and absf(ground.x + 30.0) < 0.01, "a drop on open ground stays")
	var air := _drop(Vector3(-30.0, 40.0, -20.0))
	_expect(absf(air.y - GROUND_Y) < 0.05 and absf(air.x + 30.0) < 0.01, "a drop in the air falls to the ground (%.2f)" % air.y)


func _check_caches() -> void:
	print("a cache's place (the top surface over a map point):")
	var over_pad := LootDropPlacement.make_top_point(_space, _exclude, Vector3(3.0, 0.0, 3.0), 60.0, GROUND_Y)
	_expect(absf(over_pad.y - PAD_TOP) < 0.05, "over a pad it lies on the deck (%.2f)" % over_pad.y)
	var over_room := LootDropPlacement.make_top_point(_space, _exclude, Vector3(0.0, 0.0, 0.0), ROOM_CEILING + 60.0, ROOM_FLOOR)
	_expect(absf(over_room.y - (ROOM_CEILING + 0.6)) < 0.05, "over an interior it lies on its roof (%.2f)" % over_room.y)
	var open := LootDropPlacement.make_top_point(_space, _exclude, Vector3(-60.0, 0.0, 0.0), 60.0, GROUND_Y)
	_expect(absf(open.y - GROUND_Y) < 0.05, "in the open it lies on the ground")


## The drop point for a body whose feet are at `p`.
func _drop(p: Vector3, ground := GROUND_Y) -> Vector3:
	return LootDropPlacement.make_point(_space, _exclude, p, ground, REACH)


## `spot` is standable, within pickup reach of a soldier standing at `from`, and not inside any collider.
func _expect_reachable(spot: Vector3, from: Vector3, what: String) -> void:
	var flat := Vector2(spot.x - from.x, spot.z - from.z).length()
	_expect(LootDropPlacement.is_standable(_space, _exclude, spot), what + ": a soldier can stand on it")
	_expect(flat <= REACH and absf(spot.y - from.y) <= REACH, what + ": within reach (%.2f m across, %.2f m up)" % [flat, spot.y - from.y])


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed += 1


# ------------------------------------------------------------------ the world

func _build_world() -> void:
	_add_box(Vector3(0.0, -1.0, 0.0), Vector3(400.0, 2.0, 400.0))                       # the ground (top at 0)
	_add_box(Vector3(0.0, (PAD_BOTTOM + PAD_TOP) * 0.5, 0.0), Vector3(20.0, PAD_TOP - PAD_BOTTOM, 20.0))
	_add_box(Vector3(40.0, (CRAWL_BOTTOM + CRAWL_TOP) * 0.5, 0.0), Vector3(20.0, CRAWL_TOP - CRAWL_BOTTOM, 20.0))
	_add_box(Vector3(40.0, CRAWL_GROUND - 20.0, 0.0), Vector3(22.0, 40.0, 22.0))          # the floor under the crawl deck
	_add_box(Vector3(0.0, ROOM_FLOOR - 1.0, 0.0), Vector3(14.0, 2.0, 14.0))               # the room's floor (top at ROOM_FLOOR)
	for side in [-1.0, 1.0]:
		_add_box(Vector3(5.5 * side, (ROOM_FLOOR + ROOM_CEILING + 0.6) * 0.5, 0.0), Vector3(1.0, ROOM_CEILING + 0.6 - ROOM_FLOOR, 12.0))
		_add_box(Vector3(0.0, (ROOM_FLOOR + ROOM_CEILING + 0.6) * 0.5, 5.5 * side), Vector3(12.0, ROOM_CEILING + 0.6 - ROOM_FLOOR, 1.0))
	_add_box(Vector3(0.0, ROOM_CEILING + 0.3, 0.0), Vector3(12.0, 0.6, 12.0))


func _add_box(center: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	body.position = center
	add_child(body)
