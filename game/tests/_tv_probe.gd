extends Node
func _ready() -> void:
	Assets.refresh()
	Assets.data_root = "C:/tvs2/data"
	Packs.reload()
	for id in ["tribes_v:arenaobjects__rampsupport", "tribes_v:cityinfrastructure__piped1024", "tribes_v:tv_phoenixlight"]:
		var inst := ShapeInstance.new()
		add_child(inst)
		inst.build(Assets.shape(id), 0, "WORLD0")
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := -lo
		for mi in inst.find_children("*", "MeshInstance3D", true, false):
			var aabb: AABB = (mi as MeshInstance3D).mesh.get_aabb()
			var xf: Transform3D = (mi as MeshInstance3D).global_transform
			for c in 8:
				var p := xf * (aabb.position + aabb.size * Vector3(c & 1, (c >> 1) & 1, (c >> 2) & 1))
				lo = lo.min(p)
				hi = hi.max(p)
		print(id, " godot extent ", hi - lo)
	get_tree().quit()
