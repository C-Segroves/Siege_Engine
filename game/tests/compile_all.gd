extends Node
## Loads every .gd in the project (with autoloads present) so parse / type errors show up headless; exit code 1 when
## any fails. A class_name the global class list does not have yet (a class added without re-importing) is reported:
## every script that uses it fails to parse until `--import` runs.

const IMPORT_HINT := "run Godot with --headless --path game --import first"


func _ready() -> void:
	var files := _scan("res://")
	var failed := 0
	for f in files:
		var s = load(f)
		if not (s is GDScript) or not (s as GDScript).can_instantiate():
			failed += 1
			print("FAILED: ", f)
	var unregistered := make_unregistered_classes(files)
	for line in unregistered:
		print("UNREGISTERED CLASS: %s - %s" % [line, IMPORT_HINT])
	print("compile_all: %d scripts, %d failed, %d unregistered class_name" % [files.size(), failed, unregistered.size()])
	get_tree().quit(1 if failed > 0 or not unregistered.is_empty() else 0)


## "<ClassName> (<path>)" of every class_name declared in `files` that the global class list does not know.
static func make_unregistered_classes(files: Array) -> Array:
	var known := {}
	for c in ProjectSettings.get_global_class_list():
		known[str(c.get("class", ""))] = true
	var re := RegEx.create_from_string(r"(?m)^class_name\s+(\w+)")
	var out := []
	for f in files:
		var m: RegExMatch = re.search(FileAccess.get_file_as_string(f))
		if m != null and not known.has(m.get_string(1)):
			out.append("%s (%s)" % [m.get_string(1), f])
	return out


func _scan(dir: String) -> Array:
	var out := []
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.append_array(_scan(dir.path_join(d)))
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	return out
