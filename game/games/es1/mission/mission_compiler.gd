class_name MissionCompiler
extends RefCounted
## Runtime port of tools/mission.py: the shell's per-play mission "compile" step (GO.EXE 0x3276c)
## plus the mission_json() resolution. Data comes from gamedata/<pack>/missions/ written by
## tools/export_missions.py (parsed but unevaluated MSN records, ENG chunks, name tables, zones).
## See docs/formats/mission.md.
##
##   var m := MissionCompiler.load_mission("B0_C0_0A", PackedInt32Array(), 1234)
##
## Output is identical to mission_json(name, seed, mvars, campaign, options, with_raw=False,
## with_zone=True) (checked by game/tests/test_mission_compiler.gd + tools/tests/test_mission_port.py).
## The random generator is an exact port of CPython's random.Random (MT19937, init_by_array,
## randrange via getrandbits rejection sampling), so equal seeds give equal missions.

const PACK := "es1"
const DIR := "missions"
const CAMPAIGN_AUTO := -1      ## campaign from the B?_C<n>_ file name, SM_* -> single mission
const CAMPAIGN_SINGLE := -2    ## force single-mission mode

## CPython-compatible random generator (kept as MissionCompiler.Rng for existing callers).
const Rng = preload("res://games/es1/mission/mission_rng.gd")
## The Earthsiege 1 record compiler (GO.EXE 0x3276c).
const Compiler = preload("res://games/es1/mission/es1_msn_compiler.gd")
const Resolver = preload("res://games/es1/mission/es1_mission_resolver.gd")
const MISSION_VAR_COUNT := 100
## mission.var slots the shell fills before compiling (GO 0x359d9).
const VAR_CAMPAIGN := 1
const VAR_SLOT := 2
const VAR_TIME_OF_DAY := 3
const VAR_RANDOM_FIRST := 4
const VAR_RANDOM_LAST := 6
const SINGLE_MISSION_CAMPAIGN := 99
const DEFAULT_OPTIONS := {"ammo": 1, "damage": 1, "difficulty": 2, "visibility": 0, "time_of_day": 0}

static var _cache := {}


## name: MSN base name ("B0_C0_0A", case-insensitive, ".MSN" optional).
## mission_vars: 100 mission variables; empty -> the shell defaults (default_mission_vars).
## seed: >= 0 random seed; -1 = no randomness (every random(n) returns 0, like Rng(None)).
## campaign: CAMPAIGN_AUTO (-1), CAMPAIGN_SINGLE (-2) or a campaign index 0..7.
## options: ammo, damage, difficulty, visibility, time_of_day (single missions);
##   extra key "resolve_texts": true resolves ENG switch blocks with the mission vars
##   (default: unresolved placeholders, as mission_json does).
static func load_mission(name: String, mission_vars: PackedInt32Array = PackedInt32Array(), seed := -1,
		campaign := -1, options := {}) -> Dictionary:
	if name.to_lower().begins_with("es2:"):
		# Earthsiege 2 layout (docs/formats/es2.md section 10)
		return MissionCompilerES2.load_mission(name, mission_vars, seed, campaign, options)
	var base := normalize_name(name)
	var raw = _load("msn/%s.json" % base)
	if raw == null:
		push_error("MissionCompiler: mission %s not found" % base)
		return {}
	var camp = campaign
	if campaign == CAMPAIGN_AUTO:
		camp = guess_campaign(base)
	elif campaign < 0:
		camp = null
	var comp = Compiler.new(raw, padded_vars(mission_vars, MISSION_VAR_COUNT), Rng.new(seed), camp, options)
	comp.run()
	var texts = null
	var eng = _load("eng/%s.json" % base)
	if eng != null:
		texts = eng_texts(eng, comp.vars if options.get("resolve_texts", false) else null)
	return Resolver.new(tables(), comp).build_mission(base, raw, {"seed": seed, "campaign": camp, "texts": texts})


