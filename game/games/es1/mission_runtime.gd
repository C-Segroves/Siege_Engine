class_name MissionRuntime
extends MissionRuntimeBase
## Runs an original Earthsiege mission inside a Battle: places structures and nav points,
## spawns unit groups with their orders/formations/paths, keeps region-triggered groups dormant,
## evaluates trigger regions and the mission-type win test (see docs/formats/mission.md).
## Structures and nav points are built on every peer (deterministic); units and rules run on the host.
## Also the base of MissionRuntimeES2 (the same MSN machinery); every game's runtime shares the Battle
## contract of MissionRuntimeBase.

const MECH_SHAPES := ["ROADRUNN", "GUNSLING", "RAPTOR", "TOMAHAWK", "PATRIOT", "PANTHER", "HERCULES",
	"COLOSSUS", "MONGOOSE", "SCORPION", "MIRIMAC", "RAMSES", "ACHILLES", "APOLLO", "BULLDOG", "SPIDER"]
const KIND_HERC := 0
const KIND_FLYER := 1
const KIND_STRUCTURE := 2
const STRUCTURE_NAMES := ["Supply depot", "Herc factory", "Mining facility", "Generator", "Herc hangar",
	"Listening post", "Radar tower", "Refinery", "Gun tower"]
## bases.json row used when a structure type has none: [type, shape index, -, -, hit points].
const DEFAULT_BASE_HP := 15000.0
const RULES_INTERVAL := 0.25
## Distance at which a nav point counts as reached.
const NAV_REACH_RADIUS := 40.0
## Region circles smaller than this (e.g. radius 10) mean "at the nav point".
const MIN_REGION_RADIUS := 30.0
## Player damage levels for the debriefing code: integrity above these is "light" / "medium".
const LIGHT_DAMAGE := 0.8
const MEDIUM_DAMAGE := 0.5
## Debriefing codes (mission var 0, DBSIM 0xf0f0): 2..4 success by damage level; failures follow the
## successes, the last one is "Herc lost" (damage level 3).
const CODE_SUCCESS_BASE := 2
const DAMAGE_HERC_LOST := 3
## The failure debriefings are the last four of the mission's list (one per damage level 0..3).
const FAILURE_DEBRIEFINGS := 4
## End code of a player who left the map after the out-of-bounds warning (code 7; mission.md section 5).
const CODE_LEFT_MAP := 8
## Seconds outside the map before it counts as left: the original's warning time is not traced [L]; the remake
## uses Earthsiege 2's auto-end grace (DBSIM 0x4131ac, es2.md 10.4).
const LEFT_MAP_GRACE := 4.9

var regions := []                 # [{def, fired}]
var group_units := {}             # group index -> Array[Node] (Herc or Structure)
var dormant_groups := {}          # group index -> true until its region fires
var unit_index := {}              # "herc:<i>" / "flyer:<i>" -> spawned Node (MissionTargets)
var player_unit := -1             # herc record index of the player's Herc (-1: replaced by the roster)
var targets: MissionTargets
## Earthsiege 1 objective tests (set up by MissionRuntime.setup; the other games have their own rules).
var win_rules: ES1WinRules
var _elapsed := 0.0
## Lazily built check of the battlefield's solids for unit spawns (make_clear_spawn).
var _clearance: SpawnClearance = null
## Host: the wingmen's radio chatter (null until the squad spawned, or when the pack has no pilot tables).
var wingman_radio: WingmanRadio = null


## Compiles a mission the way the original shell did (conditions, random picks, mission vars).
static func load_resolved(name: String, vars := PackedInt32Array(), seed := -1) -> Dictionary:
	if seed < 0:
		seed = randi() & 0x7fffffff
	return MissionCompiler.load_mission(name, vars, seed, -1, {"resolve_texts": true})


static func world_index(mission: Dictionary) -> int:
	var wf := String(mission.get("header", {}).get("world_file", "WORLD0.WLD")).get_basename().to_upper()
	return int(wf.trim_prefix("WORLD"))


