class_name DarkstarExpressionParser
extends RefCounted
## The expression half of the Darkstar-family parser (DarkstarParser adds the statements): token access over
## DarkstarLexer tokens and the expression trees ("k" constant, "l"/"g" variable, "f" field, "call", "mcall"
## method call, "tag", "un", "and", "or", "bin", "tern", "asg", "inc", "new" object creation).
## Precedence (low -> high): assignment, ?: (TorqueScript), ||, &&, the binary levels, unary, postfix.
## Object creation: `instant Type "name" { fields; nested instant objects };` (Tribes missions, both dialects) and
## TorqueScript's `new Class(name) { fields; nested new }` / `datablock Class(name) [: parent] { ... }`, as
## ["new", class expr, name expr, parent name or null, [[field, index parts or null, expr]], [child nodes],
## datablock?].

const ASSIGN_OPS := ["=", "+=", "-=", "*=", "/="]
const TORQUE_ASSIGN_OPS := ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]
## Binary operator levels between && and the unary operators, loosest first (each left-associative); the bit
## operators | ^ & are Tribes' (type masks: $SimPlayerObjectType|$VehicleObjectType).
const BINARY_LEVELS := [["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["@"], ["+", "-"], ["*", "/", "%"]]
## TorqueScript levels (CMDgram.y precedence); SPC / TAB / NL are identifiers turned into operators.
const TORQUE_BINARY_LEVELS := [["|"], ["^"], ["&"], ["==", "!=", "$=", "!$="], ["<", ">", "<=", ">="],
	["@", "SPC", "TAB", "NL"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]
const CONCAT_WORDS := ["SPC", "TAB", "NL"]

var vm: DarkstarScript
var _t: Array = []
var _p := 0
var _src_name := ""
var _torque := false


func _init(interpreter: DarkstarScript) -> void:
	vm = interpreter
	_torque = interpreter.dialect == DarkstarLexer.Dialect.TORQUE


# ------------------------------------------------------------------ token access

func _peek(o := 0) -> Array:
	return _t[mini(_p + o, _t.size() - 1)]


func _is(v: String, o := 0) -> bool:
	var t: Array = _peek(o)
	return t[0] == "p" and t[1] == v


func _is_kw(v: String, o := 0) -> bool:
	var t: Array = _peek(o)
	return t[0] == "i" and String(t[1]).to_lower() == v


func _next() -> Array:
	var t: Array = _t[_p]
	_p = mini(_p + 1, _t.size() - 1)
	return t


func _skip(v: String) -> void:
	if _is(v):
		_next()


## Consumes `v`; otherwise records an error and skips one token to recover.
func _expect(v: String) -> void:
	if _is(v):
		_next()
		return
	_err("expected '%s' got '%s'" % [v, str(_peek()[1])])
	if _peek()[0] != "e":
		_next()


func _err(msg: String) -> void:
	vm.errors.append("%s:%d: %s" % [_src_name, int(_peek()[2]), msg])


# ------------------------------------------------------------------ expressions

func _expr():
	return _assign()


func _assign():
	var lhs = _ternary() if _torque else _or()
	var ops := TORQUE_ASSIGN_OPS if _torque else ASSIGN_OPS
	if _peek()[0] == "p" and String(_peek()[1]) in ops:
		var op := String(_next()[1])
		return ["asg", lhs, op, _assign()]
	return lhs


func _ternary():
	var c = _or()
	if not _is("?"):
		return c
	_next()
	var a = _assign()
	_expect(":")
	return ["tern", c, a, _assign()]


func _or():
	var a = _and()
	while _is("||"):
		_next()
		a = ["or", a, _and()]
	return a


func _and():
	var a = _binary_level(0)
	while _is("&&"):
		_next()
		a = ["and", a, _binary_level(0)]
	return a


func _binary_level(level: int):
	var levels := TORQUE_BINARY_LEVELS if _torque else BINARY_LEVELS
	if level >= levels.size():
		return _unary()
	var a = _binary_level(level + 1)
	while _is_binary_op(levels[level]):
		var op := String(_next()[1])
		a = ["bin", op, a, _binary_level(level + 1)]
	return a


func _is_binary_op(ops: Array) -> bool:
	var t: Array = _peek()
	if t[0] == "p":
		return String(t[1]) in ops
	return _torque and t[0] == "i" and String(t[1]) in CONCAT_WORDS and String(t[1]) in ops


func _unary():
	if _is("!"):
		_next()
		return ["un", "!", _unary()]
	if _is("-"):
		_next()
		return ["un", "-", _unary()]
	if _torque and _is("~"):
		_next()
		return ["un", "~", _unary()]
	if _is("*"):
		_next()
		return ["tag", _unary()]
	if _is("++") or _is("--"):
		var op := String(_next()[1])
		return ["inc", _unary(), 1 if op == "++" else -1, true]
	return _postfix()


func _postfix():
	var e = _primary()
	while true:
		if _is("."):
			_next()
			var f := String(_next()[1]).to_lower()
			if _torque and _is("("):
				e = ["mcall", e, f, _call_args()]
				continue
			var idx = null
			if _is("["):
				_next()
				idx = _index_list()
			e = ["f", e, f, idx]
		elif _is("++") or _is("--"):
			var op := String(_next()[1])
			e = ["inc", e, 1 if op == "++" else -1, false]
		else:
			break
	return e


## a[b, c] -> concatenation "b_c" (Darkstar joins multiple indices with _)
func _index_list():
	var parts := [_expr()]
	while _is(","):
		_next()
		parts.append(_expr())
	_expect("]")
	return parts


func _primary():
	var t: Array = _next()
	match t[0]:
		"n", "s":
			return ["k", t[1]]
		"l", "g":
			var idx = null
			if _is("["):
				_next()
				idx = _index_list()
			return [t[0], t[1], idx]
		"i":
			if _torque and String(t[1]).to_lower() == "new":
				_p -= 1
				return _new_object(false)
			return _call_or_word(String(t[1]))
		"p":
			if t[1] == "(":
				var e = _expr()
				_expect(")")
				return e
	_err("unexpected '%s'" % str(t[1]))
	return ["k", ""]


## name(args) is a call; true/false are 1/0; any other bare word is a string.
func _call_or_word(name: String):
	if _is("("):
		return ["call", name.to_lower(), _call_args()]
	match name.to_lower():
		"true":
			return ["k", 1]
		"false":
			return ["k", 0]
	return ["k", name]


func _call_args() -> Array:
	_next()  # (
	var args := []
	while not _is(")") and _peek()[0] != "e":
		args.append(_expr())
		if _is(","):
			_next()
		elif not _is(")"):
			break
	_expect(")")
	return args


# ------------------------------------------------------------------ object creation

## `instant Type "name" { fields; nested instant objects };` or `instant Type "name";` -> a "new" node.
func _instant_object() -> Array:
	_next()  # instant
	var cls := String(_next()[1])
	var name_expr = ["k", ""]
	if _peek()[0] == "s" or _peek()[0] == "i":
		name_expr = ["k", String(_next()[1])]
	var body := {"fields": [], "children": []}
	if _is("{"):
		body = _object_body()
	_skip(";")
	return ["new", ["k", cls], name_expr, null, body.fields, body.children, false]


## `new Class(name) { ... }` / `datablock Class(name) [: parent] { ... }`.
func _new_object(datablock: bool) -> Array:
	_next()  # new / datablock
	var cls_expr = ["k", String(_next()[1])] if _peek()[0] == "i" else _primary()
	var name_expr = ["k", ""]
	if _is("("):
		_next()
		if not _is(")"):
			name_expr = _expr()
		_expect(")")
	var parent = null
	if _is(":"):
		_next()
		parent = String(_next()[1])
	var body := {"fields": [], "children": []}
	if _is("{"):
		body = _object_body()
	return ["new", cls_expr, name_expr, parent, body.fields, body.children, datablock]


## `{ name[idx] = expr; ... new/instant children ...; }`
func _object_body() -> Dictionary:
	var fields := []
	var children := []
	_expect("{")
	while not _is("}") and _peek()[0] != "e":
		var before := _p
		if _is_kw("new") or _is_kw("instant"):
			children.append(_new_object(false) if _is_kw("new") else _instant_object())
			_skip(";")
		elif _peek()[0] == "i":
			_object_field(fields)
		else:
			_next()
		if _p == before:
			_next()
	_expect("}")
	return {"fields": fields, "children": children}


func _object_field(fields: Array) -> void:
	var f := String(_next()[1]).to_lower()
	var idx = null
	if _is("["):
		_next()
		idx = _index_list()
	if _is("="):
		_next()
		fields.append([f, idx, _expr()])
	_skip(";")
