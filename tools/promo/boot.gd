extends SceneTree
## Loads the node script named by --driver=<abs path> once the autoloads exist, and runs it.
func _initialize() -> void:
	_start.call_deferred()

func _start() -> void:
	var path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--driver="):
			path = a.substr(9)
	var node: Node = load(path).new()
	root.add_child(node)