static func to_godot(p: Array) -> Vector3:
	return ShapeInstance.es_to_godot([p[0], p[1], p[2]])


## Original headings: values <= 360 are degrees, otherwise 1/65536 turns (see mission.md).
static func heading_to_yaw(h) -> float:
	if h == null:
		return 0.0
	var v := float(h)
	var rad := deg_to_rad(v) if absf(v) <= 360.0 else v / 65536.0 * TAU
	return -rad


## Yaw looking from `from` towards `to` (Godot: -Z forward).
static func yaw_towards(from: Vector3, to: Vector3) -> float:
	var d := to - from
	return atan2(-d.x, -d.z)

# ------------------------------------------------------------------ launch contract (MissionKinds)
# Every game's runtime answers these the same way; MissionKinds calls them on the runtime's script.

## Points battle `config` at `mission`'s world: Earthsiege WORLD<n>.WLD with its heightmap zone, or the
## engine-schema terrain map a mission names.
static func apply_world_to_config(config: Dictionary, mission: Dictionary) -> void:
	config.world = world_index(mission)
	config.zone = int(mission.get("header", {}).get("zone", 0))
	if mission.get("map") is String and String(mission.map) != "":
		config.map = mission.map


## Earthsiege: the mission's own rules handle a player leaving the map (end codes 7 / 8, mission.md section 5).
static func make_area_rule() -> String:
	return BattleBounds.AREA_MISSION


func setup(p_battle: Node3D, mission: Dictionary, vars := PackedInt32Array()) -> void:
	super.setup(p_battle, mission, vars)
	EsDamageModel.ai_damage_scale = EsDamageModel.make_ai_damage_scale(mission.get("header", {})) if radio_pack() == "es1" else 1.0
	targets = MissionTargets.new(self)
	win_rules = ES1WinRules.new(self)
	for wp in _arr(m.get("player_start", {}).get("waypoints")):
		nav_points.append(to_godot(wp))
	_build_nav_markers()
	_init_regions()
	_build_structures()


## The first waypoint is the drop zone; navigation starts at the next one, which gets a marker.
func _build_nav_markers() -> void:
	nav_index = 1 if nav_points.size() > 1 else 0
	for i in range(1, nav_points.size()):
		var n := Marker3D.new()
		n.position = nav_points[i]
		n.set_meta("label", str(i))
		n.add_to_group("nav_points")
		battle.add_child(n)


func _init_regions() -> void:
	for r in _arr(m.get("regions")):
		regions.append({"def": r, "fired": false})


# ------------------------------------------------------------------ structures (all peers)

## Structure index -> [owning group, slot in its formation], for structures placed by a base group.
func _structure_slots() -> Dictionary:
	var slot := {}
	for g in _arr(m.get("groups")):
		if _kind_code(g) == KIND_STRUCTURE:
			var k := 0
			for mi in _arr(g.get("members")):
				slot[int(mi)] = [g, k]
				k += 1
	return slot


static func _slot_team(slot: Dictionary, i: int) -> int:
	return int(slot[i][0].get("team", 0)) if slot.has(i) else 0


func _build_structures() -> void:
	var bases = Assets.load_json("gameplay/bases.json")
	var rows: Array = bases.get("bases", []) if bases is Dictionary else []
	var slot := _structure_slots()
	var list: Array = _arr(m.get("structures"))
	for i in list.size():
		var s: Dictionary = list[i]
		var t := int(s.get("type", 0))
		var row: Array = rows[t] if t < rows.size() else [t, 0, 0, 0, DEFAULT_BASE_HP]
		var team := _slot_team(slot, i)
		var hp := float(row[4]) if row.size() > 4 else DEFAULT_BASE_HP
		var xf := Transform3D(Basis(Vector3.UP, heading_to_yaw(s.get("heading"))), _structure_position(s, slot.get(i)))
		var name: String = STRUCTURE_NAMES[t] if t < STRUCTURE_NAMES.size() else "Structure"
		_add_structure(i, _es1_base_shape(int(row[1]), team), xf, team, hp, name)


