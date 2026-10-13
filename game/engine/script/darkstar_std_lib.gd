class_name DarkstarStdLib
extends DarkstarFunctionTable
## The string, math and vector functions of the Darkstar / Torque consoles that need no game: words and
## fields of strings, String::* (Tribes), the m* math and Vector* functions (Tribes 2), getRandom, echo.
## Vectors are "x y z" strings; a transform is "x y z ax ay az angle" (axis-angle, radians).
## Included by the Tribes function tables (DarkstarFunctionTable.include).

const WORD_SEPARATORS := " \t\n"
const FIELD_SEPARATORS := "\t\n"
const RECORD_SEPARATORS := "\n"
## mFloatLength / vector formatting: TorqueScript prints floats with up to 6 significant digits.
const FLOAT_DIGITS := 6

## Every echo / error line (diagnostics; tests read it).
var echoes: Array[String] = []


func _init() -> void:
	_register_strings()
	_register_math()
	_register_vectors()
	_on(["echo", "dbecho", "error", "warn"], _echo)


func _register_strings() -> void:
	_on(["getword"], func(_n, a): return make_words(_s(a, 0), WORD_SEPARATORS, int(_f(a, 1)), int(_f(a, 1))))
	_on(["getwords"], func(_n, a): return make_words(_s(a, 0), WORD_SEPARATORS, int(_f(a, 1)), int(_f(a, 2, 1e9))))
	_on(["getwordcount"], func(_n, a): return make_parts(_s(a, 0), WORD_SEPARATORS).size())
	_on(["firstword"], func(_n, a): return make_words(_s(a, 0), WORD_SEPARATORS, 0, 0))
	_on(["restwords"], func(_n, a): return make_words(_s(a, 0), WORD_SEPARATORS, 1, 1000000000))
	_on(["setword"], _set_word)
	_on(["removeword"], _remove_word)
	_on(["getfield"], func(_n, a): return make_words(_s(a, 0), FIELD_SEPARATORS, int(_f(a, 1)), int(_f(a, 1))))
	_on(["getfieldcount"], func(_n, a): return make_parts(_s(a, 0), FIELD_SEPARATORS).size())
	_on(["getrecord"], func(_n, a): return make_words(_s(a, 0), RECORD_SEPARATORS, int(_f(a, 1)), int(_f(a, 1))))
	_on(["getrecordcount"], func(_n, a): return make_parts(_s(a, 0), RECORD_SEPARATORS).size())
	_on(["strlen"], func(_n, a): return _s(a, 0).length())
	_on(["strcat"], func(_n, a): return "".join(a.map(func(x): return DarkstarScript.to_str(x))))
	_on(["strupr"], func(_n, a): return _s(a, 0).to_upper())
	_on(["strlwr"], func(_n, a): return _s(a, 0).to_lower())
	_on(["strstr", "strpos"], func(_n, a): return _s(a, 0).find(_s(a, 1), int(_f(a, 2))))
	_on(["strcmp", "string::compare"], func(_n, a): return signi(_s(a, 0).casecmp_to(_s(a, 1))))
	_on(["stricmp", "string::icompare"], func(_n, a): return signi(_s(a, 0).nocasecmp_to(_s(a, 1))))
	_on(["strreplace"], func(_n, a): return _s(a, 0).replace(_s(a, 1), _s(a, 2)))
	_on(["getsubstr", "string::getsubstr"], func(_n, a): return _s(a, 0).substr(int(_f(a, 1)), int(_f(a, 2, 1e9))))
	_on(["string::findsubstr"], func(_n, a): return _s(a, 0).find(_s(a, 1)))
	_on(["trim"], func(_n, a): return _s(a, 0).strip_edges())
	_on(["stripchars"], _strip_chars)
	_on(["stripmlcontrolchars", "striptrailingspaces"], func(_n, a): return _s(a, 0).strip_edges(false, true))


func _register_math() -> void:
	_on(["floor", "mfloor"], func(_n, a): return int(floorf(_f(a, 0))))
	_on(["mceil"], func(_n, a): return int(ceilf(_f(a, 0))))
	_on(["mabs"], func(_n, a): return DarkstarScript._clean(absf(_f(a, 0))))
	_on(["msqrt"], func(_n, a): return sqrt(maxf(_f(a, 0), 0.0)))
	_on(["mpow"], func(_n, a): return pow(_f(a, 0), _f(a, 1)))
	_on(["msin"], func(_n, a): return sin(_f(a, 0)))
	_on(["mcos"], func(_n, a): return cos(_f(a, 0)))
	_on(["mtan"], func(_n, a): return tan(_f(a, 0)))
	_on(["matan"], func(_n, a): return atan2(_f(a, 0), _f(a, 1)))
	_on(["masin"], func(_n, a): return asin(clampf(_f(a, 0), -1.0, 1.0)))
	_on(["macos"], func(_n, a): return acos(clampf(_f(a, 0), -1.0, 1.0)))
	_on(["mdegtorad"], func(_n, a): return deg_to_rad(_f(a, 0)))
	_on(["mradtodeg"], func(_n, a): return rad_to_deg(_f(a, 0)))
	_on(["mfloatlength"], func(_n, a): return String.num(_f(a, 0), int(_f(a, 1))))
	_on(["getrandom"], _get_random)
	_on(["time::getminutes"], func(_n, a): return int(floorf(_f(a, 0) / 60.0)))
	_on(["time::getseconds"], func(_n, a): return int(fmod(floorf(_f(a, 0)), 60.0)))


