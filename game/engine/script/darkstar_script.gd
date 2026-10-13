class_name DarkstarScript
extends RefCounted
## Interpreter for Darkstar-family scripts (.cs): Starsiege and Tribes (Darkstar, 1998-99) and Tribes 2
## (TorqueScript, 2001). A tree-walking evaluator over the statements DarkstarParser builds from DarkstarLexer
## tokens. Scripts are run as written; every engine function is the game's: the host object supplies them
## (each game has its own function table, see DarkstarFunctionTable). Value rules: DarkstarValues; the
## script functions and TorqueScript packages: DarkstarFunctions.
##
## Host interface (all optional except ss_builtin):
##   ss_builtin(name_lower, args) -> Variant      engine function; null = "not a builtin"
##   ss_resolve(value) -> int                      object id of a name / path (0 = none)
##   ss_get_field(key, field) / ss_field_changed(key, field, value)   live object fields
##   ss_declared(type, name, fields)               a Starsiege-style `Type name { }` declaration
##   ss_new_object(spec) -> id                     `new` / `datablock` / `instant`: spec = {class, name,
##                                                 fields, parent (group id or 0), datablock (bool), copy_of}
##   ss_namespaces(key) -> Array[String]            method lookup order of an object (lower case)
##   ss_method(key, name, args) -> Variant          engine method of an object; null = none
##
## Language (as used by the shipped scripts): `function a::b::c(%x, %y) { ... }`, `%local`, `$global`
## (names may contain ::), `$a[%i]` / `%o.f[%i]` (index = name concatenation), fields `expr.name`,
## if/else, while, for, return, break, continue, operators ! - * / % + - @ < > <= >= == != && || = += -=
## *= /= ++ --, `*TAG` / `*(expr)` string-table lookup, bare words are strings, `true`/`false` = 1/0,
## comments // and # (to end of line), object declarations `Type name { field = value; ... };`.
## Comparisons are numeric when both sides look numeric, otherwise case-insensitive string compares (needed by
## `%arg == boundary` style tests).
## The TORQUE dialect (DarkstarParser) adds packages (activatePackage / deactivatePackage), parent::,
## method calls through the object's namespaces, `new` objects, switch, ?:, bit operators, $= / !$=,
## SPC / TAB / NL; numbers read the leading number of a string and == compares numerically; a function that
## ends without `return` yields its last expression's value.

const MAX_DEPTH := 200
## Iteration cap of while / for loops (runaway scripts).
const MAX_LOOP_ITERATIONS := 100000
## Kept for callers of the old single-file interpreter.
const OPS2 := DarkstarLexer.OPS2
## Language-level functions of the TORQUE dialect (handled before the host).
const TORQUE_LANGUAGE := ["activatepackage", "deactivatepackage", "ispackage", "isfunction", "call", "eval"]

var host: Object = null
var dialect := DarkstarLexer.Dialect.DARKSTAR
var definitions := DarkstarFunctions.new()
var functions := definitions.active   # lower name -> [params(Array[String]), body(Array)]: the active definition
var globals := {}            # lower name -> value
var objects := {}            # declared/named objects: lower name -> {"__type": t, field: value}
var fields := {}             # object key (id or lower name) -> {field: value}
var strings := {}            # TAG -> text
var errors: Array[String] = []
var warned := {}
## Namespace links for parent:: (lower namespace -> lower parent namespace), filled by the host
## (e.g. "singleplayergame" -> "defaultgame", a datablock's name -> its class).
var namespace_parents := {}
var _depth := 0
var _ret = null
## The value of the last expression statement: a TorqueScript function that ends without `return` yields it
## (SinglePlayerGame::pickPlayerSpawn hands on pickTeamSpawn's transform this way).
var _last_value = ""
var _frames := []            # [function name, definition level] of the running script functions


static func tokenize(src: String) -> Array:
	return DarkstarLexer.tokenize(src)


func _is_torque() -> bool:
	return dialect == DarkstarLexer.Dialect.TORQUE