## ES1 base shapes: BASES_<n> for the human side, BASES_E_<n> (at most 5) for the Cybrids.
static func _es1_base_shape(index: int, team: int) -> String:
	return "es1:BASES_%d" % index if team == 0 else "es1:BASES_E_%d" % mini(index, 5)


func _structure_position(s: Dictionary, group_slot) -> Vector3:
	if s.get("position") != null:
		return to_godot(s.position)
	if group_slot == null:
		return Vector3.ZERO
	var g: Dictionary = group_slot[0]
	var pos := to_godot(g.position) if g.get("position") != null else Vector3.ZERO
	return pos + _formation_offset("base", int(g.get("formation", 0)), group_slot[1], heading_to_yaw(g.get("heading")))


func _add_structure(i: int, shape_id: String, xf: Transform3D, team: int, hp: float, display_name: String) -> void:
	var s: Dictionary = m.structures[i]
	var st := Structure.create(battle, shape_id, xf, battle.palette_id, team, hp)
	st.net_id = i
	st.display_name = display_name
	st.health_scale(float(s.get("health", 100)))
	st.destroyed.connect(_on_structure_destroyed.bind(i))
	structures.append(st)


func _kind_code(g: Dictionary) -> int:
	match String(g.get("kind", "herc")):
		"herc": return KIND_HERC
		"flyer": return KIND_FLYER
	return KIND_STRUCTURE


static func _formation_key(kind: String) -> String:
	match kind:
		"mech": return "mech_formations"
		"base": return "base_formations"
	return "flyer_formations"


func _formation_offset(kind: String, form: int, k: int, yaw: float) -> Vector3:
	return make_es1_formation_offset(kind, form, k, yaw)


## Slot `k` of formation `form` for units of `kind` turned by `yaw`: the Earthsiege formations table (metres).
static func make_es1_formation_offset(kind: String, form: int, k: int, yaw: float) -> Vector3:
	var f = Assets.load_json("gameplay/formations.json")
	if not f is Dictionary or k == 0 and kind == "mech":
		return Vector3.ZERO
	var forms: Array = f.get(_formation_key(kind), [])
	if form >= forms.size():
		return Vector3.ZERO
	var slots: Array = forms[form]
	var si := k - 1 if kind == "mech" else k
	if si < 0 or si >= slots.size():
		return Vector3.ZERO
	return _slot_vector(slots[si], yaw)


## A formation table entry (original units, x/y[/z]) turned by the group's yaw.
static func _slot_vector(o: Array, yaw: float) -> Vector3:
	var local := ShapeInstance.es_to_godot([o[0], o[1], o[2] if o.size() > 2 else 0])
	return Basis(Vector3.UP, yaw) * local


## Formation slot offset in the leader's local frame (metres), for AI followers.
func formation_offset_local(k: int) -> Vector3:
	return _formation_offset("mech", 0, k, 0.0)


# ------------------------------------------------------------------ units (host)

## Spawns the player squad (roster) and all non-dormant groups. Called by the host's Battle.
func spawn_units() -> void:
	_spawn_start_groups(1)   # group 0 is the player squad: the roster and the campaign's wingmen
	start_wingman_radio(ES1SquadSpawner.new(self).spawn_squad())


## Host: the pilot radio of the player's wingmen `units` (WingmanRadio, the pack's pilot tables).
func start_wingman_radio(units: Array) -> void:
	if wingman_radio == null:
		wingman_radio = WingmanRadio.create(battle, radio_pack())
		if not wingman_radio.has_tables():
			wingman_radio.free()
			wingman_radio = null
			return
		add_child(wingman_radio)
	for u in units:
		if u is Herc:
			wingman_radio.add_wingman(u)


func _exit_tree() -> void:
	EsDamageModel.ai_damage_scale = 1.0


## The pack whose radio tables this mission speaks (audio/tables/pilot<n>_voice.json).
func radio_pack() -> String:
	return "es1"


