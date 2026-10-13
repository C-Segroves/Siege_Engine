class_name DarkstarFunctions
extends RefCounted
## The script functions a DarkstarScript knows, with TorqueScript's packages: each name has a stack of
## definitions, the base one first; activating a package pushes its functions on top, deactivating takes them
## off again. `active` holds the definition a call runs: lower name -> [params, body].
## A definition is [params, body, package name ("" for none)].

var active := {}
var _stacks := {}             # lower name -> [definitions], base first
var _packages := {}           # lower package -> {lower name: definition}
var _active_packages: Array[String] = []


## A parsed `function` (inside `package` when `package_name` is not ""). A function outside packages replaces
## the base definition; active packages stay on top of it.
func define(name: String, params: Array, body: Array, package_name := "") -> void:
	var def := [params, body, package_name]
	if package_name != "":
		if not _packages.has(package_name):
			_packages[package_name] = {}
		_packages[package_name][name] = def
		if package_name in _active_packages:
			_push(name, def)
		return
	var stack: Array = _stacks.get(name, [])
	if stack.is_empty():
		stack.append(def)
	else:
		stack[0] = def
	_stacks[name] = stack
	_refresh(name)


func _push(name: String, def: Array) -> void:
	var stack: Array = _stacks.get(name, [])
	stack.append(def)
	_stacks[name] = stack
	_refresh(name)


func _refresh(name: String) -> void:
	var stack: Array = _stacks.get(name, [])
	if stack.is_empty():
		active.erase(name)
	else:
		active[name] = [stack.back()[0], stack.back()[1]]


## activatePackage(name): its functions override the current definitions (a package is active once).
func activate(package_name: String) -> void:
	package_name = package_name.to_lower()
	if package_name in _active_packages or not _packages.has(package_name):
		return
	_active_packages.append(package_name)
	for fn in _packages[package_name]:
		_push(fn, _packages[package_name][fn])


func deactivate(package_name: String) -> void:
	package_name = package_name.to_lower()
	if not package_name in _active_packages:
		return
	_active_packages.erase(package_name)
	for fn in _packages[package_name]:
		_stacks[fn] = (_stacks.get(fn, []) as Array).filter(func(d: Array) -> bool: return d[2] != package_name)
		_refresh(fn)


func is_active_package(package_name: String) -> bool:
	return package_name.to_lower() in _active_packages


func has_package(package_name: String) -> bool:
	return _packages.has(package_name.to_lower())


## The stack level of the definition a call of `name` runs (-1 when `name` has no stack).
func top_level(name: String) -> int:
	return (_stacks.get(name, []) as Array).size() - 1


## Definition `level` of `name` ([] when there is none).
func definition(name: String, level: int) -> Array:
	var stack: Array = _stacks.get(name, [])
	return stack[level] if level >= 0 and level < stack.size() else []
