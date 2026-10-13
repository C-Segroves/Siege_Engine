class_name MissionCompilerES2
extends RefCounted
## Earthsiege 2 mission compiler: runtime port of tools/mission_es2.py (Compiler + resolve()).
## Data: gamedata/es2/missions/ (python tools/mission_es2.py export): msn/<NAME>.json parsed records,
## eng/<NAME>.json text tables, tables.json, campaign.json. Format: docs/formats/es2.md section 10.
##
##   var m := MissionCompilerES2.load_mission("C1_01", PackedInt32Array(), 1234)
##   (or MissionCompiler.load_mission("es2:C1_01", ...), which delegates here)
##
## Output equals mission_es2.mission_json(name, seed, mvars, campaign) (checked by
## tools/tests/test_mission_port_es2.py). Random numbers: MissionCompiler.Rng (CPython MT19937).

const PACK := "es2"
const DIR := "missions"
const NVARS := 1000
## The Earthsiege 2 record compiler (VSHELL 0x417b67).
const Compiler2 = preload("res://games/es1/mission/es2_msn_compiler.gd")
const Resolver = preload("res://games/es1/mission/es2_mission_resolver.gd")
const HERC_TYPES := Resolver.HERC_TYPES
const FLYER_TYPES := Resolver.FLYER_TYPES
const GROUP_KINDS := Resolver.GROUP_KINDS
const TARGET_KINDS := Resolver.TARGET_KINDS
const REGION_TARGET_TYPES := Resolver.REGION_TARGET_TYPES

static var _cache := {}


## campaign: MissionCompiler.CAMPAIGN_AUTO (-1, from the C<n>_ name), CAMPAIGN_SINGLE (-2) or 1..5.
static func load_mission(name: String, mission_vars: PackedInt32Array = PackedInt32Array(), seed := -1,
		campaign := -1, _options := {}) -> Dictionary:
	var base := normalize_name(name)
	var raw = _load("msn/%s.json" % base)
	if raw == null:
		push_error("MissionCompilerES2: mission %s not found" % base)
		return {}
	var eng = _load("eng/%s.json" % base)
	var camp = campaign
	if campaign == MissionCompiler.CAMPAIGN_AUTO:
		camp = guess_campaign(base)
	elif campaign < 0:
		camp = null
	var mvars = MissionCompiler.padded_vars(mission_vars, NVARS)
	var comp = Compiler2.new(raw, eng if eng != null else [], mvars, MissionCompiler.Rng.new(seed), camp)
	comp.run()
	return Resolver.new(comp).build_mission(base, seed, camp)


static func normalize_name(name: String) -> String:
	var n := name.get_file().to_upper()
	if n.begins_with("ES2:"):
		n = n.substr(4)
	if n.ends_with(".MSN"):
		n = n.substr(0, n.length() - 4)
	return n


static func guess_campaign(name: String) -> Variant:
	var re := RegEx.create_from_string("^C(\\d)_\\d+")
	var m := re.search(normalize_name(name))
	return int(m.get_string(1)) if m != null else null


static func mission_names() -> Array:
	var idx = _load("index.json")
	return idx["missions"] if idx != null else []


static func campaign_data() -> Dictionary:
	var c = _load("campaign.json")
	return c if c != null else {}


static func default_mission_vars(campaign: Variant = null, slot := 0, rng: MissionCompiler.Rng = null) -> Array:
	if rng == null:
		rng = MissionCompiler.Rng.new(-1)
	var v := []
	v.resize(NVARS)
	v.fill(0)
	v[MissionCompiler.VAR_CAMPAIGN] = campaign if campaign != null else MissionCompiler.SINGLE_MISSION_CAMPAIGN
	v[MissionCompiler.VAR_SLOT] = slot
	MissionCompiler.roll_shell_randoms(v, rng)
	return v


static func _load(rel: String) -> Variant:
	if _cache.has(rel):
		return _cache[rel]
	var j = Assets.load_json(DIR.path_join(rel), PACK)
	if j != null:
		j = MissionCompiler._ints(j)
	_cache[rel] = j
	return j


static func clear_cache() -> void:
	_cache.clear()