## Host: a won mission is called on the radio by a wingman.
func announce_end(success: bool) -> void:
	if success and wingman_radio != null:
		wingman_radio.announce_mission_won()


## Spawns every unit group from `first_group` on that is not waiting for its spawn region.
func _spawn_start_groups(first_group: int) -> void:
	var groups: Array = _arr(m.get("groups"))
	for gi in range(first_group, groups.size()):
		var g: Dictionary = groups[gi]
		if _kind_code(g) == KIND_STRUCTURE:
			continue
		if g.get("spawn_region") != null and int(g.spawn_region) >= 0:
			dormant_groups[gi] = true
			continue
		_spawn_group(gi)


func player_spawn(k: int) -> Transform3D:
	var pos := nav_points[0] if not nav_points.is_empty() else Vector3.ZERO
	var look := nav_points[1] if nav_points.size() > 1 else pos + Vector3.FORWARD
	var xf := Transform3D(Basis(Vector3.UP, yaw_towards(pos, look)), pos)
	xf.origin += xf.basis * squad_slot_offset(k)
	return xf


## Group facing: its heading, else along the first leg of its path.
static func _group_yaw(g: Dictionary, path: Array) -> float:
	if g.get("heading") == null and path.size() > 1:
		return yaw_towards(path[0], path[1])
	return heading_to_yaw(g.get("heading"))


static func _group_base_position(g: Dictionary, path: Array) -> Vector3:
	if g.get("position") != null:
		return to_godot(g.position)
	return path[0] if not path.is_empty() else Vector3.ZERO


func _spawn_group(gi: int) -> void:
	group_units[gi] = ES1UnitSpawner.new(self).spawn_group(gi)


# ------------------------------------------------------------------ triggers & rules (host)

func _physics_process(delta: float) -> void:
	if _over or not multiplayer.is_server():
		return
	_elapsed += delta
	var dt := make_rules_step(delta, RULES_INTERVAL)
	if dt <= 0.0:
		return
	_check_regions()
	win_rules.update_alerts()
	win_rules.update_objective_flags(dt)
	_update_nav()
	_check_end()


func _check_regions() -> void:
	for ri in regions.size():
		var r: Dictionary = regions[ri]
		if r.fired:
			continue
		if _region_occupied(r.def):
			fire_region(ri)


func fire_region(ri: int) -> void:
	var r: Dictionary = regions[ri]
	if r.fired:
		return
	r.fired = true
	var d: Dictionary = r.def
	var of = d.get("on_fire")
	if of is Dictionary:
		_var_op(int(of.get("var", -1)), of.get("op", 0))
	_wake_groups(d)


## Spawns the dormant groups a fired region activates; `arrival` = how they arrive (ES2 region param).
func _wake_groups(region: Dictionary, arrival := 0) -> void:
	for gi in _arr(region.get("activates_groups")):
		if dormant_groups.has(int(gi)):
			dormant_groups.erase(int(gi))
			_spawn_dormant_group(int(gi), arrival)


func _spawn_dormant_group(gi: int, _arrival: int) -> void:
	_spawn_group(gi)


func _region_occupied(d: Dictionary) -> bool:
	var who := String(d.get("type_name", "player"))
	for v in get_tree().get_nodes_in_group("vehicles"):
		if not v.alive or not _region_counts(who, v):
			continue
		for a in _arr(d.get("areas")):
			if _in_area(v.global_position, a):
				return true
	return false


## Which vehicles a region type reacts to (ES1 region type names, tools/mission.py).
static func _region_counts(who: String, v: Node) -> bool:
	match who:
		"player":
			return v.team == 0 and not v.has_meta("ai")
		"player squad", "any human-side unit":
			return v.team == 0
		"any cybrid-side unit":
			return v.team == 1
	return true