func _register_vectors() -> void:
	_on(["vectoradd"], func(_n, a): return make_vector_string(make_vector(_s(a, 0)) + make_vector(_s(a, 1))))
	_on(["vectorsub"], func(_n, a): return make_vector_string(make_vector(_s(a, 0)) - make_vector(_s(a, 1))))
	_on(["vectorscale"], func(_n, a): return make_vector_string(make_vector(_s(a, 0)) * _f(a, 1)))
	_on(["vectordist"], func(_n, a): return make_vector(_s(a, 0)).distance_to(make_vector(_s(a, 1))))
	_on(["vectorlen"], func(_n, a): return make_vector(_s(a, 0)).length())
	_on(["vectornormalize"], func(_n, a): return make_vector_string(make_vector(_s(a, 0)).normalized()))
	_on(["vectordot"], func(_n, a): return make_vector(_s(a, 0)).dot(make_vector(_s(a, 1))))
	_on(["vectorcross"], func(_n, a): return make_vector_string(make_vector(_s(a, 0)).cross(make_vector(_s(a, 1)))))
	_on(["matrixmulvector"], func(_n, a): return make_vector_string(make_rotation(_s(a, 0)) * make_vector(_s(a, 1))))


# ------------------------------------------------------------------ helpers (also used by the game tables)

static func _s(a: Array, i: int) -> String:
	return DarkstarScript.to_str(_arg(a, i))


static func _f(a: Array, i: int, default := 0.0) -> float:
	return DarkstarScript.leading_num(_arg(a, i)) if i < a.size() else default


## The non-empty parts of `s` split at any of `separators`.
static func make_parts(s: String, separators: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	for ch in s:
		if separators.contains(ch):
			out.append(cur)
			cur = ""
		else:
			cur += ch
	out.append(cur)
	if separators == WORD_SEPARATORS:
		return PackedStringArray(Array(out).filter(func(w: String) -> bool: return w != ""))
	return out


## Parts first..last of `s` joined with the first separator ("" when out of range).
static func make_words(s: String, separators: String, first: int, last: int) -> String:
	var parts := make_parts(s, separators)
	if first < 0 or first >= parts.size():
		return ""
	return separators[0].join(parts.slice(first, mini(last, parts.size() - 1) + 1))


static func make_vector(s: String) -> Vector3:
	var p := make_parts(s, WORD_SEPARATORS)
	var v := Vector3.ZERO
	for i in mini(3, p.size()):
		v[i] = float(p[i]) if p[i].is_valid_float() else 0.0
	return v


static func make_vector_string(v: Vector3) -> String:
	return "%s %s %s" % [make_number_string(v.x), make_number_string(v.y), make_number_string(v.z)]


static func make_number_string(x: float) -> String:
	if x == floorf(x) and absf(x) < 1e9:
		return str(int(x))
	return String.num(x, FLOAT_DIGITS)


## The rotation of a transform string "x y z ax ay az angle" (radians), or of an axis-angle "ax ay az angle".
static func make_rotation(s: String) -> Basis:
	var p := make_parts(s, WORD_SEPARATORS)
	var at := 3 if p.size() >= 7 else 0
	if p.size() < at + 4:
		return Basis.IDENTITY
	var axis := Vector3(float(p[at]), float(p[at + 1]), float(p[at + 2]))
	if axis.length() < 1e-6:
		return Basis.IDENTITY
	return Basis(axis.normalized(), float(p[at + 3]))


func _set_word(_n: String, a: Array):
	var parts := Array(make_parts(_s(a, 0), WORD_SEPARATORS))
	var i := int(_f(a, 1))
	while parts.size() <= i:
		parts.append("")
	parts[i] = _s(a, 2)
	return " ".join(parts)


func _remove_word(_n: String, a: Array):
	var parts := Array(make_parts(_s(a, 0), WORD_SEPARATORS))
	var i := int(_f(a, 1))
	if i >= 0 and i < parts.size():
		parts.remove_at(i)
	return " ".join(parts)


func _strip_chars(_n: String, a: Array):
	var s := _s(a, 0)
	for ch in _s(a, 1):
		s = s.replace(ch, "")
	return s


## getRandom(): 0..1; getRandom(max): integer 0..max; getRandom(min, max): integer min..max.
func _get_random(_n: String, a: Array):
	if a.is_empty():
		return randf()
	if a.size() == 1:
		return randi_range(0, int(_f(a, 0)))
	return randi_range(int(_f(a, 0)), int(_f(a, 1)))


func _echo(_n: String, a: Array):
	echoes.append(" ".join(a.map(func(x): return DarkstarScript.to_str(x))))
	return ""
