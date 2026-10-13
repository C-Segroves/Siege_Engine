extends Node
## Headless check of hardpoint size classes and cross-game weapon mounting (WeaponFit,
## WeaponPodFit, HercModel; campaign_availability.md section 4):
##  - every Herc-family weapon and hardpoint has a size class;
##  - native parity: every game's own Hercs are offered exactly the weapons the old mask rule offered;
##  - cross-game fit follows the size ladder (S < M < L < X, turret-only never);
##  - fitted / stand-in pod models match the host's reference box (+-25 %);
##  - no visible hardpoint ever shows nothing (internal mounts excepted);
##  - native pods sit exactly where the decoded originals put them (weapon_mounts.md): Earthsiege GL
##    offset + pod push-out on the mount part's node, Starsiege hardpoint offset on head0 rolled by
##    side; muzzles at the original muzzle; a foreign pod on a Battledrome bay replaces the baked pod;
##  - every Earthsiege GL mount id names a part (cell parts included: mount id 5 is the torso's damage
##    cell) and the hardpoint frame hangs on that part's node; the Headhunter's internal guns fire from
##    its torso, not its feet;
##  - two-vertex 3Space polygons (lines) are drawn: the Bulldog's particle-beam gun keeps its rails.
##   godot --headless --audio-driver Dummy --path game res://tests/weapon_fit_check.tscn

const HERC := "herc"
const SCALE_TOLERANCE := 0.25
const MODEL_HOSTS := ["es1:RAPTOR", "es1:COLOSSUS", "es2:OGRE", "bd:THOR", "starsiege:kn_basl", "starsiege:cy_exec"]
## [weapon, vehicle, hardpoint, expected fit]
const CROSS_CASES := [
	["es1:LAS100", "starsiege:kn_basl", 0, true],
	["starsiege:MFAC", "es1:RAPTOR", 0, false],
	["es2:LAS500", "starsiege:ca_basl", 2, true],
	["starsiege:TUR_HLAS", "starsiege:ca_basl", 2, false],
	["bd:LASER7", "es1:RAPTOR", 0, false],
	["bd:LASER1", "es1:RAPTOR", 2, true],
	["es1:PBEAM_CYBRID", "starsiege:kn_basl", 0, false],
]

const ON_HERCS := {WeaponFit.RULE_CYBRID_WEAPONS_ON_HERCS: true}
## [weapon, vehicle, hardpoint, rules, expected fit]: Cybrid-only weapons by match rule
## (campaign / co-op {} = original; arena / versus / skirmish = ON_HERCS).
const RULE_CASES := [
	["es1:PBEAM_CYBRID", "starsiege:kn_basl", 2, {}, false],
	["es1:PBEAM_CYBRID", "starsiege:kn_basl", 2, ON_HERCS, true],
	["es1:PBEAM_CYBRID", "es1:RAPTOR", 0, ON_HERCS, false],
	["starsiege:TLAS", "starsiege:tr_pala", 0, {}, false],
	["starsiege:TLAS", "starsiege:tr_pala", 0, ON_HERCS, true],
	["starsiege:TUR_HLAS", "starsiege:ca_basl", 2, ON_HERCS, false],
]

var fails := 0


func _ready() -> void:
	_check_sizes()
	_check_native_parity()
	_check_cross_fit()
	_check_cybrid_rule()
	_check_mount_bases_stripped()
	_check_no_invisible_mounts()
	await _check_model_scale()
	await _check_native_placement()
	await _check_baked_pod_replaced()
	_check_gl_mount_parts()
	await _check_internal_muzzles()
	await _check_line_polys_drawn()
	print("weapon_fit_check: %d failures" % fails)
	get_tree().quit()


func _fail(msg: String) -> void:
	fails += 1
	print("FAIL: ", msg)


func _herc_vehicles() -> Array:
	return Packs.vehicles.values().filter(func(v): return str(v.get("category", HERC)) == HERC)


func _check_sizes() -> void:
	var per_pack := {}
	for w in Packs.weapons.values():
		if str(w.get("category", HERC)) != HERC:
			continue
		var s := str(w.get("size", ""))
		if not (s in WeaponFit.SIZES or s == WeaponFit.INTERNAL):
			_fail("weapon %s has no size class" % w.id)
		var k := "%s %s" % [w.pack, s]
		per_pack[k] = int(per_pack.get(k, 0)) + 1
	var hardpoints := {}
	for v in _herc_vehicles():
		for i in WeaponFit.hardpoint_masks(v).size():
			var s := WeaponFit.hardpoint_size(v, i)
			if not s in WeaponFit.SIZES:
				_fail("%s hardpoint %d has no size class (mask %d)" % [v.id, i, WeaponFit.hardpoint_masks(v)[i]])
			var k := "%s %s" % [v.pack, s]
			hardpoints[k] = int(hardpoints.get(k, 0)) + 1
	print("weapon sizes: ", per_pack)
	print("hardpoint sizes: ", hardpoints)