func _in_area(p: Vector3, a: Dictionary) -> bool:
	if a.get("shape") == "circle":
		var c := to_godot(a.center)
		var r := maxf(float(a.get("radius", 0)) * Assets.UNIT, MIN_REGION_RADIUS)
		return Vector2(p.x - c.x, p.z - c.z).length() <= r
	if a.has("corner1") and a.has("corner2"):
		var lo := to_godot(a.corner1)
		var hi := to_godot(a.corner2)
		return p.x >= minf(lo.x, hi.x) and p.x <= maxf(lo.x, hi.x) and p.z >= minf(lo.z, hi.z) and p.z <= maxf(lo.z, hi.z)
	return false


## Mission variable update: codes 2 (+=1), 1 (=0), 13..16 (=1..4), or decoded strings "var+=1"/"var=N".
func _var_op(v: int, op) -> void:
	if v < 0 or v >= mission_vars.size():
		return
	if op is String:
		if op == "var+=1":
			mission_vars[v] += 1
		elif op.begins_with("var="):
			mission_vars[v] = int(op.substr(4))
		return
	match int(op):
		2: mission_vars[v] += 1
		1: mission_vars[v] = 0
		13, 14, 15, 16: mission_vars[v] = int(op) - 12


func _update_nav() -> void:
	if nav_index >= nav_points.size():
		return
	for v in get_tree().get_nodes_in_group("vehicles"):
		if _is_human_player(v) and v.alive:
			var p: Vector3 = v.global_position
			var n := nav_points[nav_index]
			if Vector2(p.x - n.x, p.z - n.z).length() < NAV_REACH_RADIUS:
				battle.fx("message", ["Nav point %d reached." % nav_index, 4.0], true)
				nav_index += 1
				battle.fx("nav_index", [nav_index], true)   # co-op: the clients' compass and objectives follow
				return


static func _is_human_player(v: Node) -> bool:
	return v.team == 0 and not v.has_meta("ai")


## The first living human player vehicle, or null.
func _living_player() -> Node3D:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if _is_human_player(v) and v.alive:
			return v
	return null


## A human player vehicle, alive or not, or null.
func _any_player() -> Node3D:
	for v in get_tree().get_nodes_in_group("vehicles"):
		if _is_human_player(v):
			return v
	return null


func _group_wiped_out(gi: int) -> bool:
	for u in group_units.get(gi, []):
		if is_instance_valid(u) and u.alive:
			return false
	return true


## Living vehicles that are not dormant.
func active_vehicles() -> Array:
	var out := []
	for v in get_tree().get_nodes_in_group("vehicles"):
		if v.alive and not v.has_meta("dormant"):
			out.append(v)
	return out


## Scene nodes a mission target {kind, index} refers to (herc / flyer / structure / group).
func target_nodes(t) -> Array:
	return targets.nodes(t)


func group_of(t) -> int:
	return targets.group_of(t)


## "dead" (destroyed; human groups at >= 63.5 % losses), "alive", "pending" (dormant / not spawned).
func target_state(t) -> String:
	return targets.state(t)


## The alert region of a unit's mission record (herc, flyer or structure), -1 if none.
func alert_region_of(u: Node) -> int:
	return targets.alert_region_of(u)


## A destroyed unit runs its record's mission-variable change and fires its death region (SIM@d77c,
## SIM@13699); a wiped-out group runs the group's change (SIM@1d524).
## The objectives panel's lines ([{text, done}], MissionObjectives). Every game's runtime answers for its own
## objectives; Earthsiege asks its mission-type rules.
func make_objective_lines() -> Array:
	return win_rules.make_objective_lines() if win_rules != null else []


func on_unit_destroyed(h: Herc) -> void:
	var rec = _unit_record(h)
	if rec is Dictionary:
		_apply_record_death(rec)
	var gi := int(h.get_meta("group", -1))
	if gi < 0 or not _group_wiped_out(gi):
		return
	var od = m.groups[gi].get("on_destroyed")
	if od is Dictionary:
		_var_op(int(od.get("var", -1)), od.get("op", 0))


