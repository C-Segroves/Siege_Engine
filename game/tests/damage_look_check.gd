extends Node
## Damaged Herc parts keep their original look (playtest E5): Earthsiege 1 / 2 damage-state cells are shaded
## polygons (3Space shade list 12, charred grey), drawn through the world's shade lists. Without the exported
## lists (worlds/shade_<n>.png, texlight_<n>.png from tools/export_es1.py export_worlds) the engine fell back to
## an identity table: the damaged parts drew flat raw palette colours (palette[12] = dark blue) instead.
## A broken component shows only its own part damaged (DMG shape_part = cell slot), not random cells all over.
##   Godot --headless --audio-driver Dummy --path game res://tests/damage_look_check.tscn

const PACK_WORLDS := {"es1": [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22], "es2": [0]}
## Shade list of the damaged state of every Earthsiege Herc (RAPTOR: 97 polygons) and the light column checked.
const DAMAGE_SHADE_LIST := 12
const MID_LIGHT := 16

var _failures := 0


func _ready() -> void:
	for pack in PACK_WORLDS:
		if not Assets.has_pack(pack):
			print("  skip: no %s pack" % pack)
			continue
		for n in PACK_WORLDS[pack]:
			_check_world(pack, int(n))
	_check_damaged_cells_shaded("es1:RAPTOR")
	await _check_component_part_damaged()
	print("damage_look_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	if not ok:
		print("  FAIL %s" % what)
		_failures += 1


func _check_world(pack: String, n: int) -> void:
	for table in ["shade", "texlight"]:
		_expect(FileAccess.file_exists(Assets.path("worlds/%s_%d.png" % [table, n], pack)), "%s world %d has its %s table" % [pack, n, table])
	var l := Palette.look("%s:WORLD%d" % [pack, n])
	var img: Image = (l.shade as ImageTexture).get_image()
	var slot := img.get_pixel(MID_LIGHT, DAMAGE_SHADE_LIST).r8
	_expect(slot != DAMAGE_SHADE_LIST, "%s world %d: shade list %d maps to its ramp (slot %d), not the raw palette entry" % [pack, n, DAMAGE_SHADE_LIST, slot])


## The damaged state of `vid`'s cells draws shaded polygons through the shade lists.
func _check_damaged_cells_shaded(vid: String) -> void:
	var sdef := Assets.shape(vid)
	var shaded := 0
	for p in (sdef.get("lods", [{}])[0] as Dictionary).get("pieces", []):
		if int(p.cell) >= 0 and int(p.state) == 1:
			for poly in p.polys:
				if poly.m.kind == "shade":
					shaded += 1
	_expect(shaded > 0, "%s: damaged cells are shaded polygons (%d)" % [vid, shaded])
	print("  %s damaged-state shaded polygons: %d" % [vid, shaded])


const FOOT_COMPONENT := "LEFT_FOOT"
const ROSTER := {1: {"name": "Tester", "vehicle": "es1:RAPTOR", "team": 0, "loadout": []}}


func _check_component_part_damaged() -> void:
	var comps := HercDamage.make_components(Packs.vehicle("es1:RAPTOR"))
	_expect(comps.any(func(c): return c.name == "FRONT_COCKPIT" and int(c.get("shape_part", -1)) == 7), "Raptor components keep their DMG shape_part")
	var battle: Battle = load("res://games/es1/battle.tscn").instantiate()
	battle.config = {"mode": "mission", "respawn": false, "roster": ROSTER.duplicate(true),
		"mission": MissionCompiler.load_mission("B0_C0_0A", PackedInt32Array(), 1, -1, {})}
	add_child(battle)
	for i in 20:
		await get_tree().physics_frame
	var h: Herc = battle.player
	var index := -1
	for i in h.components.size():
		if h.components[i].name == FOOT_COMPONENT:
			index = i
	var slot := int(h.components[index].get("shape_part", -1)) if index >= 0 else -1
	h.wound_component(index, 1e9)
	var wrong := 0
	var shown := 0
	for ci in h.shape.cell_count():
		var damaged := h.shape.get_cell_state(ci) == HercDamage.DAMAGED_CELL_STATE
		if damaged and h.shape.get_cell_slot(ci) != slot:
			wrong += 1
		if damaged and h.shape.get_cell_slot(ci) == slot:
			shown += 1
	_expect(slot >= 0 and shown > 0, "the broken %s shows its part (slot %d) damaged (%d cells)" % [FOOT_COMPONENT, slot, shown])
	_expect(wrong == 0, "no other part loses its textures (%d other cells damaged)" % wrong)
	print("  %s broken: slot %d cells damaged %d, others %d" % [FOOT_COMPONENT, slot, shown, wrong])
	battle.queue_free()
	await get_tree().process_frame