## The pre-WeaponFit rule (Packs.fits before section 4): hardpoint mask >= weapon mask.
static func _old_fits(w: Dictionary, mask: int) -> bool:
	return mask >= int(w.get("hardpoint_mask", PackWeaponLoader.SIZE_MASK.get(w.get("size_class", "light"), 7)))


static func _old_offer(mask: int, cybrid: bool, category: String) -> Array:
	var out := []
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if w.get("category", HERC) != category or not Packs.is_enabled(w.pack, "%s_weapons" % category):
			continue
		if w.get("cybrid_only", false) and not cybrid:
			continue
		if _old_fits(w, mask):
			out.append(str(id))
	out.sort()
	return out


func _check_native_parity() -> void:
	var pairs := 0
	var mismatches := 0
	for v in _herc_vehicles():
		var masks := WeaponFit.hardpoint_masks(v)
		var cyb: bool = v.get("side", "herc") == "cybrid"
		for i in masks.size():
			var old := _old_offer(int(masks[i]), cyb, str(v.category))
			var now: Array = Packs.weapons_for_mask(int(masks[i]), cyb, str(v.category)).map(func(w): return str(w.id))
			now.sort()
			# the mine launcher bay rule (WeaponFit.MINE_BAY) is new: mines only, whatever the size
			var native_old := old.filter(func(id): return Assets.split_id(id)[0] == v.pack and WeaponFit.fits_bay(Packs.weapon(id), v, i))
			var native_new := Packs.weapons.values().filter(func(w): return w.pack == v.pack and WeaponFit.fits(w, v, i)).map(func(w): return str(w.id))
			native_new.sort()
			pairs += 1
			if old != now or native_old != native_new:
				mismatches += 1
				if mismatches <= 5:
					_fail("%s hardpoint %d: offer changed (old %d / new %d, native %d / %d)" % [v.id, i, old.size(), now.size(), native_old.size(), native_new.size()])
	print("native parity: %d hardpoints compared, %d changed" % [pairs, mismatches])


func _check_cross_fit() -> void:
	for c in CROSS_CASES:
		var w := Packs.weapon(str(c[0]))
		var v := Packs.vehicle(str(c[1]))
		if w.is_empty() or v.is_empty():
			print("cross fit: %s on %s skipped (not installed)" % [c[0], c[1]])
			continue
		var got := WeaponFit.fits(w, v, int(c[2]))
		print("cross fit: %-20s (%s) on %s #%d (%s): %s" % [c[0], WeaponFit.size_of(w), c[1], c[2], WeaponFit.hardpoint_size(v, int(c[2])), got])
		if got != bool(c[3]):
			_fail("%s on %s #%d: fits=%s, expected %s" % [c[0], c[1], c[2], got, c[3]])


func _check_cybrid_rule() -> void:
	for c in RULE_CASES:
		var w := Packs.weapon(str(c[0]))
		var v := Packs.vehicle(str(c[1]))
		if w.is_empty() or v.is_empty():
			print("cybrid rule: %s on %s skipped (not installed)" % [c[0], c[1]])
			continue
		var got := WeaponFit.fits(w, v, int(c[2]), c[3])
		print("cybrid rule: %-18s on %s #%d rules %s: %s" % [c[0], c[1], c[2], c[3], got])
		if got != bool(c[4]):
			_fail("%s on %s #%d rules %s: fits=%s, expected %s" % [c[0], c[1], c[2], c[3], got, c[4]])
	# the offer list follows the same rule; include_cybrid and the rule are one concept
	var x_mask := int(WeaponFit.SIZE_MASKS.X)
	var cyb := func(list: Array) -> int: return list.filter(func(w): return w.get("cybrid_only", false)).size()
	var off: int = cyb.call(Packs.weapons_for_mask(x_mask))
	var on: int = cyb.call(Packs.weapons_for_mask(x_mask, false, HERC, ON_HERCS))
	var flag: int = cyb.call(Packs.weapons_for_mask(x_mask, true))
	print("cybrid rule: Cybrid-only weapons offered on an X hardpoint: original %d, rule on %d, include_cybrid %d" % [off, on, flag])
	if off != 0 or on == 0 or on != flag:
		_fail("weapons_for_mask does not follow the Cybrid weapon rule")


