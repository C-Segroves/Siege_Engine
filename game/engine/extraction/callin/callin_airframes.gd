class_name CallinAirframes
extends RefCounted
## The aircraft of the air call-ins: which installed flyer flies a bombing run or a gunship, and building it as an AI
## unit (a normal battle vehicle on every peer: spawned with the spawn message, then carried by EntityTable and the
## snapshots like any other flyer). Nothing here names a pack that may be missing: the rule's list is tried in order,
## then the best installed flyer, then the engine's own plain Skimmer.

## The engine's built-in flyer (Flyer._configure_es1_skimmer): flies with no pack installed at all.
const PLAIN_ID := "es1:SKIMMER"
const PLAIN_LOADOUT := ["es1:LAS100"]
const AI_SKILL := 0.6
## Meta of an aircraft a call-in flies: the peer it works for (kills credit him) and the kind.
const CALLER_META := "callin_caller"
const KIND_META := "callin_kind"


## True when flyer `id` is installed and its content kind enabled.
static func is_usable(id: String) -> bool:
	var v := Packs.vehicle(id)
	if v.is_empty() or not bool(v.get("flyer", false)):
		return false
	return Packs.is_enabled(str(v.pack), "vehicles" if str(v.get("category", "")) == "vehicle" else "hercs")


## The flyer of a call-in whose rules are `rule`: its `airframe_ids` in order, else the best installed flyer for the
## role (`carries_bombs`: a bomber; otherwise the strongest armed flyer), else PLAIN_ID.
static func pick(rule: Dictionary, carries_bombs: bool) -> String:
	for id in rule.get("airframe_ids", []):
		if is_usable(str(id)):
			return str(id)
	var best := ""
	var best_score := -INF
	for v in Packs.pilotable():
		if not is_usable(str(v.id)):
			continue
		var score := make_score(v, carries_bombs)
		if score > best_score:
			best_score = score
			best = str(v.id)
	return best if best != "" else PLAIN_ID


## The airframe the air call-in `kind` flies (the same pick the run makes when it starts).
static func pick_for_kind(kind: String) -> String:
	return pick(CallinRules.rule(kind), kind == CallinRules.KIND_BOMBING)


## The craft's own name (Thundersword, Shrike, Skimmer) as the pack spells it; a pack that spells it in capitals gets title case.
static func make_craft_name(kind: String) -> String:
	return make_name_of(pick_for_kind(kind))


## The name of flyer `id` (see make_craft_name).
static func make_name_of(id: String) -> String:
	var name := str(Packs.vehicle(id).get("name", id.get_slice(":", 1)))
	return name.capitalize() if name == name.to_upper() else name


## How well flyer `v` suits the role: a bomber by the bombs it carries then its mass, a gunship by its combat rating.
static func make_score(v: Dictionary, carries_bombs: bool) -> float:
	if carries_bombs:
		return (1000.0 if not make_bomb_ids(v).is_empty() else 0.0) + float(v.get("mass", 0.0))
	if (v.get("loadout", []) as Array).is_empty():
		return -1.0
	return Packs.combat_rating(v)


## The ids of the bomb weapons in flyer `v`'s loadout.
static func make_bomb_ids(v: Dictionary) -> Array:
	return (v.get("loadout", []) as Array).filter(func(w) -> bool: return str(Packs.weapon(str(w)).get("kind", "")) == "bomb")


## The bomb weapon definition a bombing run drops: the airframe's own bomb, else the rule's ids, else any installed
## bomb, else the rule's plain fallback (it has no id, so clients draw no bomb in flight: the impact fx tells them).
static func make_bomb_def(airframe_id: String, rule: Dictionary) -> Dictionary:
	var own := make_bomb_ids(Packs.vehicle(airframe_id))
	for id in own + rule.get("bomb_ids", []):
		var def := Packs.weapon(str(id))
		if not def.is_empty():
			return def
	for id in Packs.weapons:
		if str(Packs.weapons[id].get("kind", "")) == "bomb":
			return Packs.weapons[id]
	return (rule.get("fallback_bomb", {}) as Dictionary).duplicate(true)


## The weapons a gunship carries: its own loadout, else the plain one.
static func make_loadout(airframe_id: String, rule: Dictionary) -> Array:
	var own: Array = Packs.vehicle(airframe_id).get("loadout", [])
	return own if not own.is_empty() else rule.get("fallback_loadout", PLAIN_LOADOUT)


## The spawn message of an AI flyer `vehicle_id` of `team` at `at` heading `yaw` (plain values: what every peer builds it from).
static func make_spec(net_id: int, vehicle_id: String, team: int, kind: String, at: Vector3, yaw: float, loadout: Array,
		protection: float) -> Dictionary:
	return {"net_id": net_id, "vehicle": vehicle_id, "team": team, "owner": 1, "xf": Transform3D(Basis(Vector3.UP, yaw), at),
		"loadout": loadout, "name": CallinRules.make_label(kind),
		"ai": {"skill": AI_SKILL, "flyer": true}, "protection": protection}


## Host: an AI flyer `vehicle_id` of `team` appears at `at` heading `yaw`, working for `peer`. Null when it would not spawn.
static func build(battle: Battle, vehicle_id: String, team: int, peer: int, kind: String, at: Vector3, yaw: float,
		loadout: Array, protection: float) -> Flyer:
	var spec := make_spec(battle.spawner.allocate_id(), vehicle_id, team, kind, at, yaw, loadout, protection)
	battle.send_spawn(spec)
	var craft := battle.vehicles.get(int(spec.net_id)) as Flyer
	if craft == null:
		push_error("CallinAirframes: %s did not spawn" % vehicle_id)
		return null
	craft.global_position = at   # the spawner lifts an AI flyer to its patrol altitude; this is where the run starts
	craft.rotation.y = yaw
	SupportCraft.mark(craft)
	craft.set_meta(CALLER_META, peer)
	craft.set_meta(KIND_META, kind)
	return craft
