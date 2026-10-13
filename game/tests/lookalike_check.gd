extends Node
## Headless check of the look-alike decision tree for weapons without a model (WeaponLookalike,
## docs/formats/weapon_mounts.md section 7):
##  - every model-less Herc weapon (all of Battledrome, ES2 MINE / LAEW, Starsiege EHUL) gets the
##    archetype its data says;
##  - for simulated installed-pack subsets (only the candidate set is filtered; nothing on disk changes)
##    every Battledrome weapon on an ES1, ES2 and Starsiege Herc gets a deterministic pick from the
##    installed packs only, the expected sample picks, and is never invisible;
##  - Battledrome weapons on Battledrome Hercs keep their baked pods (and launchers draw nothing).
##   godot --headless --audio-driver Dummy --path game res://tests/lookalike_check.tscn

## Archetype of each model-less weapon by name prefix (Battledrome) or id.
const BD_ARCHETYPES := {
	"LASER": WeaponLookalike.LASER, "BLASTER": WeaponLookalike.BLASTER, "PLASMA": WeaponLookalike.PLASMA,
	"CANON": WeaponLookalike.AUTOCANNON, "MOSQUITO": WeaponLookalike.MISSILE, "HORNET": WeaponLookalike.MISSILE,
	"CHARLIE": WeaponLookalike.MISSILE, "EAGLE": WeaponLookalike.MISSILE, "GATOR": WeaponLookalike.MINE,
	"BLOODHND": WeaponLookalike.MINE, "PITBULL": WeaponLookalike.MINE,
}
const OTHER_ARCHETYPES := {"es2:MINE": WeaponLookalike.MINE, "es2:LAEW": WeaponLookalike.ARTILLERY,
	"starsiege:EHUL": WeaponLookalike.SPECIAL}
## Model weapons whose archetype anchors the rest of the table.
const ANCHOR_ARCHETYPES := {"es1:LAS100": WeaponLookalike.LASER, "es1:PBEAM": WeaponLookalike.PARTICLE_BEAM,
	"es1:ELF": WeaponLookalike.DRAIN, "es1:ATC35": WeaponLookalike.AUTOCANNON, "es1:MLRS6": WeaponLookalike.MISSILE,
	"es1:GREN": WeaponLookalike.ARTILLERY, "es1:ECM": WeaponLookalike.SPECIAL, "es2:PLAS": WeaponLookalike.PLASMA,
	"starsiege:BLAS": WeaponLookalike.BLASTER, "starsiege:BC": WeaponLookalike.HEAVY_CANNON,
	"starsiege:PRX6": WeaponLookalike.MINE, "starsiege:EMP": WeaponLookalike.DRAIN}

const HOSTS := ["es1:RAPTOR", "es2:OUTLAW", "starsiege:kn_basl"]
const BD_HOST := "bd:THOR"
## Simulated installations ([] = everything actually installed).
const SUBSETS := [[], ["bd", "es1"], ["bd", "starsiege"], ["bd", "es2"], ["bd"], ["bd", "tribes2"]]
## [subset, host, hardpoint, weapon, expected rule, expected source weapon ("" = any)]
const EXPECTED := [
	[[], "es1:RAPTOR", 2, "bd:LASER1", "archetype_size_host", "es1:LAS100"],
	[[], "es1:RAPTOR", 0, "bd:LASER4", "archetype_size_host", "es1:LAS200"],
	[[], "es1:RAPTOR", 2, "bd:CANON1", "archetype_size_host", "es1:ATC20"],
	[[], "es1:RAPTOR", 2, "bd:MOSQUITO_15", "archetype_size_host", ""],
	[["bd", "es1"], "es1:RAPTOR", 2, "bd:BLASTER1", "family_size", "es1:LAS100"],
	[["bd", "es1"], "es1:RAPTOR", 2, "bd:GATOR_10", "family_size", ""],
	[["bd", "starsiege"], "es1:RAPTOR", 2, "bd:LASER1", "archetype_size_era", "starsiege:LAS"],
	[["bd", "starsiege"], "es1:RAPTOR", 2, "bd:GATOR_10", "archetype_size_era", "starsiege:PRX6"],
	[["bd", "es2"], "starsiege:kn_basl", 0, "bd:MOSQUITO_15", "archetype_size_era", ""],
	[["bd", "es2"], "starsiege:kn_basl", 0, "bd:PLASMA1", "archetype_near_size", ""],
	[[], "starsiege:kn_basl", 0, "bd:LASER1", "archetype_size_host", "starsiege:LAS"],
	[[], "es2:OUTLAW", 1, "bd:LASER4", "archetype_size_host", ""],
	[["bd", "es1"], "es2:OUTLAW", 1, "bd:LASER4", "archetype_size_era", "es1:LAS200"],
	[["bd"], "es1:RAPTOR", 2, "bd:LASER1", WeaponLookalike.RULE_HOST_POD, ""],
	[["bd", "tribes2"], "es1:RAPTOR", 2, "bd:LASER1", WeaponLookalike.RULE_HOST_POD, ""],
]