## Starsiege pods on another game's Herc leave their flat hardpoint strut ("baseA32" on wg_hatc / wg_vip8)
## behind but keep a "baseA 32" piece that is the gun body (wg_las, wg_hlas).
const STRUT_CASES := {"starsiege:wg_hatc": 0, "starsiege:wg_vip8": 0, "starsiege:wg_las": 1, "starsiege:wg_hlas": 1}


func _check_mount_bases_stripped() -> void:
	for sid in STRUT_CASES:
		if not WeaponPodFit.has_geometry(sid):
			continue
		var pieces: Array = WeaponPodFit.foreign_pod_shape(sid).lods[0].pieces
		var bases := pieces.filter(func(p): return str(p.get("name", "")).to_lower().begins_with("base"))
		print("mount base: %s keeps %d pieces, %d base pieces" % [sid, pieces.size(), bases.size()])
		if bases.size() != int(STRUT_CASES[sid]) or pieces.is_empty():
			_fail("%s foreign pod keeps %d base pieces, expected %d" % [sid, bases.size(), STRUT_CASES[sid]])


func _check_no_invisible_mounts() -> void:
	var looks := {}
	for v in _herc_vehicles():
		if not v.get("pilotable", false):
			continue
		var guns: Array = v.get("guns", [])
		for i in guns.size():
			for w in Packs.weapons.values():
				if not WeaponFit.fits(w, v, i):
					continue
				var plan := HercModel.mount_plan(v, i, w)
				var look: String = HercModel.Look.keys()[int(plan.look)]
				looks[look] = int(looks.get(look, 0)) + 1
				if (plan.look == HercModel.Look.HIDDEN) != _drawn_by_nothing(v, guns[i], w):
					_fail("%s #%d with %s: %s" % [v.id, i, w.id, look])
				elif plan.has("shape") and not WeaponPodFit.has_geometry(str(plan.shape)):
					_fail("%s #%d with %s: pod shape %s has no geometry" % [v.id, i, w.id, plan.shape])
	print("mount looks: ", looks)


## Where the original draws no weapon: internal GL mounts (group > 3) and Battledrome mine / missile
## launchers (bay without a baked pod) with a Battledrome weapon.
static func _drawn_by_nothing(v: Dictionary, g: Dictionary, w: Dictionary) -> bool:
	if int(g.get("mount_group", 0)) > HercModel.MAX_VISIBLE_MOUNT_GROUP:
		return true
	return w.pack == v.pack and str(g.get("bay", "")) != "" and not g.has("pod_cells")


## Builds each sample host with one foreign weapon per pack and size on every hardpoint it fits, and
## measures the pod's length in metres against the reference box.
func _check_model_scale() -> void:
	var checked := 0
	for vid in MODEL_HOSTS:
		var v := Packs.vehicle(vid)
		if v.is_empty():
			print("model scale: %s not installed, skipped" % vid)
			continue
		var host := ShapeInstance.new()
		add_child(host)
		host.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
		var mounts := HercModel.mount_nodes(v, host, HercModel.create_frames(v, host))
		for i in (v.guns as Array).size():
			for w in _samples_for(v, i):
				checked += _measure_pod(v, i, w, mounts[i % mounts.size()])
		host.queue_free()
		await get_tree().process_frame
	print("model scale: %d pods measured" % checked)


## One weapon per (pack, size, has model) that fits hardpoint i and is not the host's own.
func _samples_for(v: Dictionary, i: int) -> Array:
	var picked := {}
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if w.pack == v.pack or not WeaponFit.fits(w, v, i):
			continue
		var key := "%s|%s|%s" % [w.pack, WeaponFit.size_of(w), WeaponPodFit.model_shape_id(w, 0) != ""]
		if not picked.has(key) or str(id) < str(picked[key].id):
			picked[key] = w
	return picked.values()