## Mission vars as the compiler takes them: null (shell defaults) when none are given, else
## exactly `count` values (missing ones 0).
static func padded_vars(mission_vars: PackedInt32Array, count: int) -> Variant:
	if mission_vars.size() == 0:
		return null
	var mvars := []
	for i in count:
		mvars.append(mission_vars[i] if i < mission_vars.size() else 0)
	return mvars


static func normalize_name(name: String) -> String:
	var n := name.get_file().to_upper()
	if n.ends_with(".MSN"):
		n = n.substr(0, n.length() - 4)
	return n


## Campaign index from a "B<n>_C<k>_..." name, null for anything else (single missions).
static func guess_campaign(name: String) -> Variant:
	var re := RegEx.create_from_string("^B\\d_C(\\d)_")
	var m := re.search(normalize_name(name))
	return int(m.get_string(1)) if m != null else null


static func mission_names() -> Array:
	var idx = _load("index.json")
	return idx["missions"] if idx != null else []


static func tables() -> Dictionary:
	var t = _load("tables.json")
	return t if t != null else {}


## mission.var as the shell prepares it before compiling (GO 0x359d9).
static func default_mission_vars(campaign: Variant = null, slot := 0, options := {}, rng: Rng = null) -> Array:
	if rng == null:
		rng = Rng.new(-1)
	var opts := _options(options)
	var v := []
	v.resize(MISSION_VAR_COUNT)
	v.fill(0)
	if campaign != null:
		v[VAR_CAMPAIGN] = campaign
		v[VAR_SLOT] = slot
	else:
		v[VAR_CAMPAIGN] = SINGLE_MISSION_CAMPAIGN
	v[VAR_TIME_OF_DAY] = opts["time_of_day"]
	roll_shell_randoms(v, rng)
	return v


## Vars 4..6: three random(12) rolls of the shell.
static func roll_shell_randoms(v: Array, rng: Rng) -> void:
	for i in range(VAR_RANDOM_FIRST, VAR_RANDOM_LAST + 1):
		v[i] = rng.call_n(12)


## Flatten ENG chunks: briefing text, objective strings, debriefing list. mvars null -> switch
## blocks are listed as "{varN: lo..hi: text | ...}" placeholders (tools/mission.py eng_texts).
static func eng_texts(chunks: Array, mvars = null) -> Dictionary:
	var brief := []
	var obj := []
	var deb := []
	for ch in chunks:
		var parts := _flat(ch, mvars)
		match ch["tag"]:
			"BRF": brief.append(" ".join(parts))
			"OBJ": obj.append(parts)
			"DEB": deb.append(" ".join(parts))
	return {"briefing": brief[0] if brief.size() > 0 else "",
		"objectives": obj[0] if obj.size() > 0 else [], "debriefings": deb}


static func _flat(ch: Dictionary, mvars) -> PackedStringArray:
	var out := PackedStringArray()
	for s in ch["segments"]:
		if s is String:
			out.append(s)
		elif mvars != null:
			var v: int = mvars[s["switch_var"]]
			for c in s["cases"]:
				if c["lo"] <= v and v <= c["hi"]:
					out.append(c["text"])
		else:
			var cs := PackedStringArray()
			for c in s["cases"]:
				cs.append("%d..%d: %s" % [c["lo"], c["hi"], c["text"]])
			out.append("{var%d: %s}" % [s["switch_var"], " | ".join(cs)])
	return out


static func _options(options: Dictionary) -> Dictionary:
	var o := DEFAULT_OPTIONS.duplicate()
	var d = tables().get("default_options")
	if d != null:
		o = d.duplicate()
	for k in options:
		o[k] = options[k]
	return o


# ------------------------------------------------------------------ data loading

static func _load(rel: String) -> Variant:
	if _cache.has(rel):
		return _cache[rel]
	var j = Assets.load_json(DIR.path_join(rel), PACK)
	if j != null:
		j = _ints(j)
	_cache[rel] = j
	return j


## JSON numbers arrive as floats; all mission data is integral.
static func _ints(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			return int(v)
		TYPE_ARRAY:
			var a := []
			a.resize(v.size())
			for i in v.size():
				a[i] = _ints(v[i])
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _ints(v[k])
			return d
	return v


static func clear_cache() -> void:
	_cache.clear()
