class_name DarkstarFunctionTable
extends RefCounted
## A game's script-callable engine functions, dispatched by lower-case name: the per-game half of the shared
## Darkstar script runtime (DarkstarScript is the shared half). Starsiege (SSEngineFunctions), Tribes
## (TribesFunctions) and Tribes 2 (Tribes2Functions) each register their own handlers; the string, math and
## vector functions every game shares come from DarkstarStdLib (merged with include()).
## A handler is a Callable(name: String, args: Array) -> Variant.

var _handlers := {}
## The tables include() merged (kept alive: their handlers are bound to them).
var _included: Array[DarkstarFunctionTable] = []


func _on(names: Array, handler: Callable) -> void:
	for n in names:
		_handlers[n] = handler


## Adds every handler of `other` this table does not define itself.
func include(other: DarkstarFunctionTable) -> void:
	_included.append(other)
	_handlers.merge(other._handlers)


func has_function(name: String) -> bool:
	return _handlers.has(name)


## Runs engine function `name` (lower case) with evaluated arguments; null = not an engine function.
func call_function(name: String, a: Array):
	if _handlers.has(name):
		return _handlers[name].call(name, a)
	return null


static func _arg(args: Array, i: int, default = ""):
	return args[i] if i < args.size() else default


func _no_op(_n: String, _a: Array):
	return ""


func _zero(_n: String, _a: Array):
	return 0