func _measure_pod(v: Dictionary, i: int, w: Dictionary, mount: Node3D) -> int:
	var model := HercModel.weapon_model(v, i, w, Packs.default_palette(str(v.pack)))
	if model == null:
		return 0
	HercModel.attach_weapon_model(mount, model, v)
	var plan: Dictionary = model.get_meta(HercModel.PLAN_META)
	var metres := WeaponPodFit.longest(WeaponPodFit.local_box(model.shape)) * model.global_basis.get_scale().x
	var want := WeaponPodFit.longest(plan.box) if plan.has("box") else WeaponPodFit.longest(WeaponPodFit.metric_box(str(plan.shape)))
	if absf(metres - want) > want * SCALE_TOLERANCE:
		_fail("%s #%d %s (%s): pod %.2f m, reference %.2f m" % [v.id, i, w.id, HercModel.Look.keys()[int(plan.look)], metres, want])
	model.queue_free()
	return 1


# ------------------------------------------------------------------ original placement

const PLACEMENT_HOSTS := ["es1:ROADRUNN", "es1:RAPTOR", "es1:COLOSSUS", "es1:SCORPION", "es2:OUTLAW", "es2:OGRE",
	"es2:APOCA", "starsiege:kn_apoc", "starsiege:ca_basl", "starsiege:tr_talo", "starsiege:tr_pala", "bd:THOR"]
## Placement tolerance (m).
const PLACE_TOLERANCE := 0.01
## DBSIM 0xbbd4 (ES2 0x40f904): pod push-out per GL mount group, as factors of the pod half extent (x, z).
const GL_PUSH := {0: [0, 1], 1: [0, -1], 2: [-1, 0], 3: [1, 0]}
## Starsiege.exe 0x494dd0: roll about the forward axis per hardpoint side (degrees, + = top to the right).
const SIDE_ROLL_DEG := {"T": 0.0, "I": 0.0, "B": 180.0, "L": -90.0, "R": 90.0}


## Every visible native pod of the sample hosts' default loadouts against the decoded original transform.
func _check_native_placement() -> void:
	var checked := 0
	for vid in PLACEMENT_HOSTS:
		var v := Packs.vehicle(vid)
		if v.is_empty():
			continue
		var host := ShapeInstance.new()
		add_child(host)
		host.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
		var frames := HercModel.mount_nodes(v, host, HercModel.build_mounts(v, host))
		var lo: Array = v.get("loadout", [])
		for i in mini(lo.size(), (v.guns as Array).size()):
			var w := Packs.weapon(str(lo[i])) if lo[i] != null else {}
			var model := HercModel.weapon_model(v, i, w, Packs.default_palette(str(v.pack))) if not w.is_empty() else null
			if model == null or int(model.get_meta(HercModel.PLAN_META).look) != HercModel.Look.NATIVE:
				continue
			HercModel.attach_weapon_model(frames[i], model, v)
			checked += _compare_placement(v, i, w, host, model, frames[i])
		host.queue_free()
		await get_tree().process_frame
	print("native placement: %d pods compared with the decoded originals" % checked)
	if checked == 0:
		_fail("no native pod compared")


func _compare_placement(v: Dictionary, i: int, w: Dictionary, host: ShapeInstance, model: ShapeInstance, frame: Node3D) -> int:
	var g: Dictionary = v.guns[i]
	var want := _original_mount(v, g, w, host)
	if want.is_empty():
		return 0
	var k := Packs.shape_scale(str(v.pack))
	var got: Transform3D = host.global_transform.affine_inverse() * model.global_transform
	var at: Transform3D = want.pod
	if got.origin.distance_to(at.origin) * k > PLACE_TOLERANCE or not (got.basis.orthonormalized() * Vector3.UP).is_equal_approx(at.basis * Vector3.UP):
		_fail("%s #%d %s: pod at %s up %s, original %s up %s" % [v.id, i, w.id, got.origin * k, got.basis.orthonormalized() * Vector3.UP, at.origin * k, at.basis * Vector3.UP])
	var muzzle := host.global_transform.affine_inverse() * HercModel.muzzle_of(frame).global_position
	if muzzle.distance_to(want.muzzle) * k > PLACE_TOLERANCE:
		_fail("%s #%d %s: muzzle %s, original %s" % [v.id, i, w.id, muzzle * k, want.muzzle * k])
	return 1


