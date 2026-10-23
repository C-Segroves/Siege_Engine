class_name ES1WinRules
extends RefCounted
## Earthsiege 1 mission rules (DBSIM 0xf4e8, docs/formats/mission.md section 5): the player squad's order
## target (group 0's target), its status, the "safe" test, the win test per mission type, the loss of a
## guarded target, and the alert regions (an enemy close by, or a hit).

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
## facing it within 45 degrees, through the link stages below (+0xe). The mission is won on that flag (and the
## players being safe) alone: DBSIM 0xf618 has no "area cleared" alternative.
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
## Link stages (DBSIM 0x15f80, counter 0xaf700, timer 0xaf705, table 0x91ce8): each stage fires when the timer is out,
## shows SYSTEM.STR message 29 + stage, then loads TABLE[stage] ms. Stage 0 fires at once (5 s), stage 1 after 5 s (5 s),
## stage 2 after 5 s (a negative value: the timer is out on the next frame), stage 3 completes the link. Leaving the
## position after stage 0 shows message 33 and restarts from stage 0 (no pause).
const DATALINK_STAGE_MS := [5000, 5000, -25536, 0]
## SYSTEM.STR texts 29..33 (the sim's own message line; no voice clips exist for them).
const DATALINK_TEXTS := ["ENGAGING COMPUTER LINK", "BEGINNING DATA TRANSFER", "TRANSFERRING DATA...",
	"DATA TRANSFER COMPLETE"]
const DATALINK_ABORT_TEXT := "TRANSFER ABORTED"
const DATALINK_MESSAGE_SECONDS := 4.0
## Seconds the "Target identified." line stays up.
const RECON_MESSAGE_SECONDS := 4.0
const TEXT_RECON_DONE := "Target identified."
const NAV_TEXT := "Reach the nav points (%d of %d)"

var rt: MissionRuntime
## What the shared mission blocks ask of the battle.
var world: ES1MissionWorld
## Recon objective flag (+0xd): a player targeted the squad's order target.
var recon_flag: bool:
	get: return _recon != null and _recon.is_done()
## Datalink objective flag (+0xe): the link with the order target completed.
var datalink_flag: bool:
	get: return _link != null and _link.is_done()
## Link stages shown since the link (re)started.
var _datalink_stage: int:
	get: return _link.get_fired_count() if _link != null else 0
var _objectives := ObjectiveSet.new()
var _goal: Objective = null          # the mission type's goal (null for the nav types: the nav line is their goal)
var _nav: ConditionObjective
var _recon: ScriptObjective = null
var _link: RelayScanObjective = null


func _init(runtime: MissionRuntime) -> void:
	rt = runtime
	world = ES1MissionWorld.new(runtime)
	_build_objectives()


## The objective of the mission type (the factory of DBSIM jump table 0x9173c) and the nav progress line.
func _build_objectives() -> void:
	var kind := mission_type()
	_nav = ConditionObjective.new("nav", "", _is_nav_complete)
	if kind in NAV_TYPES:
		_objectives.apply_add(_nav)
		return
	_goal = _make_goal_objective(kind)
	_objectives.apply_add(_goal)
	_nav.required = false
	_nav.primary = false
	_objectives.apply_add(_nav)


func _make_goal_objective(kind: int) -> Objective:
	if kind == TYPE_ESCORT:
		return ConditionObjective.new("goal", "", _is_escort_done)
	if kind in PROTECT_TYPES:
		return ConditionObjective.new("goal", "", _is_target_protected)
	if kind in DESTROY_TYPES:
		return DestroyObjective.new("goal", "", [ES1MissionWorld.ORDER_TARGET] as Array[String])
	if kind == TYPE_RECON:
		_recon = ScriptObjective.new("goal")
		return _recon
	if kind == TYPE_DATALINK:
		_link = _make_datalink_objective()
		return ConditionObjective.new("goal", "", _is_link_or_cleared)
	return ConditionObjective.new("goal", "", _area_cleared)


