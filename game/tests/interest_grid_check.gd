extends Node
## Headless check of InterestGrid (docs/DEDICATED_SERVER_SCALING.md chunk D): near/far selection by cell range,
## tiers, radar-visible entity included, line-of-sight demotion, enter/leave events, send intervals, disabled mode.
##   godot --headless --audio-driver Dummy --path game res://tests/interest_grid_check.tscn

const CLIENT := 1
const OWN_ID := 100
const NEAR_ID := 101
const MID_ID := 102
const FAR_VEHICLE_ID := 103
const BEYOND_ID := 104
const RADAR_ID := 105
const ALLY_ID := 107
const SOLDIER_FAR_ID := 108
const OCCLUDED_ID := 200
const SoldierStub := preload("res://tests/interest_grid_soldier_stub.gd")
const VehicleStub := preload("res://tests/interest_grid_vehicle_stub.gd")

var _fails := 0
var _nodes := {}                            # id -> Node3D


func _ready() -> void:
	var table := _make_table()
	var grid := InterestGrid.new()
	grid.add_client(CLIENT, OWN_ID, 1)
	grid.rebuild(table)
	grid.evaluate_client(CLIENT)
	_check_range_and_tiers(grid)
	_check_radar(grid)
	_check_los_demotion(grid, table)
	_check_events(grid, table)
	_check_send_intervals(grid)
	_check_disabled(grid)
	for node: Node in _nodes.values():
		node.free()
	print("interest_grid_check: ", "PASS" if _fails == 0 else "%d FAILED" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _make_table() -> EntityTable:
	var table := EntityTable.new()
	_register(table, OWN_ID, Vector3(0, 0, 0), 1, false)
	_register(table, NEAR_ID, Vector3(50, 0, 0), 2, false)
	_register(table, MID_ID, Vector3(0, 0, 250), 2, false)
	_register(table, FAR_VEHICLE_ID, Vector3(600, 0, 0), 2, false)
	_register(table, BEYOND_ID, Vector3(0, 0, 3000), 2, false)
	_register(table, RADAR_ID, Vector3(-2000, 0, 0), 2, false)
	_register(table, ALLY_ID, Vector3(0, 0, -1500), 1, false)
	_register(table, SOLDIER_FAR_ID, Vector3(500, 0, 0), 2, true)
	return table


func _register(table: EntityTable, id: int, at: Vector3, team: int, soldier: bool) -> void:
	var unit := Node3D.new()
	unit.set_script(SoldierStub if soldier else VehicleStub)
	add_child(unit)
	unit.position = at
	unit.set("team", team)
	_nodes[id] = unit
	table.register(id, unit)


func _check_range_and_tiers(grid: InterestGrid) -> void:
	_expect(grid.tier_of(CLIENT, OWN_ID) == InterestGrid.Tier.NEAR, "own unit is NEAR")
	_expect(grid.tier_of(CLIENT, NEAR_ID) == InterestGrid.Tier.NEAR, "50 m is NEAR")
	_expect(grid.tier_of(CLIENT, MID_ID) == InterestGrid.Tier.MID, "250 m is MID")
	_expect(grid.tier_of(CLIENT, FAR_VEHICLE_ID) == InterestGrid.Tier.FAR, "600 m vehicle is FAR")
	_expect(not grid.is_relevant(CLIENT, BEYOND_ID), "3000 m entity is not relevant")
	_expect(not grid.is_relevant(CLIENT, SOLDIER_FAR_ID), "soldier past its 300 m view range is not relevant")
	_expect(grid.tier_of(CLIENT, ALLY_ID) == InterestGrid.Tier.FAR, "far ally stays relevant at FAR")


func _check_radar(grid: InterestGrid) -> void:
	_expect(not grid.is_relevant(CLIENT, RADAR_ID), "unseen distant entity absent without radar")
	grid.radar_probe = func(_client: int, entity: int) -> bool: return entity == RADAR_ID
	grid.evaluate_client(CLIENT)
	_expect(grid.tier_of(CLIENT, RADAR_ID) == InterestGrid.Tier.FAR, "radar contact included at FAR")
	_expect(grid.entered_ids(CLIENT).has(RADAR_ID), "radar contact reported as entered")
	grid.radar_probe = Callable()
	grid.evaluate_client(CLIENT)
	_expect(grid.left_ids(CLIENT).has(RADAR_ID), "radar contact reported as left once off radar")


func _check_los_demotion(grid: InterestGrid, table: EntityTable) -> void:
	_register(table, OCCLUDED_ID, Vector3(0, 0, 300), 2, false)
	grid.rebuild(table)
	grid.evaluate_client(CLIENT)
	_expect(grid.tier_of(CLIENT, OCCLUDED_ID) == InterestGrid.Tier.MID, "visible 300 m entity is MID")
	grid.occlusion_probe = func(_client: int, entity: int) -> bool: return entity == OCCLUDED_ID
	grid.evaluate_client(CLIENT)
	_expect(grid.tier_of(CLIENT, OCCLUDED_ID) == InterestGrid.Tier.FAR, "occluded MID entity demoted to FAR")
	_expect(grid.is_relevant(CLIENT, OCCLUDED_ID), "occluded entity is demoted, not dropped")
	_expect(grid.tier_of(CLIENT, NEAR_ID) == InterestGrid.Tier.NEAR, "near entity never ray-tested")
	grid.occlusion_probe = Callable()


func _check_events(grid: InterestGrid, table: EntityTable) -> void:
	grid.evaluate_client(CLIENT)
	_expect(grid.entered_ids(CLIENT).is_empty() and grid.left_ids(CLIENT).is_empty(), "no change, no events")
	_nodes[BEYOND_ID].position = Vector3(0, 0, 100)
	_refresh(grid, table, 1)
	_expect(grid.entered_ids(CLIENT).has(BEYOND_ID), "entity moving into range is reported entered")
	_nodes[BEYOND_ID].position = Vector3(0, 0, 3000)
	_refresh(grid, table, 2)
	_expect(grid.left_ids(CLIENT).has(BEYOND_ID), "entity moving out of range is reported left")
	table.unregister(NEAR_ID)
	_refresh(grid, table, 3)
	_expect(grid.left_ids(CLIENT).has(NEAR_ID), "unregistered entity is reported left")


func _refresh(grid: InterestGrid, table: EntityTable, tick: int) -> void:
	table.update_from_nodes(tick)
	grid.rebuild(table)
	grid.evaluate_client(CLIENT)


func _check_send_intervals(grid: InterestGrid) -> void:
	grid.evaluate_client(CLIENT)
	var mid_sent := 0
	var far_sent := 0
	for tick in 15:
		mid_sent += int(grid.should_send(CLIENT, MID_ID, tick))
		far_sent += int(grid.should_send(CLIENT, FAR_VEHICLE_ID, tick))
		_expect(grid.should_send(CLIENT, OWN_ID, tick), "NEAR is sent every tick")
	_expect(mid_sent == 5, "MID is sent every 3rd tick (got %d of 15)" % mid_sent)
	_expect(far_sent == 3, "FAR is sent every 5th tick (got %d of 15)" % far_sent)
	_expect(not grid.should_send(CLIENT, BEYOND_ID, 0), "irrelevant entity is never sent")


func _check_disabled(grid: InterestGrid) -> void:
	grid.enabled = false
	grid.evaluate_client(CLIENT)
	_expect(grid.tier_of(CLIENT, BEYOND_ID) == InterestGrid.Tier.NEAR, "disabled grid: everything NEAR")
	grid.enabled = true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_fails += 1
		push_error("interest_grid_check FAIL: " + message)
		print("FAIL: ", message)
