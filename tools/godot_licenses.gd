extends SceneTree
## Writes the license of the Godot build that runs it, the copyright notices of the third-party code built into
## Godot and those components' license texts to the folder given after "--" (run by tools/package_release.ps1):
##   godot --headless --path <empty project dir> --script tools/godot_licenses.gd -- <out dir>
## The texts come from the engine itself (Engine.get_license_text / get_copyright_info / get_license_info), so they
## match the exact Godot version the release was exported with.


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: godot --headless --script tools/godot_licenses.gd -- <out dir>")
		quit(1)
		return
	var out: String = args[0]
	var ok := _write(out.path_join("Godot-LICENSE.txt"), "Godot Engine (MIT License)\n\n" + Engine.get_license_text())
	ok = _write(out.path_join("Godot-THIRD_PARTY.txt"), _make_third_party_text()) and ok
	quit(0 if ok else 1)


func _make_third_party_text() -> String:
	var lines := PackedStringArray(["Third-party components built into the Godot Engine", ""])
	for info in Engine.get_copyright_info():
		lines.append("Component: %s" % info["name"])
		for part in info["parts"]:
			lines.append("  Files: %s" % ", ".join(part["files"]))
			lines.append("  Copyright: %s" % "\n             ".join(part["copyright"]))
			lines.append("  License: %s" % part["license"])
		lines.append("")
	var licenses: Dictionary = Engine.get_license_info()
	for license_name in licenses:
		lines.append("----------------------------------------------------------------")
		lines.append("License: %s\n\n%s\n" % [license_name, licenses[license_name]])
	return "\n".join(lines)


func _write(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("cannot write %s" % path)
		return false
	f.store_string(text)
	return true
