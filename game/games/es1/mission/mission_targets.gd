class_name MissionTargets
extends RefCounted
## Earthsiege 1 / 2 mission targets ({kind: herc|flyer|structure|group, index}) resolved to scene nodes,
## and their state as the objective and order tests see it (MissionRuntime, MissionRuntimeES2).

## A human group counts as destroyed at this fraction of losses (Earthsiege 2 DBSIM objective test).
const HUMAN_GROUP_LOSS := 0.635

var rt: MissionRuntime


func _init(runtime: MissionRuntime) -> void:
	rt = runtime


## Scene nodes a mission target {kind, index} refers to (herc / flyer / structure / group).
func nodes(t) -> Array:
	if not t is Dictionary:
		return []
	var idx := int(t.get("index", -1)) if t.get("index") != null else -1
	match String(t.get("kind", "")):
		"herc":
			return _herc_target(idx)
		"flyer":
			return [rt.unit_index["flyer:%d" % idx]] if rt.unit_index.has("flyer:%d" % idx) else []
		"structure":
			return [rt.structures[idx]] if idx >= 0 and idx < rt.structures.size() else []
		"group":
			return _group_target(idx)
	return []


func _herc_target(idx: int) -> Array:
	if idx == rt.player_unit and rt.player_unit >= 0:
		var me := rt._any_player()
		return [me] if me else []
	return [rt.unit_index["herc:%d" % idx]] if rt.unit_index.has("herc:%d" % idx) else []


func _group_target(idx: int) -> Array:
	var out := []
	if idx == 0:
		var me := rt._any_player()
		if me:
			out.append(me)
	if idx >= 0 and idx < MissionRuntime._arr(rt.m.get("groups")).size() and rt._kind_code(rt.m.groups[idx]) == MissionRuntime.KIND_STRUCTURE:
		for mi in MissionRuntime._arr(rt.m.groups[idx].get("members")):
			if int(mi) < rt.structures.size():
				out.append(rt.structures[int(mi)])
	for u in rt.group_units.get(idx, []):
		out.append(u)
	return out


func group_of(t) -> int:
	if not t is Dictionary:
		return -1
	if t.get("kind") == "group":
		return int(t.get("index", -1))
	for n in nodes(t):
		if n is Herc:
			return int(n.get_meta("group", 0 if not n.has_meta("ai") else -1))
	return -1


## "dead" (destroyed; human groups at >= 63.5 % losses), "alive", "pending" (dormant / not spawned).
func state(t) -> String:
	if not t is Dictionary:
		return "alive"
	if String(t.get("kind")) == "group" and rt.dormant_groups.has(int(t.get("index", -1))):
		return "pending"
	var found := nodes(t)
	if found.is_empty():
		return "pending"
	var dead := 0
	var human := false
	for n in found:
		if not is_instance_valid(n) or not n.alive:
			dead += 1
		if is_instance_valid(n) and n.team == 0:
			human = true
	if dead == found.size():
		return "dead"
	if human and String(t.get("kind")) == "group" and float(dead) / found.size() >= HUMAN_GROUP_LOSS:
		return "dead"
	return "alive"


## The alert region of a unit's mission record (herc, flyer or structure), -1 if none.
func alert_region_of(u: Node) -> int:
	var rec := _record_of(u)
	return int(rec.get("alert_region", -1)) if not rec.is_empty() else -1


func _record_of(u: Node) -> Dictionary:
	if u.has_meta("herc_index") and int(u.get_meta("herc_index")) < MissionRuntime._arr(rt.m.get("hercs")).size():
		return rt.m.hercs[int(u.get_meta("herc_index"))]
	if u.has_meta("flyer_index") and int(u.get_meta("flyer_index")) < MissionRuntime._arr(rt.m.get("flyers")).size():
		return rt.m.flyers[int(u.get_meta("flyer_index"))]
	if u is Structure and int(u.net_id) < MissionRuntime._arr(rt.m.get("structures")).size():
		return rt.m.structures[int(u.net_id)]
	return {}