## Parses source text; returns the top-level statement list (functions/objects are registered).
func parse(src: String, name := "script") -> Array:
	return DarkstarParser.new(self).parse(src, name)


## Loads a script: registers functions/objects and runs top-level statements.
func load_source(src: String, name := "script") -> void:
	exec_block(parse(src, name), {})


## Registers a parsed object declaration: its field expressions are evaluated now (constants,
## tags, string concatenations) and the host is told about it.
func declare_object(typ: String, nm: String, obj: Dictionary) -> void:
	var key := nm.to_lower()
	var fl := {}
	for f in obj:
		var v = obj[f]
		fl[f] = eval(v[1], {}) if v is Array and v.size() == 2 and v[0] == "__expr" else v
	objects[key] = fl
	if not fields.has(key):
		fields[key] = {}
	for f in fl:
		fields[key][f] = fl[f]
	if host and host.has_method("ss_declared"):
		host.ss_declared(typ, nm, fl)


## A parsed `function` (see DarkstarFunctions.define).
func define_function(name: String, params: Array, body: Array, package_name := "") -> void:
	definitions.define(name, params, body, package_name)


func activate_package(package_name: String) -> void:
	definitions.activate(package_name)


func deactivate_package(package_name: String) -> void:
	definitions.deactivate(package_name)


func is_package_active(package_name: String) -> bool:
	return definitions.is_active_package(package_name)


# ------------------------------------------------------------------ statements

enum Flow { NORMAL, RETURN, BREAK, CONTINUE }


func exec_block(stmts: Array, locals: Dictionary) -> int:
	for s in stmts:
		var f := exec(s, locals)
		if f != Flow.NORMAL:
			return f
	return Flow.NORMAL


func exec(s: Array, locals: Dictionary) -> int:
	match s[0]:
		"expr":
			_last_value = eval(s[1], locals)
		"if":
			if truthy(eval(s[1], locals)):
				return exec_block(s[2], locals)
			elif s[3] != null:
				return exec_block(s[3], locals)
		"while":
			return _exec_while(s, locals)
		"for":
			return _exec_for(s, locals)
		"do":
			return _exec_do(s, locals)
		"sw":
			return _exec_switch(s, locals)
		"ret":
			_ret = eval(s[1], locals) if s[1] != null else ""
			return Flow.RETURN
		"brk":
			return Flow.BREAK
		"cont":
			return Flow.CONTINUE
		"blk":
			return exec_block(s[1], locals)
	return Flow.NORMAL


## ["while", cond, body]
func _exec_while(s: Array, locals: Dictionary) -> int:
	var n := 0
	while truthy(eval(s[1], locals)):
		var f := exec_block(s[2], locals)
		if f == Flow.BREAK:
			break
		if f == Flow.RETURN:
			return f
		n += 1
		if n > MAX_LOOP_ITERATIONS:
			errors.append("while loop limit")
			break
	return Flow.NORMAL


## ["for", init, cond, step, body]
func _exec_for(s: Array, locals: Dictionary) -> int:
	if s[1] != null:
		eval(s[1], locals)
	var n := 0
	while s[2] == null or truthy(eval(s[2], locals)):
		var f := exec_block(s[4], locals)
		if f == Flow.BREAK:
			break
		if f == Flow.RETURN:
			return f
		if s[3] != null:
			eval(s[3], locals)
		n += 1
		if n > MAX_LOOP_ITERATIONS:
			errors.append("for loop limit")
			break
	return Flow.NORMAL


## ["do", body, cond]
func _exec_do(s: Array, locals: Dictionary) -> int:
	var n := 0
	while true:
		var f := exec_block(s[1], locals)
		if f == Flow.BREAK:
			break
		if f == Flow.RETURN:
			return f
		n += 1
		if not truthy(eval(s[2], locals)) or n > MAX_LOOP_ITERATIONS:
			break
	return Flow.NORMAL


