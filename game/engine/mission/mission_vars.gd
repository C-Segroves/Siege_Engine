class_name MissionVars
extends RefCounted
## Mission variables (the campaigns carry them between missions) and an interpreter over named op tables. The tables are
## data the game adapters own: {opcode: "set" | "add" | "sub" | "mul" | "div" | "mod" | "min" | "max" | "copy"} for
## changes and {opcode: "eq" | "ne" | "lt" | "le" | "gt" | "ge"} for tests. "copy" takes the operand as a variable index.

var values := PackedInt32Array()
var _ops: Dictionary
var _tests: Dictionary


func _init(count: int, p_ops: Dictionary, p_tests: Dictionary) -> void:
	values.resize(count)
	_ops = p_ops
	_tests = p_tests


func get_value(index: int) -> int:
	return values[index] if index >= 0 and index < values.size() else 0


func apply_set(index: int, value: int) -> void:
	if index >= 0 and index < values.size():
		values[index] = value


## Runs `opcode` on variable `index` with `operand`; false for an opcode the table lacks.
func apply_op(opcode: Variant, index: int, operand: int) -> bool:
	if not _ops.has(opcode):
		return false
	var v := get_value(index)
	match str(_ops[opcode]):
		"set": v = operand
		"add": v += operand
		"sub": v -= operand
		"mul": v *= operand
		"div": v = v / operand if operand != 0 else v
		"mod": v = v % operand if operand != 0 else v
		"min": v = mini(v, operand)
		"max": v = maxi(v, operand)
		"copy": v = get_value(operand)
		_: return false
	apply_set(index, v)
	return true


## The result of test `opcode` on variable `index` against `operand` (false for an unknown opcode).
func make_test(opcode: Variant, index: int, operand: int) -> bool:
	var v := get_value(index)
	match str(_tests.get(opcode, "")):
		"eq": return v == operand
		"ne": return v != operand
		"lt": return v < operand
		"le": return v <= operand
		"gt": return v > operand
		"ge": return v >= operand
	return false
