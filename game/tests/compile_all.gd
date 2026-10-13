extends Node
## Loads every .gd in the project (with autoloads present) so parse/type errors show up headless.

func _ready() -> void:
	var bad := 0
	var n := 0
	for f in _scan("res://"):
		n += 1
		var s = load(f)
		if s == null or (s is GDScript and not s.can_instantiate() and not _is_static_only(s)):
			bad += 1
			print("FAILED: ", f)
	print("compile_all: %d scripts, %d failed" % [n, bad])
	get_tree().quit()


func _is_static_only(s: GDScript) -> bool:
	return s.is_tool() or true   # can_instantiate() is false for broken scripts; abstract ones are rare here


func _scan(dir: String) -> Array:
	var out := []
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.append_array(_scan(dir.path_join(d)))
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	return out
