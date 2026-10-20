extends Node
## EntityTable (engine/net/entity_table.gd), headless: units register, update once per tick, unregister (dense
## rows), freed Nodes drop out, and updating 300 rows is cheap.
##   godot --headless --audio-driver Dummy --path game res://tests/entity_table_check.tscn

const ROWS := 300
const BUDGET_USEC := 2000
const SAMPLE_TICKS := 20

var _failures := 0


func _ready() -> void:
	_check_round_trip()
	_check_unregister_keeps_rows_dense()
	_check_freed_unit_drops_out()
	_check_changed_tick()
	_check_update_cost()
	print("entity_table_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _make_unit(at: Vector3) -> CharacterBody3D:
	var u := CharacterBody3D.new()
	u.set_meta("ai", true)
	add_child(u)
	u.global_position = at
	u.velocity = Vector3(1, 0, 2)
	return u


func _make_table(count: int) -> Array:
	var table := EntityTable.new()
	var units: Array[Node3D] = []
	for i in count:
		var u := _make_unit(Vector3(i, 2.0, -i))
		units.append(u)
		table.register(1000 + i, u)
	return [table, units]


func _check_round_trip() -> void:
	var made := _make_table(ROWS)
	var table: EntityTable = made[0]
	var units: Array = made[1]
	_expect(table.size() == ROWS and table.has_entity(1000 + 7), "%d units registered" % ROWS)
	units[7].global_position = Vector3(5, 6, 7)
	units[7].rotation.y = 1.0
	table.update_from_nodes(1)
	var row := table.make_row(1007)
	_expect(table.make_position(row).is_equal_approx(Vector3(5, 6, 7)), "position read back")
	_expect(is_equal_approx(table.yaw[row], 1.0) and table.make_velocity(row).is_equal_approx(Vector3(1, 0, 2)), "yaw and velocity read back")
	_expect(table.is_flagged(row, EntityTable.FLAG_BOT) and not table.is_flagged(row, EntityTable.FLAG_HUMAN), "an AI unit is flagged as bot")
	table.register(1007, units[7])
	_expect(table.size() == ROWS, "registering an id twice keeps one row")
	_free_all(units)


func _check_unregister_keeps_rows_dense() -> void:
	var made := _make_table(5)
	var table: EntityTable = made[0]
	table.unregister(1001)
	table.unregister(4242)   # unknown: ignored
	table.update_from_nodes(1)
	var ok := table.size() == 4
	for id in [1000, 1002, 1003, 1004]:
		var row := table.make_row(id)
		ok = ok and row != EntityTable.NO_ROW and table.ids[row] == id and is_equal_approx(table.pos_x[row], float(id - 1000))
	_expect(ok and not table.has_entity(1001), "unregister moves the last row into the hole; ids, rows and positions agree")
	_free_all(made[1])


func _check_freed_unit_drops_out() -> void:
	var made := _make_table(4)
	var table: EntityTable = made[0]
	(made[1][2] as Node).free()
	table.update_from_nodes(1)
	_expect(table.size() == 3 and not table.has_entity(1002), "a freed Node is unregistered by the next update")
	_free_all(made[1])


func _check_changed_tick() -> void:
	var made := _make_table(2)
	var table: EntityTable = made[0]
	table.update_from_nodes(10)
	var row := table.make_row(1000)
	var first := table.last_changed_tick[row]
	table.update_from_nodes(11)
	_expect(table.last_changed_tick[row] == first, "an unmoved unit keeps its last_changed_tick")
	made[1][0].global_position += Vector3.RIGHT
	table.update_from_nodes(12)
	_expect(table.last_changed_tick[row] == 12, "a moved unit's last_changed_tick is the tick")
	_free_all(made[1])


func _check_update_cost() -> void:
	var made := _make_table(ROWS)
	var table: EntityTable = made[0]
	var best := INF
	for t in SAMPLE_TICKS:
		var start := Time.get_ticks_usec()
		table.update_from_nodes(t)
		best = minf(best, float(Time.get_ticks_usec() - start))
	print("  update of %d rows: %.0f us (best of %d)" % [ROWS, best, SAMPLE_TICKS])
	_expect(best < BUDGET_USEC, "updating %d rows costs under %d us" % [ROWS, BUDGET_USEC])
	_free_all(made[1])


func _free_all(units: Array) -> void:
	for u in units:
		if is_instance_valid(u):
			u.free()
