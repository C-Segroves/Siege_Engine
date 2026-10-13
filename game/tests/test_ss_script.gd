extends SceneTree
## Headless check of the Starsiege script interpreter:
##   godot --headless --path game --script res://tests/test_ss_script.gd [-- <gamedata dir>]
## Parses every exported Starsiege script (missions/*.cs, scripts/*.cs) and runs a few evaluator tests.

const SS := preload("res://games/starsiege/ss_script.gd")


class Host:
	var log := []
	func ss_builtin(name: String, args: Array):
		log.append([name, args])
		if name == "echo":
			return ""
		return null


func _init() -> void:
	var root := "res://../gamedata/starsiege"
	for a in OS.get_cmdline_user_args():
		root = a
	var fails := 0
	# evaluator unit tests
	var vm = SS.new()
	var h := Host.new()
	vm.host = h
	vm.load_source("""
		function f(%a, %b) { return %a + %b * 2; }
		function g(%x) { if(%x == boundary) return 1; else if(%x == patrol) return 2; return 3; }
		function loop() { %s = 0; for(%i = 0; %i < 5; %i++) { if(%i == 3) continue; %s += %i; } while(%s > 0) { %s--; if(%s == 4) break; } return %s; }
		$a = f(1, 2) @ "x";
		$b = g(patrol);
		$c = loop();
		$obj.count = 2; $obj.count--; $arr[1] = 7; $d = $arr[1] + $obj.count;
		Pilot Mary { id = 28; name = Mary; skill = 0.7; };
		$e = Mary.skill;
		$f = !false && (1 < 2) || 0;
		$g = -3 / 2;
	""", "unit")
	var expect := {"a": "5x", "b": 2, "c": 4, "d": 8, "e": 0.7, "f": 1, "g": -1.5}
	for k in expect:
		var got = vm.globals.get(k)
		if str(got) != str(expect[k]):
			print("FAIL %s = %s (want %s)" % [k, got, expect[k]])
			fails += 1
	for e in vm.errors:
		print("unit error: ", e)
		fails += 1
	# parse every exported script
	var n := 0
	var nerr := 0
	for sub in ["missions", "scripts"]:
		var dir := root.path_join(sub)
		var d := DirAccess.open(dir)
		if d == null:
			print("no dir ", dir)
			continue
		for f in d.get_files():
			if not f.to_lower().ends_with(".cs"):
				continue
			var src := FileAccess.get_file_as_string(dir.path_join(f))
			var p = SS.new()
			p.parse(src, f)
			n += 1
			if not p.errors.is_empty():
				nerr += 1
				for e in p.errors.slice(0, 5):
					print("  ", e)
			if p.functions.is_empty() and f.begins_with("H"):
				print("  no functions in ", f)
	print("parsed %d scripts, %d with errors, unit fails %d" % [n, nerr, fails])
	quit(1 if fails > 0 or nerr > 0 else 0)