var fails := 0


func _ready() -> void:
	_check_archetypes()
	_check_subsets()
	_check_expected()
	_check_battledrome_native()
	await _check_models_built()
	WeaponLookalike.clear_pack_filter()
	print("lookalike_check: %d failures" % fails)
	get_tree().quit()


func _fail(msg: String) -> void:
	fails += 1
	print("FAIL: ", msg)


func _check_archetypes() -> void:
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if str(w.pack) == "bd" and str(w.get("category", "herc")) == "herc":
			_expect_archetype(w, _bd_archetype(str(w.name)))
	for id in OTHER_ARCHETYPES:
		_expect_archetype(Packs.weapon(id), OTHER_ARCHETYPES[id])
	for id in ANCHOR_ARCHETYPES:
		_expect_archetype(Packs.weapon(id), ANCHOR_ARCHETYPES[id])
	for id in Packs.weapons:
		var w: Dictionary = Packs.weapons[id]
		if not WeaponLookalike.AFFINITY.has(WeaponLookalike.make_archetype(w)):
			_fail("%s: archetype %s not in the affinity table" % [id, WeaponLookalike.make_archetype(w)])


static func _bd_archetype(name: String) -> String:
	for prefix in BD_ARCHETYPES:
		if name.begins_with(prefix):
			return BD_ARCHETYPES[prefix]
	return ""


func _expect_archetype(w: Dictionary, want: String) -> void:
	if w.is_empty():
		return   # pack not installed
	var got := WeaponLookalike.make_archetype(w)
	print("archetype: %-20s %s" % [w.id, got])
	if got != want:
		_fail("%s: archetype %s, expected %s" % [w.id, got, want])


## Every Battledrome weapon on every visible hardpoint it fits, per simulated installation.
func _check_subsets() -> void:
	for subset in SUBSETS:
		WeaponLookalike.apply_pack_filter(subset)
		var counts := {}
		for vid in HOSTS:
			var v := Packs.vehicle(vid)
			if v.is_empty():
				continue
			for i in (v.guns as Array).size():
				for w in _bd_weapons():
					if WeaponFit.fits(w, v, i):
						_check_pick(subset, v, i, w, counts)
		print("subset %s: rules %s" % [subset if not subset.is_empty() else "all", counts])


func _bd_weapons() -> Array:
	var out := Packs.weapons.values().filter(func(w): return str(w.pack) == "bd" and str(w.get("category", "herc")) == "herc")
	out.sort_custom(func(a, b): return str(a.id) < str(b.id))
	return out


