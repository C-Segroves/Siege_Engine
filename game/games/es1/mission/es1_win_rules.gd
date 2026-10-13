class_name ES1WinRules
extends RefCounted
## Earthsiege 1 mission rules (DBSIM 0xf4e8, docs/formats/mission.md section 5): the player squad's order
## target (group 0's target), its status, the "safe" test, the win test per mission type, the loss of a
## guarded target, and the alert regions (an enemy close by, or a hit).

## Alert region: an enemy within 50000 original units (195 m) or a hit (SIM@e722, SIM@1f496).
const DETECT_RANGE_UNITS := 50000.0
## "Safe" (DBSIM 0xf744): no aware enemy within 80000 units (312 m), 100000 (390 m) if it targets the unit.
const SAFE_RANGE_UNITS := 80000.0
const SAFE_RANGE_TARGETING_UNITS := 100000.0
## Target status (DBSIM 0xee84 / 0xecc0): 0..3 damage levels, 4 destroyed. The sim's damage is 0..255.
const STATUS_LOST := 3
const STATUS_DESTROYED := 4
const DAMAGE_SCALE := 256.0
## Object damage at which status 1 / 2 / 3 begin (DBSIM 0xeef4).
const OBJECT_DAMAGE_STEPS := [50, 128, 192]
## Group: lost members (x 1024 / members) at which status 3 / 2 begin, and the mean damage above which
## status 3 / 2 / 1 begin (DBSIM 0xed93).
const GROUP_LOSS_LOST := 500
const GROUP_LOSS_DAMAGED := 250
const GROUP_LOSS_SCALE := 1024
const GROUP_DAMAGE_STEPS := [50, 128, 192]
## Group order "guarding" (MSN group orders): the squad fails when its guarded target is lost (DBSIM 0xf536).
const ORDER_GUARDING := 6
## Objective flags the sim sets for the player (DBSIM 0x15f80): type 0 (recon) when the player targets an object
## of the squad's order target (+0xd); type 3 (datalink) after standing within 10000 units (39 m) of the order target,
## facing it within 45 degrees, through the link timer (two 5000 ms stages, table 0x91ce8) (+0xe).
const TYPE_RECON := 0
const TYPE_DATALINK := 3
## Mission types (header word 3) by what wins them (DBSIM jump table 0x9173c): reach the last nav point,
## keep the order target safe, destroy the order target.
const NAV_TYPES := [1, 2]
## Escort (DBSIM 0xf4e8, mission.md section 5): the order target reached the end of its path and is alive.
const TYPE_ESCORT := 7
const PROTECT_TYPES := [4, 5]
const DESTROY_TYPES := [6, 8, 9]
const DATALINK_RANGE_UNITS := 10000.0
const DATALINK_CONE := PI / 4.0
const DATALINK_TIME := 10.0

var rt: MissionRuntime
## Recon objective flag (+0xd): a player targeted the squad's order target.
var recon_flag := false
## Datalink objective flag (+0xe): the link with the order target completed.
var datalink_flag := false
var _datalink_t := 0.0


func _init(runtime: MissionRuntime) -> void:
	rt = runtime


## The player squad's order target {kind, index} (MSN group 0 target), or null.
func squad_target() -> Variant:
	var groups := MissionRuntime._arr(rt.m.get("groups"))
	return groups[0].get("target") if not groups.is_empty() else null


## True when the player squad guards its target and that target is heavily damaged or destroyed.
func guarded_target_lost() -> bool:
	var groups := MissionRuntime._arr(rt.m.get("groups"))
	if groups.is_empty() or int(groups[0].get("orders", -1)) != ORDER_GUARDING:
		return false
	var t = squad_target()
	return t is Dictionary and target_status(t) >= STATUS_LOST


func mission_type() -> int:
	return int(rt.m.get("header", {}).get("mission_type", 1))


## Win test by mission type (header word 3, DBSIM jump table 0x9173c). Types 0 / 3 also count as won once every
## active hostile unit and structure is destroyed (remake rule: the player cleared the area instead).
func objective_met() -> bool:
	var t = squad_target()
	var kind := mission_type()
	if kind in NAV_TYPES:
		return rt.nav_index >= rt.nav_points.size()
	if kind == TYPE_ESCORT:
		return escort_arrived(t)
	if kind in PROTECT_TYPES:
		return target_safe(t)
	if kind in DESTROY_TYPES:
		return t is Dictionary and target_status(t) == STATUS_DESTROYED
	if kind == TYPE_RECON:
		return recon_flag or _area_cleared()
	if kind == TYPE_DATALINK:
		return datalink_flag or _area_cleared()
	return _area_cleared()