## ["sw", subject, string compare, [[values], body]..., default]: the first case holding the subject runs
## (no fall-through; break inside a case leaves the enclosing loop, as TorqueScript's if-chain does).
func _exec_switch(s: Array, locals: Dictionary) -> int:
	var subject = eval(s[1], locals)
	for c in s[3]:
		for v in c[0]:
			var value = eval(v, locals)
			var hit := to_str(subject).to_lower() == to_str(value).to_lower() if s[2] else is_equal_approx(num(subject), num(value))
			if hit:
				return exec_block(c[1], locals)
	if s[4] != null:
		return exec_block(s[4], locals)
	return Flow.NORMAL


# ------------------------------------------------------------------ expressions

func eval(e, locals: Dictionary):
	if not e is Array:
		return e
	match e[0]:
		"k":
			return e[1]
		"l":
			return locals.get(_var_name(e, locals), "")
		"g":
			return globals.get(_var_name(e, locals), "")
		"f":
			var o = eval(e[1], locals)
			return get_field(o, _field_name(e, locals))
		"call":
			return call_fn(e[1], _eval_args(e[2], locals))
		"mcall":
			return call_method(eval(e[1], locals), e[2], _eval_args(e[3], locals))
		"tag":
			var v = eval(e[1], locals)
			return tag(v)
		"un":
			return _eval_unary(e, locals)
		"and":
			return 1 if truthy(eval(e[1], locals)) and truthy(eval(e[2], locals)) else 0
		"or":
			return 1 if truthy(eval(e[1], locals)) or truthy(eval(e[2], locals)) else 0
		"tern":
			return eval(e[2], locals) if truthy(eval(e[1], locals)) else eval(e[3], locals)
		"bin":
			return binop(e[1], eval(e[2], locals), eval(e[3], locals))
		"asg":
			return _eval_assignment(e, locals)
		"inc":
			return _eval_increment(e, locals)
		"new":
			return _eval_new(e, locals, 0)
	return ""


func _eval_args(arg_exprs: Array, locals: Dictionary) -> Array:
	var args := []
	for a in arg_exprs:
		args.append(eval(a, locals))
	return args


func _eval_unary(e: Array, locals: Dictionary):
	var v = eval(e[2], locals)
	if e[1] == "!":
		return 0 if truthy(v) else 1
	if e[1] == "~":
		return ~int(num(v)) & 0xffffffff
	return -num(v)


## ["asg", lvalue, op, rhs]: = or a compound (+= -= *= /= ...) assignment; yields the stored value.
func _eval_assignment(e: Array, locals: Dictionary):
	var v = eval(e[3], locals)
	if e[2] != "=":
		v = binop(String(e[2]).left(-1), eval(e[1], locals), v)
	assign(e[1], v, locals)
	return v


## ["inc", lvalue, +1/-1, prefix]: prefix yields the new value, postfix the old one.
func _eval_increment(e: Array, locals: Dictionary):
	var old = eval(e[1], locals)
	var nv = num(old) + e[2]
	assign(e[1], _clean(nv), locals)
	return _clean(nv) if e[3] else old


## ["new", class, name, parent name, fields, children, datablock]: the host creates the object (in group
## `group`), then its children inside it; yields the new object's id.
func _eval_new(e: Array, locals: Dictionary, group: int):
	var spec := {"class": to_str(eval(e[1], locals)), "name": to_str(eval(e[2], locals)), "parent": group,
		"datablock": e[6], "copy_of": e[3] if e[3] != null else "", "fields": {}}
	for f in e[4]:
		var nm := String(f[0]) + (_index_str(f[1], locals) if f[1] != null else "")
		spec.fields[nm] = eval(f[2], locals)
	if host == null or not host.has_method("ss_new_object"):
		return 0
	var id = host.ss_new_object(spec)
	for c in e[5]:
		_eval_new(c, locals, int(id))
	return id


func _var_name(e: Array, locals: Dictionary) -> String:
	var nm := String(e[1])
	if e.size() > 2 and e[2] != null:
		nm += _index_str(e[2], locals)
	return nm


func _field_name(e: Array, locals: Dictionary) -> String:
	var nm := String(e[2])
	if e[3] != null:
		nm += _index_str(e[3], locals)
	return nm