## The original pod transform and muzzle (host shape space) of weapon w on gun g, computed from the raw
## records: {"pod": Transform3D, "muzzle": Vector3}; {} when the rule is not known.
func _original_mount(v: Dictionary, g: Dictionary, w: Dictionary, host: ShapeInstance) -> Dictionary:
	var m: Dictionary = w.get("model", {})
	var muzzle: Array = m.get("muzzle_units", [0, 0, 0]) if m.get("muzzle_units") is Array else [0, 0, 0]
	if g.get("offset") is Array:
		var node := _part_node_transform(host, int(g.mount_node))
		var e: Array = m.get("pod_extent", [0, 0, 0])
		var push: Array = GL_PUSH.get(int(g.mount_group), [0, 0])
		var o: Array = g.offset
		var pod := [float(o[0]) + float(e[0]) * push[0], float(o[1]), float(o[2]) + float(e[2]) * push[1]]
		var tip := [pod[0] + float(muzzle[0]), pod[1] + float(muzzle[1]), pod[2] + float(muzzle[2])]
		return {"pod": node * Transform3D(Basis.IDENTITY, ShapeInstance.es_to_godot(pod)),
			"muzzle": node * ShapeInstance.es_to_godot(tip)}
	if g.get("side") is String and g.get("muzzle_units") is Array:
		var node := _node_transform(host, int(g.get("attach_node", -1)))
		var roll := Basis(Vector3.FORWARD, deg_to_rad(float(SIDE_ROLL_DEG.get(str(g.side), 0.0))))
		var pod := node * Transform3D(roll, ShapeInstance.es_to_godot(g.muzzle_units))
		return {"pod": pod, "muzzle": pod * ShapeInstance.es_to_godot(muzzle)}
	return {}


## Default-pose transform (host shape space) of the node of the shape part with id `part` (DBSIM findPart).
func _part_node_transform(host: ShapeInstance, part: int) -> Transform3D:
	return _node_transform(host, _raw_part_node(host.shape, part))


## Node of part `part` in LOD 0 straight from the shape data: a piece's own id, or the id of the cell part
## (damage cell) it belongs to; -1 (the root) when no part has that id.
static func _raw_part_node(shape: Dictionary, part: int) -> int:
	var lod: Dictionary = shape.lods[0]
	for piece in lod.pieces:
		var ci := int(piece.get("cell", -1))
		if ci >= 0 and int(lod.cells[ci].get("id", -1)) == part:
			return int(lod.cells[ci].node)
		if int(piece.get("id", -1)) == part:
			return int(piece.node)
	return -1


func _node_transform(host: ShapeInstance, index: int) -> Transform3D:
	var xfs := WeaponPodFit.make_node_transforms(host.shape)
	return xfs[index] if index >= 0 and index < xfs.size() else Transform3D.IDENTITY


## Another game's pod on a Battledrome bay: the baked pod is hidden and the new pod fills its box.
func _check_baked_pod_replaced() -> void:
	var v := Packs.vehicle("bd:THOR")
	var w := Packs.weapon("es1:ATC50")
	if v.is_empty() or w.is_empty():
		print("baked pod: skipped (not installed)")
		return
	var host := ShapeInstance.new()
	add_child(host)
	host.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var frames := HercModel.mount_nodes(v, host, HercModel.build_mounts(v, host))
	var model := HercModel.weapon_model(v, 0, w, host.palette_name)
	HercModel.attach_weapon_model(frames[0], model, v)
	await get_tree().process_frame
	var plan: Dictionary = model.get_meta(HercModel.PLAN_META)
	var visible: int = v.guns[0].pod_cells.filter(func(ci): return host.is_cell_drawn(int(ci))).size()
	var k := Packs.shape_scale(str(v.pack))
	var box: AABB = (frames[0].global_transform.affine_inverse() * model.global_transform) * WeaponPodFit.local_box(model.shape)
	var metric := AABB(box.position * k, box.size * k)
	var ref: AABB = plan.box
	print("baked pod: THOR POD 1 with %s: %d baked cells drawn; pod %s m, bay box %s m" % [w.id, visible, metric.size, ref.size])
	if visible > 0:
		_fail("bd:THOR #0: the baked pod is still drawn under %s" % w.id)
	if absf(WeaponPodFit.longest(metric) - WeaponPodFit.longest(ref)) > WeaponPodFit.longest(ref) * SCALE_TOLERANCE 			or metric.get_center().distance_to(ref.get_center()) > WeaponPodFit.longest(ref) * SCALE_TOLERANCE:
		_fail("bd:THOR #0: %s pod %s does not fill the bay box %s" % [w.id, metric, ref])
	host.queue_free()


# ------------------------------------------------------------------ GL mount parts and line polygons