## Escort test: target `t` is not destroyed and a living unit of it finished its path (a group's leader travels
## the path, its members follow in formation).
func escort_arrived(t) -> bool:
	if not t is Dictionary or target_status(t) == STATUS_DESTROYED:
		return false
	for n in rt.target_nodes(t):
		if is_instance_valid(n) and n.alive and bool(n.get_meta(AIPilot.PATH_DONE_META, false)):
			return true
	return false


## The objectives panel's lines ([{text, done}]): the mission type's goal, then the nav progress.
func make_objective_lines() -> Array:
	var out := []
	var goal := _make_goal_text(mission_type(), _make_target_name())
	if goal != "":
		out.append({"text": goal, "done": objective_met()})
	if not rt.nav_points.is_empty():
		var reached := mini(rt.nav_index, rt.nav_points.size())
		out.append({"text": "Reach the nav points (%d of %d)" % [reached, rt.nav_points.size()],
			"done": reached >= rt.nav_points.size()})
	return out


## What mission type `kind` asks of the player ("" for the nav-point types: their line is the nav progress).
static func _make_goal_text(kind: int, target: String) -> String:
	if kind in PROTECT_TYPES:
		return "Protect %s" % target
	if kind in DESTROY_TYPES:
		return "Destroy %s" % target
	if kind == TYPE_RECON:
		return "Identify %s (target it) or clear the area" % target
	if kind == TYPE_DATALINK:
		return "Establish the data link at %s or clear the area" % target
	if kind == TYPE_ESCORT:
		return "Escort %s to the end of its route" % target
	if kind in NAV_TYPES:
		return ""
	return "Destroy all hostiles"


func _make_target_name() -> String:
	var t = squad_target()
	if t is Dictionary:
		for n in rt.target_nodes(t):
			if is_instance_valid(n) and "display_name" in n and str(n.display_name) != "":
				return str(n.display_name)
	return "the target"


## Host, every rules tick (`dt` seconds): the recon and datalink objective flags.
func update_objective_flags(dt: float) -> void:
	match mission_type():
		TYPE_RECON:
			if not recon_flag and _a_player_targets_order_target():
				recon_flag = true
				rt.battle.fx("message", ["Target identified.", 4.0], true)
		TYPE_DATALINK:
			_update_datalink(dt)


func _a_player_targets_order_target() -> bool:
	var wanted := rt.target_nodes(squad_target())
	for v in _living_players():
		if v.target != null and wanted.has(v.target):
			return true
	return false


func _update_datalink(dt: float) -> void:
	if datalink_flag:
		return
	var link := _datalink_node()
	var linking := false
	for v in _living_players():
		linking = linking or (link != null and _in_datalink_position(v, link))
	if not linking:
		_datalink_t = 0.0
		return
	if _datalink_t == 0.0:
		rt.battle.fx("message", ["Datalink in progress - hold position.", 4.0], true)
	_datalink_t += dt
	if _datalink_t >= DATALINK_TIME:
		datalink_flag = true
		rt.battle.fx("message", ["Datalink complete.", 4.0], true)


## The object the datalink connects to (DBSIM 0x1cda0: a group target's first member).
func _datalink_node() -> Node3D:
	for n in rt.target_nodes(squad_target()):
		if is_instance_valid(n) and n.alive:
			return n
	return null


static func _in_datalink_position(v: Node3D, link: Node3D) -> bool:
	var to := link.global_position - v.global_position
	to.y = 0.0
	if to.length() >= DATALINK_RANGE_UNITS * Assets.UNIT:
		return false
	if to.is_zero_approx():
		return true
	var torso := float(v.get("torso_yaw")) if v.get("torso_yaw") != null else 0.0
	var forward := (v.global_basis * Basis(Vector3.UP, torso)) * Vector3.FORWARD
	forward.y = 0.0
	return forward.angle_to(to) < DATALINK_CONE


func _living_players() -> Array:
	var out := []
	for v in rt.get_tree().get_nodes_in_group("vehicles"):
		if MissionRuntime._is_human_player(v) and v.alive:
			out.append(v)
	return out


## The player squad is safe (DBSIM 0xf743 on the player): the mission ends on status 9 only, not on 10
## (objective complete but enemies still close).
func players_safe() -> bool:
	for v in rt.get_tree().get_nodes_in_group("vehicles"):
		if MissionRuntime._is_human_player(v) and v.alive and not is_safe(v):
			return false
	return true


