extends Node
## Texture memory of the unified bake: builds every shape of a pack with render_unified forced on and prints the
## Texture2DArray bytes. ES2 / BD bake 32 light levels per texture (docs/RENDER_UNIFICATION.md section 6).
##   RU_PACKS=es2,bd,es1 godot --audio-driver Dummy --path game res://tests/render_unified_memory_check.tscn
const DEFAULT_PACKS := "es1,es2,bd"
const BUDGET_MB := {"es1": 64.0, "es2": 256.0, "bd": 128.0}


func _ready() -> void:
	RenderUnified.force = true
	var failures := 0
	var packs := OS.get_environment("RU_PACKS")
	for pack in (packs if packs != "" else DEFAULT_PACKS).split(","):
		UnifiedMaterial.stats = {"arrays": 0, "bytes": 0}
		var n := 0
		for f in DirAccess.get_files_at(Assets.path("shapes", pack)):
			if not f.ends_with(".json") or f.begins_with("_"):
				continue
			var shape := Assets.shape("%s:%s" % [pack, f.get_basename()])
			if shape.is_empty():
				continue
			var inst := ShapeInstance.new()
			add_child(inst)
			inst.build(shape, 0, "%s:WORLD0" % pack if pack != "bd" else "bd:NRMPAL")
			inst.queue_free()
			n += 1
		var mb := float(UnifiedMaterial.stats.bytes) / 1048576.0
		print("%s: %d shapes, %d texture arrays, %.1f MB" % [pack, n, UnifiedMaterial.stats.arrays, mb])
		if mb > float(BUDGET_MB.get(pack, 256.0)):
			failures += 1
	print("render_unified_memory_check: %s (%d failures)" % ["OK" if failures == 0 else "FAIL", failures])
	get_tree().quit(1 if failures > 0 else 0)