## The mission record (herc or flyer) a spawned unit came from, or null.
func _unit_record(h: Herc) -> Variant:
	var hi := int(h.get_meta("herc_index", -1))
	var fi := int(h.get_meta("flyer_index", -1))
	if hi >= 0 and hi < _arr(m.get("hercs")).size():
		return m.hercs[hi]
	if fi >= 0 and fi < _arr(m.get("flyers")).size():
		return m.flyers[fi]
	return null


func _apply_record_death(rec: Dictionary) -> void:
	var od = rec.get("on_death")
	if od is Dictionary:
		_var_op(int(od.get("var", -1)), od.get("op", 0))
	var dr := int(rec.get("death_region", -1)) if rec.get("death_region") != null else -1
	if dr >= 0 and dr < regions.size():
		fire_region(dr)


func _on_structure_destroyed(_s: Structure, _killer: Node, i: int) -> void:
	_apply_record_death(m.structures[i])
	if multiplayer.is_server():
		battle.fx("structure_down", [i], true)


func _check_end() -> void:
	if _living_player() == null:
		end_mission(false, _failure_code(DAMAGE_HERC_LOST), "Your Herc has been destroyed.")
		return
	if make_player_out_seconds() >= LEFT_MAP_GRACE:
		end_mission(false, CODE_LEFT_MAP, "You have left the mission area.")
		return
	if win_rules.guarded_target_lost():
		end_mission(false, _failure_code(_player_damage_level()), "The unit you were guarding has been lost.")
		return
	if win_rules.objective_met() and win_rules.players_safe():
		var code := CODE_SUCCESS_BASE + _player_damage_level()
		end_mission(not _is_failure_code(code), code, "Mission objectives complete.")


## The campaign counts a mission as failed when its debriefing code exceeds the mission type's threshold
## (GO.EXE 0x159e9): e.g. a rescue (type 5) won with heavy damage (code 4) takes the failure branch.
func _is_failure_code(code: int) -> bool:
	return Campaign.is_failure(code, int(m.get("header", {}).get("mission_type", 1)))


## Failure debriefing code for a player damage level 0..3 (the last FAILURE_DEBRIEFINGS of the list), always
## above the mission type's failure threshold.
func _failure_code(damage_level: int) -> int:
	var deb: Array = _arr(m.get("texts", {}).get("debriefings"))
	var first := deb.size() - FAILURE_DEBRIEFINGS + 1
	while not _is_failure_code(first):
		first += 1
	return first + damage_level


## `pos`, moved out onto open ground when a formation slot puts a unit inside or under a building or zone feature
## (a Herc spawned in a trimesh is trapped for good; B0_C4_50's escort wingman was).
func make_clear_spawn(pos: Vector3) -> Vector3:
	if _clearance == null:
		_clearance = SpawnClearance.make(battle)
	return _clearance.make_open_ground_origin(pos)


## Seconds the longest-outside living human player has spent outside the battle area (BattleBounds; 0 inside).
func make_player_out_seconds() -> float:
	var bounds: Node = battle.get("bounds") if battle != null else null
	if bounds == null:
		return 0.0
	var worst := 0.0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if _is_human_player(v) and v.alive:
			worst = maxf(worst, bounds.make_out_seconds(v))
	return worst


## 0 light, 1 medium, 2 heavy damage of the worst human player Herc.
func _player_damage_level() -> int:
	var worst := 1.0
	for v in get_tree().get_nodes_in_group("vehicles"):
		if _is_human_player(v):
			worst = minf(worst, v.integrity)
	return 0 if worst > LIGHT_DAMAGE else (1 if worst > MEDIUM_DAMAGE else 2)


## Earthsiege: a won mission is called on the radio by a living wingman.
func apply_end(success: bool) -> void:
	announce_end(success)


## Earthsiege: `text` followed by the MSN debriefing the code selects (1-based).
func make_debriefing_text(code: int, text: String) -> String:
	var deb: Array = _arr(m.get("texts", {}).get("debriefings"))
	if code >= 1 and code - 1 < deb.size():
		return text + "\n" + String(deb[code - 1])
	return text


static func _arr(v) -> Array:
	return v if v is Array else []
