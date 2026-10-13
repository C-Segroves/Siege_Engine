class_name DarkstarValues
extends RefCounted
## The value rules of Darkstar-family scripts: values are Strings, floats or ints; a number shows without
## ".0" when whole; truth is "not empty, not 0, not false"; TorqueScript reads a string's leading number
## ("12 5 3" -> 12, its atof). The operators every dialect shares are in DarkstarScript.binop; the
## TorqueScript-only ones (string compares, SPC / TAB / NL, bit operators) are here.


static func is_num(v) -> bool:
	if v is float or v is int:
		return true
	var s := String(v).strip_edges()
	return s != "" and s.is_valid_float()


static func num(v) -> float:
	if v is float or v is int:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	var s := String(v).strip_edges()
	if s.is_valid_float():
		return float(s)
	var l := s.to_lower()
	if l == "true":
		return 1.0
	return 0.0


## TorqueScript's number of a value: the leading number of a string ("12 5 3" -> 12, "abc" -> 0).
static func leading_num(v) -> float:
	if v is float or v is int or v is bool:
		return num(v)
	var s := String(v).strip_edges()
	if s.is_valid_float():
		return float(s)
	var head := s.get_slice(" ", 0)
	return float(head) if head.is_valid_float() else num(s)


static func truthy(v) -> bool:
	if v is bool:
		return v
	if v is float or v is int:
		return v != 0
	var s := String(v).strip_edges()
	if s == "":
		return false
	if s.is_valid_float():
		return float(s) != 0.0
	var l := s.to_lower()
	return l != "false"


static func to_str(v) -> String:
	if v is float:
		if v == floorf(v) and absf(v) < 1e15:
			return str(int(v))
		return str(v)
	return str(v)


## A whole float as an int (the scripts print "3", not "3.0").
static func clean(v: float):
	return int(v) if v == floorf(v) and absf(v) < 1e15 else v


static func is_boolish(v) -> bool:
	if v is String:
		var l := String(v).to_lower()
		return l == "true" or l == "false" or l == ""
	return false


## The TorqueScript-only binary operators ("" for an unknown operator).
static func torque_binop(op: String, a, b):
	match op:
		"$=": return 1 if to_str(a).to_lower() == to_str(b).to_lower() else 0
		"!$=": return 0 if to_str(a).to_lower() == to_str(b).to_lower() else 1
		"SPC": return to_str(a) + " " + to_str(b)
		"TAB": return to_str(a) + "\t" + to_str(b)
		"NL": return to_str(a) + "\n" + to_str(b)
		"&": return int(leading_num(a)) & int(leading_num(b))
		"|": return int(leading_num(a)) | int(leading_num(b))
		"^": return int(leading_num(a)) ^ int(leading_num(b))
		"<<": return int(leading_num(a)) << int(leading_num(b))
		">>": return int(leading_num(a)) >> int(leading_num(b))
	return ""