func _index_str(parts: Array, locals: Dictionary) -> String:
	var s := ""
	for i in parts.size():
		if i > 0:
			s += "_"
		s += to_str(eval(parts[i], locals)).to_lower()
	return s


func assign(lv, v, locals: Dictionary) -> void:
	if not lv is Array:
		return
	match lv[0]:
		"l":
			locals[_var_name(lv, locals)] = v
		"g":
			globals[_var_name(lv, locals)] = v
		"f":
			set_field(eval(lv[1], locals), _field_name(lv, locals), v)
		_:
			pass


# ------------------------------------------------------------------ objects and fields

func obj_key(o) -> String:
	if o is float or o is int:
		return str(int(o))
	var s := String(o)
	if s.is_valid_float():
		return str(int(float(s)))
	if host and host.has_method("ss_resolve"):
		var id = host.ss_resolve(s)
		if id is int and id > 0:
			return str(id)
	return s.to_lower()


func get_field(o, f: String):
	var k := obj_key(o)
	if host and host.has_method("ss_get_field"):
		var hv = host.ss_get_field(k, f)
		if hv != null:
			return hv
	return fields.get(k, {}).get(f, "")


func set_field(o, f: String, v) -> void:
	var k := obj_key(o)
	if not fields.has(k):
		fields[k] = {}
	fields[k][f] = v
	if host and host.has_method("ss_field_changed"):
		host.ss_field_changed(k, f, v)


# ------------------------------------------------------------------ calls

func call_fn(name: String, args: Array):
	name = name.to_lower()
	if functions.has(name):
		return call_script(name, args)
	if _is_torque():
		if name.begins_with("parent::"):
			return call_parent(name.substr(8), args)
		if name in TORQUE_LANGUAGE:
			return _call_language(name, args)
	if host:
		var r = host.ss_builtin(name, args)
		if r != null:
			return r
	_warn_unknown("unknown function %s()" % name, name)
	return ""


func _warn_unknown(msg: String, key: String) -> void:
	if not warned.has(key):
		warned[key] = true
		errors.append(msg)


func _call_language(name: String, args: Array):
	var a0 := to_str(args[0]) if args.size() > 0 else ""
	match name:
		"activatepackage":
			activate_package(a0)
		"deactivatepackage":
			deactivate_package(a0)
		"ispackage":
			return 1 if definitions.has_package(a0) else 0
		"isfunction":
			return 1 if has_function(a0) else 0
		"call":
			return call_fn(a0, args.slice(1))
		"eval":
			eval_string(a0)
			var r = _ret if _ret != null else ""
			_ret = ""
			return r
	return ""


func has_function(name: String) -> bool:
	return functions.has(name.to_lower())


func call_script(name: String, args: Array):
	name = name.to_lower()
	var level := definitions.top_level(name)
	return _invoke(name, level, definitions.definition(name, level) if level >= 0 else functions[name], args)


## Runs definition `def` ([params, body, ...]) of `name` at package level `level` (-1: not tracked).
func _invoke(name: String, level: int, def: Array, args: Array):
	if _depth > MAX_DEPTH:
		errors.append("call depth exceeded in " + name)
		return ""
	var locals := {}
	var params: Array = def[0]
	for i in params.size():
		locals[params[i]] = args[i] if i < args.size() else ""
	_depth += 1
	_frames.append([name, level])
	_ret = ""
	var outer_last = _last_value
	_last_value = ""
	var f := exec_block(def[1], locals)
	_frames.pop_back()
	_depth -= 1
	var r = _ret if f == Flow.RETURN else ("" if not _is_torque() else _last_value)
	_ret = ""
	_last_value = outer_last
	return r


## `parent::<method>(args)` inside the running function: the definition below it in the package stack, else
## the same method in the parent namespaces (script first, then the host's engine function), else "".
func call_parent(method: String, args: Array):
	if _frames.is_empty():
		return ""
	var fname := String(_frames.back()[0])
	var level := int(_frames.back()[1])
	if level > 0 and fname.get_slice("::", fname.get_slice_count("::") - 1) == method:
		return _invoke(fname, level - 1, definitions.definition(fname, level - 1), args)
	if not fname.contains("::"):
		var r = host.ss_builtin(method, args) if host else null
		return r if r != null else ""
	return _call_in_parent_namespaces(fname.substr(0, fname.rfind("::")), method, args)


