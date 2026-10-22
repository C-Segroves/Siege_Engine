extends RefCounted
## The campaign half of the spawn audit (spawn_audit_check.gd, --only=missions[:<pack>]): every campaign / training mission is
## started in a real Battle (the config its game's launcher builds), and the places its runtime put its units and the player
## at - a start transform per unit, as the mission runtimes' spawn path made it (MissionRuntime.player_spawn, the unit
## spawners' clearance and ground snapping) - become the points of the audit. Units that arrive later (dormant groups,
## reinforcement waves) and flyers (they start in the air) are not part of it.

const SETTLE_FRAMES := 1
const DEFAULT_HERC := {"es1": "es1:RAPTOR", "es2": "es2:OUTLAW", "starsiege": "starsiege:pi_eman"}
const CAMPAIGN_PACKS := ["tribes_aa", "tribes_v"]
const TRAINING_PACKS := ["tribes", "tribes2"]
const KIND_PLAYER := "player"
const KIND_UNIT := "unit"


## The mission jobs of `pack` ("" = every pack): [{pack, id, name, make_config: Callable() -> Dictionary}].
static func make_jobs(pack: String) -> Array:
	var jobs := []
	if (pack == "" or pack == "es1") and Assets.has_pack("es1"):
		for n in MissionCompiler.mission_names():
			jobs.append(_make_es_job("es1", str(n), str(n)))
	if (pack == "" or pack == "es2") and Assets.has_pack("es2"):
		for n in MissionCompilerES2.mission_names():
			jobs.append(_make_es_job("es2", "es2:" + str(n), str(n)))
	if (pack == "" or pack == "starsiege") and Assets.has_pack("starsiege"):
		for f in DirAccess.get_files_at(Assets.data_root.path_join("starsiege").path_join("missions")):
			if f.ends_with(".json"):
				jobs.append(_make_mission_name_job("starsiege", "starsiege:" + f.get_basename().to_upper(), f.get_basename().to_upper()))
	for p in TRAINING_PACKS:
		if (pack == "" or pack == p) and Assets.has_pack(p):
			for e in TribesMissionRuntime.list_missions(p):
				jobs.append(_make_training_job(p, e))
	for p in CAMPAIGN_PACKS:
		if (pack == "" or pack == p) and Assets.has_pack(p) and Assets.has_pack("tribes2"):
			jobs.append_array(_make_campaign_jobs(p))
	return jobs


static func _make_es_job(pack: String, compile_name: String, label: String) -> Dictionary:
	var vehicle: String = DEFAULT_HERC[pack]
	return {"pack": "missions:" + pack, "id": "mission:%s:%s" % [pack, label], "name": label, "make_config": func() -> Dictionary:
		var m := MissionCompiler.load_mission(compile_name, PackedInt32Array(), 1, -1, {"resolve_texts": true})
		if m.is_empty():
			return {}
		return {"mode": "mission", "respawn": false, "mission": m,
			"roster": {1: {"name": "Audit", "vehicle": vehicle, "team": 0, "loadout": []}}}}


static func _make_mission_name_job(pack: String, mission_name: String, label: String) -> Dictionary:
	return {"pack": "missions:" + pack, "id": "mission:" + mission_name, "name": label, "make_config": func() -> Dictionary:
		return {"mode": "mission", "mission_name": mission_name, "respawn": false,
			"roster": {1: {"name": "Audit", "vehicle": DEFAULT_HERC[pack], "team": 0, "loadout": []}}}}


static func _make_training_job(pack: String, e: Dictionary) -> Dictionary:
	var mission_name := "%s:%s" % [pack, str(e.get("id", ""))]
	return {"pack": "missions:" + pack, "id": "mission:" + mission_name, "name": str(e.get("name", e.get("id", ""))), "make_config": func() -> Dictionary:
		return {"mode": "mission", "mission_name": mission_name, "respawn": false,
			"roster": MatchFlow.make_solo_roster(str(e.get("armor", "")), [])}}


## One job per mission of the pack's campaign (Session's stage campaign, the mission picked by index).
static func _make_campaign_jobs(pack: String) -> Array:
	Session.start_stage_campaign(pack)
	var total: int = Session.campaign.missions.size()
	var jobs := []
	for i in total:
		var label := str(Session.campaign.missions[i].get("name", i)) if Session.campaign.missions[i] is Dictionary else str(i)
		jobs.append({"pack": "missions:" + pack, "id": "mission:%s:%d %s" % [pack, i, label], "name": label, "make_config": func() -> Dictionary:
			Session.start_stage_campaign(pack)
			Session.campaign.index = i
			return MatchFlow.make_mission_config(str(MatchFlow.make_issued_soldier().get("vehicle", "")), [], {})})
	return jobs


## The points of a started mission battle: where its player and units stand (flyers left out). A point is the audit's
## {kind, label, xf, hercs, soldier_on_ground} shape; `hercs` is whether a vehicle stood there.
static func collect(battle: Battle) -> Array:
	var out: Array = []
	var seen := {}
	var ids := battle.vehicles.keys()
	ids.sort()
	for id in ids:
		var v: Herc = battle.vehicles[id]
		if not is_instance_valid(v) or v is Flyer or (v is Infantry and (v as Infantry).stowed):
			continue
		var is_soldier := v is Infantry
		var kind := KIND_PLAYER if v == battle.player else KIND_UNIT
		var o := v.global_position
		var key := "%d|%d|%d" % [roundi(o.x * 20.0), roundi(o.y * 20.0), roundi(o.z * 20.0)]
		if seen.has(key):
			continue
		seen[key] = true
		var xf := Transform3D(Basis(Vector3.UP, v.rotation.y), o)
		out.append({"kind": kind, "label": "%s %s #%d (%s)" % [kind, v.vehicle_id.get_slice(":", 1), id, "team %d" % v.team], "xf": xf,
			"hercs": not is_soldier, "soldier_on_ground": false})
	return out
