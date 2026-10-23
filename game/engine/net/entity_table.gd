class_name EntityTable
extends RefCounted
## The server's data-oriented view of every networked unit (Herc, vehicle, soldier, bot): parallel packed arrays
## indexed by a dense row. The interest grid, snapshot codec, hit history and bot LOD read these arrays instead
## of walking Nodes and their script properties (docs/DEDICATED_SERVER_SCALING.md section 5.2).
##
## Units register once, unregister when they leave, and are copied in by update_from_nodes once per tick. Rows
## are kept dense: unregistering moves the last row into the hole, so a row index is only stable within a tick.
## The Node stays the source of truth for rich logic; the table holds only the passive state the network needs.

## flags bits
const FLAG_ALIVE := 1
const FLAG_HUMAN := 2
const FLAG_BOT := 4
const FLAG_SOLDIER := 8
const FLAG_PUPPET := 16

const NO_ROW := -1
const NO_TICK := -1
const DEFAULT_HIT_RADIUS := 0.6
const DEFAULT_HIT_HEIGHT := 2.0

var ids := PackedInt32Array()
var pos_x := PackedFloat32Array()
var pos_y := PackedFloat32Array()
var pos_z := PackedFloat32Array()
var vel_x := PackedFloat32Array()
var vel_y := PackedFloat32Array()
var vel_z := PackedFloat32Array()
var yaw := PackedFloat32Array()
var team := PackedByteArray()
var flags := PackedInt32Array()
var health := PackedFloat32Array()        # 0..1
var last_changed_tick := PackedInt32Array()
## Hit capsule (metres) standing on the position: lag compensation tests shots against it.
var hit_radius := PackedFloat32Array()
var hit_height := PackedFloat32Array()

var _row_of := {}                         # net id -> row
var _nodes: Array[Node3D] = []            # row -> the unit's Node (read by update_from_nodes only)
var _tick := 0


func size() -> int:
	return ids.size()


func has_entity(net_id: int) -> bool:
	return _row_of.has(net_id)


## The row of `net_id`, NO_ROW when it is not registered.
func make_row(net_id: int) -> int:
	return _row_of.get(net_id, NO_ROW)


func tick() -> int:
	return _tick


## Adds `unit` as `net_id` and reads its state now. Registering an id twice replaces its Node.
func register(net_id: int, unit: Node3D) -> void:
	var row := make_row(net_id)
	if row == NO_ROW:
		row = ids.size()
		_row_of[net_id] = row
		_append_blank_row(net_id)
		_nodes.append(unit)
	else:
		_nodes[row] = unit
	_read_row(row, _tick)


func unregister(net_id: int) -> void:
	var row := make_row(net_id)
	if row == NO_ROW:
		return
	var last := ids.size() - 1
	if row != last:
		_move_row(last, row)
	_pop_last_row()
	_row_of.erase(net_id)


## Copies every registered unit's state in (one pass, once per server tick); units whose Node was freed are
## unregistered. Returns nothing: read the arrays.
func update_from_nodes(tick_number: int) -> void:
	_tick = tick_number
	var row := ids.size() - 1
	while row >= 0:   # backwards: unregistering moves the last (already visited) row into the hole
		if is_instance_valid(_nodes[row]):
			_read_row(row, tick_number)
		else:
			unregister(ids[row])
		row -= 1


func make_position(row: int) -> Vector3:
	return Vector3(pos_x[row], pos_y[row], pos_z[row])


func make_velocity(row: int) -> Vector3:
	return Vector3(vel_x[row], vel_y[row], vel_z[row])


func is_flagged(row: int, flag: int) -> bool:
	return (flags[row] & flag) != 0


# ------------------------------------------------------------------ rows

func _append_blank_row(net_id: int) -> void:
	ids.append(net_id)
	pos_x.append(0.0)
	pos_y.append(0.0)
	pos_z.append(0.0)
	vel_x.append(0.0)
	vel_y.append(0.0)
	vel_z.append(0.0)
	yaw.append(0.0)
	team.append(0)
	flags.append(0)
	health.append(1.0)
	last_changed_tick.append(NO_TICK)
	hit_radius.append(DEFAULT_HIT_RADIUS)
	hit_height.append(DEFAULT_HIT_HEIGHT)


func _pop_last_row() -> void:
	var last := ids.size() - 1
	for a in [ids, pos_x, pos_y, pos_z, vel_x, vel_y, vel_z, yaw, team, flags, health, last_changed_tick, hit_radius, hit_height]:
		a.remove_at(last)
	_nodes.remove_at(last)


func _move_row(from: int, to: int) -> void:
	ids[to] = ids[from]
	pos_x[to] = pos_x[from]
	pos_y[to] = pos_y[from]
	pos_z[to] = pos_z[from]
	vel_x[to] = vel_x[from]
	vel_y[to] = vel_y[from]
	vel_z[to] = vel_z[from]
	yaw[to] = yaw[from]
	team[to] = team[from]
	flags[to] = flags[from]
	health[to] = health[from]
	last_changed_tick[to] = last_changed_tick[from]
	hit_radius[to] = hit_radius[from]
	hit_height[to] = hit_height[from]
	_nodes[to] = _nodes[from]
	_row_of[ids[to]] = to


## Reads the unit's state into `row`; last_changed_tick moves only when pose, flags or health changed.
func _read_row(row: int, tick_number: int) -> void:
	var unit := _nodes[row]
	var at := unit.global_position
	var velocity: Variant = unit.get("velocity")   # one property lookup each: this runs for every unit every tick
	var integrity: Variant = unit.get("integrity")
	var side: Variant = unit.get("team")
	var new_flags := _make_flags(unit)
	var new_health := clampf(float(integrity) if integrity != null else 1.0, 0.0, 1.0)
	var new_yaw := unit.global_rotation.y
	var changed := at.x != pos_x[row] or at.y != pos_y[row] or at.z != pos_z[row] or new_yaw != yaw[row] 		or new_flags != flags[row] or new_health != health[row] or last_changed_tick[row] == NO_TICK
	pos_x[row] = at.x
	pos_y[row] = at.y
	pos_z[row] = at.z
	if velocity is Vector3:
		vel_x[row] = velocity.x
		vel_y[row] = velocity.y
		vel_z[row] = velocity.z
	else:
		vel_x[row] = 0.0
		vel_y[row] = 0.0
		vel_z[row] = 0.0
	yaw[row] = new_yaw
	team[row] = clampi(int(side) if side != null else 0, 0, 255)
	flags[row] = new_flags
	health[row] = new_health
	if unit.has_method("make_hit_capsule"):
		var capsule: Vector2 = unit.make_hit_capsule()
		hit_radius[row] = capsule.x
		hit_height[row] = capsule.y
	if changed:
		last_changed_tick[row] = tick_number


static func _make_flags(unit: Node3D) -> int:
	var f := 0
	if unit.get("alive") != false:
		f |= FLAG_ALIVE
	if unit.has_meta("bot_id") or unit.has_meta("ai"):
		f |= FLAG_BOT
	else:
		f |= FLAG_HUMAN
	if unit.has_method("make_snapshot_extra"):   # Infantry
		f |= FLAG_SOLDIER
	if unit.get("is_puppet") == true:
		f |= FLAG_PUPPET
	return f