func _call_in_parent_namespaces(ns: String, method: String, args: Array):
	var p := String(namespace_parents.get(ns, ""))
	var guard := 0
	while p != "" and guard < MAX_DEPTH:
		var fn := p + "::" + method
		if functions.has(fn):
			return call_script(fn, args)
		var r = host.ss_builtin(fn, args) if host else null
		if r != null:
			return r
		p = String(namespace_parents.get(p, ""))
		guard += 1
	return ""


## `object.method(args)`: the first script function `<namespace>::<method>` along the object's namespaces
## (called with the object as the first argument), else the host's engine method.
func call_method(obj, method: String, args: Array):
	method = method.to_lower()
	var k := obj_key(obj)
	var this = int(k) if k.is_valid_int() else obj
	if host and host.has_method("ss_namespaces"):
		for ns in host.ss_namespaces(k):
			var fn := String(ns) + "::" + method
			if functions.has(fn):
				return call_script(fn, [this] + args)
	if host and host.has_method("ss_method"):
		var r = host.ss_method(k, method, args)
		if r != null:
			return r
	_warn_unknown("unknown method %s.%s()" % [k, method], "." + method)
	return ""


## Runs a code string (schedule(), eval()).
func eval_string(code: String):
	var stmts := parse(code, "schedule")
	return exec_block(stmts, {})


# ------------------------------------------------------------------ values (DarkstarValues)

func tag(v):
	var s := to_str(v)
	if strings.has(s):
		return strings[s]
	var u := s.to_upper()
	return strings.get(u, s)


static func is_num(v) -> bool:
	return DarkstarValues.is_num(v)


static func num(v) -> float:
	return DarkstarValues.num(v)


static func leading_num(v) -> float:
	return DarkstarValues.leading_num(v)


static func truthy(v) -> bool:
	return DarkstarValues.truthy(v)


static func to_str(v) -> String:
	return DarkstarValues.to_str(v)


static func _clean(v: float):
	return DarkstarValues.clean(v)


func _n(v) -> float:
	return leading_num(v) if _is_torque() else num(v)


func binop(op: String, a, b):
	match op:
		"+": return _clean(_n(a) + _n(b))
		"-": return _clean(_n(a) - _n(b))
		"*": return _clean(_n(a) * _n(b))
		"/": return _clean(_n(a) / _n(b)) if _n(b) != 0.0 else 0
		"%": return int(_n(a)) % int(_n(b)) if int(_n(b)) != 0 else 0
		"@": return to_str(a) + to_str(b)
		"==": return 1 if _equal(a, b) else 0
		"!=": return 0 if _equal(a, b) else 1
		"<": return 1 if _n(a) < _n(b) else 0
		">": return 1 if _n(a) > _n(b) else 0
		"<=": return 1 if _n(a) <= _n(b) else 0
		">=": return 1 if _n(a) >= _n(b) else 0
	return DarkstarValues.torque_binop(op, a, b)


func _equal(a, b) -> bool:
	if _is_torque():
		return is_equal_approx(leading_num(a), leading_num(b))
	return _cmp(a, b) == 0


func _cmp(a, b) -> int:
	if (is_num(a) or DarkstarValues.is_boolish(a)) and (is_num(b) or DarkstarValues.is_boolish(b)):
		var x := num(a)
		var y := num(b)
		return 0 if is_equal_approx(x, y) else (-1 if x < y else 1)
	# object names vs ids: compare resolved ids when one side is numeric
	if is_num(a) != is_num(b) and host and host.has_method("ss_resolve"):
		var ra = host.ss_resolve(to_str(b if is_num(a) else a))
		if ra is int and ra > 0:
			return 0 if int(num(a if is_num(a) else b)) == ra else 1
	var sa := to_str(a).to_lower()
	var sb := to_str(b).to_lower()
	return 0 if sa == sb else (-1 if sa < sb else 1)
