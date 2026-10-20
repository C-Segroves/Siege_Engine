extends Node
## Verifies the importer-side bake (tools/unified_bake.py) against the load-time bake: for each strip in
## $RU_BAKE_DIR/unified (a scratch import) the layers must equal UnifiedMaterial's runtime bake byte for byte.
##   python tools/unified_bake.py es2 --palettes WORLD0 --out <dir>
##   RU_BAKE_DIR=<dir> godot --audio-driver Dummy --path game res://tests/render_unified_bake_check.tscn
const MAX_CHECKED := 40


func _ready() -> void:
	var dir := OS.get_environment("RU_BAKE_DIR")
	var failures := 0
	var checked := 0
	if dir == "":
		print("render_unified_bake_check: SKIPPED (set RU_BAKE_DIR to a scratch bake)")
		get_tree().quit()
		return
	for f in DirAccess.get_files_at(dir.path_join("unified")):
		if checked >= MAX_CHECKED or not f.ends_with(".png"):
			continue
		var parts := f.get_basename().split("__")           # <pack>_<WORLD>, <texset>, <index>
		var pack := String(parts[0]).get_slice("_", 0)
		var palette_id := "%s:%s" % [pack, String(parts[0]).substr(pack.length() + 1)]
		var idx := int(parts[2])
		var texset := Assets.texture_set("%s:%s" % [pack, parts[1]])
		if idx >= texset.size():
			continue
		var index_img: Image = (texset[idx] as ImageTexture).get_image()
		var look := Palette.look(palette_id)
		var tex_light: Image = (look.texlight as ImageTexture).get_image()
		var pal: Image = (look.palette as ImageTexture).get_image()
		var runtime := UnifiedMaterial._bake_texture_levels(index_img.duplicate(), tex_light.duplicate(), pal.duplicate())
		UnifiedMaterial.bake_root = dir
		var baked := UnifiedMaterial._load_baked_levels(palette_id, "%s/%s" % [pack, parts[1]], idx, runtime.size(), index_img.get_size())
		UnifiedMaterial.bake_root = ""
		var ok := baked.size() == runtime.size()
		for l in baked.size():
			ok = ok and baked[l].get_data() == runtime[l].get_data()
		checked += 1
		if not ok:
			failures += 1
			print("MISMATCH ", f, " sizes ", baked.size(), "/", runtime.size())
			if baked.size() == runtime.size() and failures == 1:
				var a: PackedByteArray = baked[0].get_data()
				var b: PackedByteArray = runtime[0].get_data()
				for k in a.size():
					if a[k] != b[k]:
						print("  first diff at byte ", k, " baked ", a[k], " runtime ", b[k], " (px ", k / 4, " ch ", k % 4, ") formats ", baked[0].get_format(), "/", runtime[0].get_format())
						break
	print("render_unified_bake_check: %d strips checked, %d mismatches" % [checked, failures])
	get_tree().quit(1 if failures > 0 or checked == 0 else 0)
