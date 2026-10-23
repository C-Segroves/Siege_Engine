class_name Formation
extends RefCounted
## Slot offsets of a formation, in the leader's frame (metres), each game keeping its own original layout:
##   table      Earthsiege 1/2 gameplay/formations.json (original units, turned by the group's yaw); the Tribes
##              missions use the ES1 table's first Herc formation for their AI followers;
##   scripted   Starsiege newFormation(name, x0, y0, z0, ...) from datFormation.cs: the first triple is the leader slot;
##   squad      the player squad's start slots (wingmen alternate left / right, back from the leader);
##   rows       the command map's "join on me" (rows of three behind the commander; remake addition).
## Slot 0 of a leader formation is the leader (offset zero); follower k is slots[k - 1]. Beyond the listed slots an
## `overflow_step` (Starsiege, Tribes: step * k) or an `overflow_fan` (ES2: the squad pattern at that spacing) applies,
## else the follower stands on the leader.

## Metres between the player squad's start slots (Earthsiege and Starsiege).
const SQUAD_SPACING := 25.0
## ES2's out-of-table Herc slots fan out this far apart.
const ES2_FAN_SPACING := 30.0
## Starsiege: slots beyond the ones newFormation listed.
const STARSIEGE_STEP := Vector3(12.0, 0, 16.0)
## Starsiege: the player's wingmen (formation_offset_local, no script formation).
const STARSIEGE_WINGMAN_STEP := Vector3(15.0, 0, 20.0)
## The command map's slots behind the commander (metres).
const ROWS_SPACING := 12.0
const ROW_WIDTH := 3

var slots: Array[Vector3] = []
var overflow_step := Vector3.ZERO
var overflow_fan := 0.0


## Follower `k`'s offset (k = 0 is the leader).
func offset_of(k: int) -> Vector3:
	if k <= 0:
		return Vector3.ZERO
	if k <= slots.size():
		return slots[k - 1]
	if overflow_fan > 0.0:
		return squad_slot(k, overflow_fan)
	return overflow_step * k


## A formation of table slots (original units [x, y, z?]) turned by `yaw`.
static func make_from_table(table_slots: Array, yaw: float) -> Formation:
	var f := Formation.new()
	var turn := Basis(Vector3.UP, yaw)
	for o in table_slots:
		f.slots.append(turn * ShapeInstance.es_to_godot([o[0], o[1], o[2] if o.size() > 2 else 0]))
	return f


## A table formation `form` of `key` ("mech_formations" ...) in `table`; out of range: the last one when `clamp_form`,
## else an empty formation (the followers stand on the leader).
static func make_from_table_entry(table: Variant, key: String, form: int, yaw: float, clamp_form: bool) -> Formation:
	if not table is Dictionary:
		return Formation.new()
	var forms: Array = table.get(key, [])
	if forms.is_empty() or (form >= forms.size() and not clamp_form):
		return Formation.new()
	return make_from_table(forms[clampi(form, 0, forms.size() - 1)], yaw)


## Starsiege newFormation: `offsets` are the engine-space triples, the first one the leader's slot.
static func make_scripted(offsets: Array) -> Formation:
	var f := Formation.new()
	for k in range(1, offsets.size()):
		f.slots.append(offsets[k])
	f.overflow_step = STARSIEGE_STEP
	return f


## Followers on a straight step: slot k at step * k.
static func make_stepped(step: Vector3) -> Formation:
	var f := Formation.new()
	f.overflow_step = step
	return f


## The player squad's slot `k` (0 = leader): wingmen alternate left / right, `spacing` apart and back.
static func squad_slot(k: int, spacing := SQUAD_SPACING) -> Vector3:
	if k <= 0:
		return Vector3.ZERO
	var row := (k + 1) / 2
	return Vector3((k % 2 * 2 - 1) * spacing * row, 0, spacing * row)


## The command map's slot `index` (from 0) behind the commander: rows of three.
static func rows_slot(index: int, spacing := ROWS_SPACING) -> Vector3:
	var row := index / ROW_WIDTH + 1
	var col := index % ROW_WIDTH - 1
	return Vector3(col * spacing, 0.0, row * spacing)