## The datalink as a scan: the original stages with their texts, within the link range (10000 units) and 45 degrees.
func _make_datalink_objective() -> RelayScanObjective:
	var stages := []
	for i in DATALINK_STAGE_MS.size():
		stages.append({"seconds": DATALINK_STAGE_MS[i] / 1000.0, "text": DATALINK_TEXTS[i]})
	var link := RelayScanObjective.new("link", "", ES1MissionWorld.DATALINK_TARGET, DATALINK_RANGE_UNITS * Assets.UNIT, stages)
	link.abort_text = DATALINK_ABORT_TEXT
	link.message_seconds = DATALINK_MESSAGE_SECONDS
	return link


func _is_nav_complete() -> bool:
	return rt.nav_index >= rt.nav_points.size()


func _is_escort_done() -> bool:
	return escort_arrived(squad_target())


func _is_target_protected() -> bool:
	return target_safe(squad_target())


func _is_link_or_cleared() -> bool:
	return datalink_flag or _area_cleared()


## The player squad's order target {kind, index} (MSN group 0 target), or null.
func squad_target() -> Variant:
	var groups := MissionRuntime._arr(rt.m.get("groups"))
	return groups[0].get("target") if not groups.is_empty() else null


## True when the player squad's order is to guard its target (DBSIM 0xf536): the squad fails when that target is lost.
func is_squad_guarding() -> bool:
	var groups := MissionRuntime._arr(rt.m.get("groups"))
	return not groups.is_empty() and int(groups[0].get("orders", -1)) == ORDER_GUARDING and squad_target() is Dictionary


func mission_type() -> int:
	return int(rt.m.get("header", {}).get("mission_type", 1))


## Win test by mission type (header word 3, DBSIM jump table 0x9173c). Types 0 and 3 are won on their flag alone (the
## caller also requires the players to be safe).
func objective_met() -> bool:
	_refresh_objectives()
	return _objectives.is_complete()


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
	_refresh_objectives()
	var lines := []
	for line in _objectives.make_lines():
		if line.text != "":
			lines.append(line)
	return lines


## Brings the objectives' state and texts up to the world as it is now (the tests of the types are live, not latched).
func _refresh_objectives() -> void:
	if _goal != null:
		_goal.text = _make_goal_text(mission_type(), _make_target_name())
	_nav.text = NAV_TEXT % [mini(rt.nav_index, rt.nav_points.size()), rt.nav_points.size()] if not rt.nav_points.is_empty() else ""
	_objectives.apply_tick(world, 0.0)


## What mission type `kind` asks of the player ("" for the nav-point types: their line is the nav progress).
static func _make_goal_text(kind: int, target: String) -> String:
	if kind in PROTECT_TYPES:
		return "Protect %s" % target
	if kind in DESTROY_TYPES:
		return "Destroy %s" % target
	if kind == TYPE_RECON:
		return "Identify %s (target it)" % target
	if kind == TYPE_DATALINK:
		return "Establish the data link at %s" % target
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


## Host, every rules tick (`dt` seconds): the recon flag and the datalink.
func update_objective_flags(dt: float) -> void:
	match mission_type():
		TYPE_RECON:
			if not recon_flag and _a_player_targets_order_target():
				_recon.apply_state(Objective.State.DONE)
				rt.get_announcer().apply_say(MissionMessage.make_message(TEXT_RECON_DONE, RECON_MESSAGE_SECONDS, MissionMessage.CHANNEL_INFO))
		TYPE_DATALINK:
			_link.apply_tick(world, dt)


func _a_player_targets_order_target() -> bool:
	var wanted := rt.target_nodes(squad_target())
	for v in get_living_players():
		if v.target != null and wanted.has(v.target):
			return true
	return false


## The object the datalink connects to (DBSIM 0x1cda0: a group target's first member).
func _datalink_node() -> Node3D:
	for n in rt.target_nodes(squad_target()):
		if is_instance_valid(n) and n.alive:
			return n
	return null


func get_living_players() -> Array:
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
		if ProximityAlert.is_unsafe_from(v, u, EsSensorProfile.make()):
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
		if ar >= 0 and ar < rt.regions.size() and not rt.regions[ar].fired and ProximityAlert.is_noticed(u, vs, EsSensorProfile.make()):
			rt.fire_region(ar)
