class_name DarkstarParser
extends DarkstarExpressionParser
## Recursive-descent parser for Darkstar-family scripts (tokens from DarkstarLexer; expressions:
## DarkstarExpressionParser). Produces statement lists (Arrays tagged "expr", "if", "while", "for", "do", "sw",
## "ret", "brk", "cont", "blk"). Function definitions and object declarations are handed to the interpreter
## (DarkstarScript) as they are parsed, so declarations see the functions defined above them.
##
## Both dialects: `Type name { field = value; };` declarations (Starsiege) and `instant` object trees (Tribes
## missions). TORQUE dialect (Tribes 2) adds `datablock Class(name) [: parent] { ... };`, `package name
## { functions };`, `switch` / `switch$`, `do ... while`.

## Guard against a parser that stops advancing on malformed input.
const MAX_TOP_LEVEL_STATEMENTS := 200000

var _package := ""


## Parses source text; returns the top-level statement list (functions/objects are registered).
func parse(src: String, name := "script") -> Array:
	_t = DarkstarLexer.tokenize(src, vm.dialect)
	_p = 0
	_src_name = name
	var out := []
	var guard := 0
	while _peek()[0] != "e":
		var before := _p
		var s = _statement()
		if s != null:
			out.append(s)
		if _p == before:
			_next()
		guard += 1
		if guard > MAX_TOP_LEVEL_STATEMENTS:
			break
	return out


# ------------------------------------------------------------------ statements

func _statement():
	var t: Array = _peek()
	if t[0] == "p":
		if t[1] == ";":
			_next()
			return null
		if t[1] == "{":
			return ["blk", _block()]
	if t[0] == "i":
		var at := _p
		var s = _keyword_statement(String(t[1]).to_lower())
		if s != null or _p != at:   # a statement, or a declaration it consumed
			return s
	var e = _expr()
	_skip(";")
	return ["expr", e]


## The statement keyword `kw` starts (null when it starts none: an expression follows).
func _keyword_statement(kw: String):
	match kw:
		"function":
			_function()
			return null
		"if":
			return _if_statement()
		"while":
			return _while_statement()
		"for":
			return _for_statement()
		"return":
			_next()
			var e = null if _is(";") else _expr()
			_skip(";")
			return ["ret", e]
		"break":
			_next()
			_skip(";")
			return ["brk"]
		"continue":
			_next()
			_skip(";")
			return ["cont"]
		"instant":
			if _peek(1)[0] == "i":
				return ["expr", _instant_object()]
	if _torque:
		return _torque_statement(kw)
	if _is_object_declaration():
		_object_decl()
	return null


## TorqueScript-only statements; null when `kw` starts none of them.
func _torque_statement(kw: String):
	match kw:
		"package":
			if _peek(1)[0] == "i":
				_package_decl()
				return ["blk", []]
		"datablock":
			if _peek(1)[0] == "i":
				var e := _new_object(true)
				_skip(";")
				return ["expr", e]
		"switch", "switch$":
			return _switch_statement()
		"do":
			return _do_statement()
	return null


## `Type name { ... };`
func _is_object_declaration() -> bool:
	var t1: Array = _peek(1)
	var t2: Array = _peek(2)
	return t1[0] == "i" and t2[0] == "p" and t2[1] == "{"


func _if_statement() -> Array:
	_next()
	_expect("(")
	var c = _expr()
	_expect(")")
	var th = _body()
	var el = null
	if _is_kw("else"):
		_next()
		el = _body()
	return ["if", c, th, el]


func _while_statement() -> Array:
	_next()
	_expect("(")
	var c = _expr()
	_expect(")")
	return ["while", c, _body()]


func _for_statement() -> Array:
	_next()
	_expect("(")
	var a = null if _is(";") else _expr()
	_expect(";")
	var c = null if _is(";") else _expr()
	_expect(";")
	var s = null if _is(")") else _expr()
	_expect(")")
	return ["for", a, c, s, _body()]


## `do body while (cond);`
func _do_statement() -> Array:
	_next()
	var body := _body()
	if _is_kw("while"):
		_next()
	_expect("(")
	var c = _expr()
	_expect(")")
	_skip(";")
	return ["do", body, c]


## ["sw", subject, string compare, [[values], body]..., default body or null]; `case a or b:` lists values.
func _switch_statement() -> Array:
	var strings := String(_next()[1]).to_lower() == "switch$"
	_expect("(")
	var subject = _expr()
	_expect(")")
	_expect("{")
	var cases := []
	var default_body = null
	while not _is("}") and _peek()[0] != "e":
		if _is_kw("case"):
			_next()
			var values := [_expr()]
			while _is_kw("or"):
				_next()
				values.append(_expr())
			_expect(":")
			cases.append([values, _case_body()])
		elif _is_kw("default"):
			_next()
			_expect(":")
			default_body = _case_body()
		else:
			_err("expected case got '%s'" % str(_peek()[1]))
			_next()
	_expect("}")
	return ["sw", subject, strings, cases, default_body]


func _case_body() -> Array:
	var out := []
	while not _is("}") and not _is_kw("case") and not _is_kw("default") and _peek()[0] != "e":
		var before := _p
		var s = _statement()
		if s != null:
			out.append(s)
		if _p == before:
			_next()
	return out


func _body() -> Array:
	if _is("{"):
		return _block()
	var s = _statement()
	return [s] if s != null else []


func _block() -> Array:
	_expect("{")
	var out := []
	while not _is("}") and _peek()[0] != "e":
		var before := _p
		var s = _statement()
		if s != null:
			out.append(s)
		if _p == before:
			_next()
	_expect("}")
	return out


# ------------------------------------------------------------------ declarations

func _function() -> void:
	_next()  # function
	var name := String(_next()[1]).to_lower()
	while _is(":"):   # tolerate typos like `patrolA::vehicle:onAttacked`
		_next()
		_skip(":")
		name += "::" + String(_next()[1]).to_lower()
	var params: Array[String] = []
	_expect("(")
	while not _is(")") and _peek()[0] != "e":
		var t: Array = _next()
		if t[0] == "l":
			params.append(String(t[1]))
		_skip(",")
	_expect(")")
	vm.define_function(name, params, _block(), _package)


## `package name { function ... };`: the functions belong to the package until it is activated.
func _package_decl() -> void:
	_next()
	_package = String(_next()[1]).to_lower()
	_expect("{")
	while not _is("}") and _peek()[0] != "e":
		var before := _p
		if _is_kw("function"):
			_function()
		else:
			_statement()
		if _p == before:
			_next()
	_expect("}")
	_skip(";")
	_package = ""


## Object declaration: fields hold ["__expr", expression] until the interpreter evaluates them.
func _object_decl() -> void:
	var typ := String(_next()[1])
	var nm := String(_next()[1])
	_expect("{")
	var obj := {"__type": typ, "__name": nm}
	while not _is("}") and _peek()[0] != "e":
		var before := _p
		if _peek()[0] == "i":
			var f := String(_next()[1]).to_lower()
			if _is("="):
				_next()
				obj[f] = ["__expr", _expr()]
			_skip(";")
		else:
			_next()
		if _p == before:
			_next()
	_expect("}")
	_skip(";")
	vm.declare_object(typ, nm, obj)