## [vehicle, gun, node]: GL mount id 5 is a cell part (ES2 HEADHUNT.DTS: cell_anim_part id 5 on node 12).
const CELL_PART_CASES := [["es2:HEADHUNT", 2, 12], ["es2:HEADHUNT", 6, 12], ["es2:HEADHUNT", 7, 12],
	["es1:PATRIOT", 5, 11], ["es1:BULLDOG", 0, 20]]
## Lowest muzzle allowed on the Headhunter, as a share of its height (hips are at about 0.55).
const MIN_MUZZLE_HEIGHT_SHARE := 0.45
## MECHWPNS 13 (es1 PBEAM_CYBRID): the four corner rails between the gun body (y < 200) and its tip
## (y > 1400) are two-vertex polygons; their middle must have geometry.
const RAIL_SHAPE := "es1:MECHWPNS_13"
const RAIL_SPAN_UNITS := Vector2(400, 1200)


## Every ES1 / ES2 GL gun's hardpoint frame hangs on the node of the part its mount id names.
func _check_gl_mount_parts() -> void:
	var checked := 0
	for v in _herc_vehicles():
		if not str(v.pack) in ["es1", "es2"]:
			continue
		var shape := Assets.shape(str(v.shape))
		for i in (v.get("guns", []) as Array).size():
			var g: Dictionary = v.guns[i]
			if not WeaponMount.is_gl_record(g):
				continue
			var want := _raw_part_node(shape, int(g.mount_node))
			var got := WeaponMount.make_part_node_index(shape, 0, int(g.mount_node))
			if got != want:
				_fail("%s #%d mount part %d: node %d, shape data %d" % [v.id, i, g.mount_node, got, want])
			if want < 0 and not v.get("flyer", false):
				_fail("%s #%d: mount part %d names no part" % [v.id, i, g.mount_node])
			checked += 1
	for c in CELL_PART_CASES:
		var v := Packs.vehicle(str(c[0]))
		if v.is_empty():
			continue
		var got := WeaponMount.make_part_node_index(Assets.shape(str(v.shape)), 0, int(v.guns[c[1]].mount_node))
		if got != int(c[2]):
			_fail("%s #%d: frame on node %d, original node %d" % [c[0], c[1], got, c[2]])
	print("GL mount parts: %d guns checked" % checked)


## The Headhunter's muzzles all sit on its upper body (they were at its feet: mount id 5 fell back to node 5).
func _check_internal_muzzles() -> void:
	var v := Packs.vehicle("es2:HEADHUNT")
	if v.is_empty():
		return
	var host := ShapeInstance.new()
	add_child(host)
	host.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var frames := HercModel.build_mounts(v, host)
	var floor_y := host.lowest_point()
	var height := maxf(float(v.get("height_m", 0.0)) / maxf(host.scale.y, HercModel.MIN_SCALE), 0.001)
	for i in frames:
		var y := host.to_local(HercModel.muzzle_of(frames[i]).global_position).y - floor_y
		if y < height * MIN_MUZZLE_HEIGHT_SHARE:
			_fail("es2:HEADHUNT #%d muzzle %.2f m above the ground (height %.2f m)" % [i, y, height])
	host.queue_free()
	await get_tree().process_frame


## Line polygons are drawn: the particle-beam gun's rails bridge the gap between its body and tip.
func _check_line_polys_drawn() -> void:
	if not WeaponPodFit.has_geometry(RAIL_SHAPE):
		return
	var pod := ShapeInstance.new()
	add_child(pod)
	pod.build(Assets.shape(RAIL_SHAPE), 0, Packs.default_palette("es1"))
	var bridges := 0
	for mi in pod.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).is_visible_in_tree():
			bridges += _count_bridging_triangles((mi as MeshInstance3D).mesh)
	if bridges == 0:
		_fail("%s: nothing joins the gun body to its tip (line polygons not drawn)" % RAIL_SHAPE)
	pod.queue_free()
	await get_tree().process_frame


## Triangles of `mesh` reaching from before RAIL_SPAN_UNITS.x to beyond .y along the pod's forward axis.
static func _count_bridging_triangles(mesh: Mesh) -> int:
	var count := 0
	for surface in mesh.get_surface_count():
		var verts: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for t in range(0, verts.size() - 2, 3):
			var ys := [-verts[t].z, -verts[t + 1].z, -verts[t + 2].z].map(func(z): return z / Assets.UNIT)
			if ys.min() < RAIL_SPAN_UNITS.x and ys.max() > RAIL_SPAN_UNITS.y:
				count += 1
	return count