func _check_pick(subset: Array, v: Dictionary, i: int, w: Dictionary, counts: Dictionary) -> void:
	var plan := HercModel.mount_plan(v, i, w)
	var choice: Dictionary = plan.get("lookalike", {})
	var rule := str(choice.get("rule", ""))
	counts[rule] = int(counts.get(rule, 0)) + 1
	var where := "%s %s #%d %s" % [subset, v.id, i, w.id]
	if plan.look == HercModel.Look.HIDDEN or (not plan.has("shape") and plan.look != HercModel.Look.STAND_IN):
		_fail("%s: nothing drawn (%s)" % [where, HercModel.Look.keys()[int(plan.look)]])
	if rule == "":
		_fail("%s: no decision recorded" % where)
	var src := Packs.weapon(str(choice.get("weapon", ""))) if str(choice.get("weapon", "")) != "" else {}
	if rule.begins_with("archetype") or rule == "family_size":
		if not subset.is_empty() and not subset.has(str(src.get("pack", ""))):
			_fail("%s: %s comes from a pack that is not installed" % [where, src.get("id", "")])
		if rule.begins_with("archetype") and WeaponLookalike.make_archetype(src) != choice.archetype:
			_fail("%s: %s is not a %s" % [where, src.get("id", ""), choice.archetype])
	WeaponLookalike.clear_cache()
	var again: Dictionary = HercModel.mount_plan(v, i, w).get("lookalike", {})
	if again != choice:
		_fail("%s: not deterministic (%s vs %s)" % [where, choice, again])


func _check_expected() -> void:
	for c in EXPECTED:
		var v := Packs.vehicle(str(c[1]))
		var w := Packs.weapon(str(c[3]))
		if v.is_empty() or w.is_empty() or not _installed(c[0]):
			print("expected: %s skipped (not installed)" % [c])
			continue
		WeaponLookalike.apply_pack_filter(c[0])
		var choice: Dictionary = HercModel.mount_plan(v, int(c[2]), w).get("lookalike", {})
		print("expected: %-18s %-18s #%d %-14s -> %s" % [c[0], v.id, c[2], w.id, WeaponLookalike.make_label(choice)])
		if str(choice.get("rule", "")) != str(c[4]) or (str(c[5]) != "" and str(choice.get("weapon", "")) != str(c[5])):
			_fail("%s: got %s" % [c, choice])
	WeaponLookalike.clear_pack_filter()


static func _installed(subset: Array) -> bool:
	return subset.all(func(p): return Assets.installed_packs().has(p))


## Battledrome weapons on a Battledrome Herc: the baked pod on bays, nothing on launchers, no look-alike.
func _check_battledrome_native() -> void:
	var v := Packs.vehicle(BD_HOST)
	if v.is_empty():
		return
	for i in (v.guns as Array).size():
		for w in _bd_weapons():
			if not WeaponFit.fits(w, v, i):
				continue
			var plan := HercModel.mount_plan(v, i, w)
			var want := HercModel.Look.BAKED if v.guns[i].has("pod_cells") else HercModel.Look.HIDDEN
			if plan.look != want or plan.has("lookalike"):
				_fail("%s #%d %s: %s, expected %s" % [v.id, i, w.id, HercModel.Look.keys()[int(plan.look)], HercModel.Look.keys()[want]])


## The models are really built and attached, with a muzzle, for a full Battledrome loadout per host.
func _check_models_built() -> void:
	for subset in SUBSETS:
		WeaponLookalike.apply_pack_filter(subset)
		for vid in HOSTS:
			var v := Packs.vehicle(vid)
			if not v.is_empty():
				await _build_host(v)


func _build_host(v: Dictionary) -> void:
	var host := ShapeInstance.new()
	add_child(host)
	host.build(Assets.shape(str(v.shape)), 0, Packs.default_palette(str(v.pack)))
	var frames := HercModel.mount_nodes(v, host, HercModel.build_mounts(v, host))
	for i in (v.guns as Array).size():
		var w := _first_fitting(v, i)
		var model := HercModel.weapon_model(v, i, w, host.palette_name)
		if model == null:
			_fail("%s #%d %s: no model built" % [v.id, i, w.id])
			continue
		HercModel.attach_weapon_model(frames[i], model, v)
		if HercModel.muzzle_of(frames[i]) == frames[i]:
			_fail("%s #%d %s: no muzzle marker" % [v.id, i, w.id])
	host.queue_free()
	await get_tree().process_frame


func _first_fitting(v: Dictionary, i: int) -> Dictionary:
	for w in _bd_weapons():
		if WeaponFit.fits(w, v, i):
			return w
	return {}