# ------------------------------------------------------------------ target status

## DBSIM 0xee84: 0..3 damage level, 4 destroyed (a group: all members lost).
func target_status(t: Dictionary) -> int:
	if String(t.get("kind", "")) == "group":
		return _group_status(int(t.get("index", -1)))
	var found := rt.target_nodes(t)
	if found.is_empty():
		return 0
	return _object_status(found[0])


func _object_status(n: Node) -> int:
	if not is_instance_valid(n) or not n.alive:
		return STATUS_DESTROYED
	return _damage_level(_damage_of(n), OBJECT_DAMAGE_STEPS)


func _group_status(gi: int) -> int:
	if rt.dormant_groups.has(gi):
		return 0
	var members := rt.target_nodes({"kind": "group", "index": gi})
	if members.is_empty():
		return 0
	var lost := 0
	var damage := 0.0
	for n in members:
		if not is_instance_valid(n) or not n.alive:
			lost += 1
			damage += DAMAGE_SCALE - 1.0
		else:
			damage += _damage_of(n)
	if lost == members.size():
		return STATUS_DESTROYED
	var loss := lost * GROUP_LOSS_SCALE / members.size()
	var level := _damage_level(damage / members.size(), GROUP_DAMAGE_STEPS)
	if loss >= GROUP_LOSS_LOST:
		return STATUS_LOST
	if loss >= GROUP_LOSS_DAMAGED:
		level = maxi(level, 2)
	return level


static func _damage_level(damage: float, steps: Array) -> int:
	var level := 0
	for s in steps:
		if damage >= float(s):
			level += 1
	return level


## Sim damage 0..255 of a living Herc or structure.
static func _damage_of(n: Node) -> float:
	if n is Structure:
		return (1.0 - n.hp / maxf(n.max_hp, 1.0)) * DAMAGE_SCALE
	return (1.0 - float(n.integrity)) * DAMAGE_SCALE


# ------------------------------------------------------------------ safe test

## DBSIM 0xf99a: the target's group is active and every living target unit is safe.
func target_safe(t) -> bool:
	if not t is Dictionary:
		return false
	if String(t.get("kind", "")) == "group" and rt.dormant_groups.has(int(t.get("index", -1))):
		return false
	var found := rt.target_nodes(t)
	if found.is_empty():
		return false
	for n in found:
		if is_instance_valid(n) and n.alive and not is_safe(n):
			return false
	return true


## DBSIM 0xf744: no living, active enemy close to `u` (closer still counts when it targets `u`). A unit
## outside the player's squad is also unsafe while an enemy group has it as its order target.
func is_safe(u: Node3D) -> bool:
	var squad := u is Herc and (MissionRuntime._is_human_player(u) or int(u.get_meta("group", -1)) == 0)
	for v in rt.active_vehicles():
		if v.team == u.team:
			continue
		if not squad and _group_hunts(v, u):
			return false
		var r := SAFE_RANGE_TARGETING_UNITS if v.target == u else SAFE_RANGE_UNITS
		if v.global_position.distance_to(u.global_position) < r * Assets.UNIT:
			return false
	return true


## True when `v`'s mission group has `u` as its order target (DBSIM 0x1ce3c).
func _group_hunts(v: Node, u: Node) -> bool:
	var gi := int(v.get_meta("group", -1))
	var groups := MissionRuntime._arr(rt.m.get("groups"))
	if gi < 0 or gi >= groups.size():
		return false
	return rt.target_nodes(groups[gi].get("target")).has(u)


# ------------------------------------------------------------------ hostiles and alert regions

## Every active hostile unit and structure is destroyed. Dormant groups do not count: like the sim's safe test
## (DBSIM 0xf744 skips inactive groups) only what is on the map matters; a death that wakes the next wave spawns it
## at once, so a chain of waves is never "cleared" early.
func _area_cleared() -> bool:
	for v in rt.active_vehicles():
		if v.team != 0:
			return false
	for s in rt.structures:
		if s.team != 0 and s.alive:
			return false
	return true


## Fires the alert region of every unit an enemy has come close to (or that was hit).
func update_alerts() -> void:
	var vs := rt.active_vehicles()
	var units := vs.duplicate()
	for s in rt.structures:
		if s.alive:
			units.append(s)
	for u in units:
		var ar := rt.alert_region_of(u)
		if ar >= 0 and ar < rt.regions.size() and not rt.regions[ar].fired and MissionTargets.is_noticed(u, vs, DETECT_RANGE_UNITS):
			rt.fire_region(ar)
