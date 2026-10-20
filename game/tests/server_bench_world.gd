extends RefCounted
## The match a tests/server_load_bench stage hosts: Varuna's Fall (an extraction raid, when the Tribes 2 pack is
## installed) or a fallback (a versus match on the first installed map), the synthetic humans' roster, and the
## bots on top of whatever the match populates itself.

const KIND_VARUNA := "varuna"
const KIND_FALLBACK := "fallback"
const FRAG_LIMIT_NEVER := 1000000
const SCATTER_MIN_M := 10.0
const SCATTER_SPAN_M := 40.0
const SCATTER_STEP_RAD := 2.4
const BOTS_PER_FRAME := 10
const HUMAN_VEHICLE := "es1:RAPTOR"
const FALLBACK_AI_VEHICLE := "es1:SCORPION"

var kind := KIND_FALLBACK
var _anchors: Array[Vector3] = []


## "varuna" when `wanted` is "auto" and the map exists, else what `wanted` names.
static func make_kind(wanted: String) -> String:
	if wanted == KIND_FALLBACK:
		return KIND_FALLBACK
	return KIND_VARUNA if VarunaMap.is_available() else KIND_FALLBACK


## Fills Net.roster with `peers` (the synthetic humans) and returns the battle config of the match.
func make_config(p_kind: String, peers: Array, bots: int) -> Dictionary:
	kind = p_kind
	Net.roster.clear()
	for id in peers:
		Net.roster[id] = {"name": "Bench %d" % id, "vehicle": HUMAN_VEHICLE, "team": 0, "ready": true, "loadout": []}
	if kind == KIND_VARUNA:
		return _make_varuna_config()
	return _make_fallback_config(bots)


func _make_varuna_config() -> Dictionary:
	MatchFlow.apply_extraction_roster(false)
	var cfg := MatchFlow.make_extraction_config({"world_idx": 0, "ai": 0, InfantryBots.CONFIG_KEY: 0})
	cfg.merge({"map": VarunaMap.MAP_ID, "extraction_seed": 4242}, true)
	return cfg


func _make_fallback_config(bots: int) -> Dictionary:
	MatchFlow.apply_free_for_all_teams()
	var settings := {"mode": "vs", "teams": false, "ai": 0, "world_idx": 0, "frag_limit": FRAG_LIMIT_NEVER}
	var cfg := MatchFlow.make_match_config(settings, [])
	cfg["start"] = BattleInfantry.START_IN_VEHICLE
	cfg["frag_limit"] = FRAG_LIMIT_NEVER
	if InfantryCatalog.make_default_pack() == "":   # no soldiers installed: the bots are AI Hercs
		cfg["ai"] = []
		for i in bots:
			cfg.ai.append({"vehicle": FALLBACK_AI_VEHICLE, "team": MatchFlow.FREE_FOR_ALL_AI_TEAM_BASE + i, "skill": 0.4})
	return cfg


## Where the bots and humans are spread: Varuna's sites, else the map's spawn points.
func build_anchors(battle: Battle) -> void:
	_anchors.clear()
	if kind == KIND_VARUNA:
		for s in VarunaMap.make_map().sites:
			_anchors.append(Vector3(float(s.pos[0]), float(s.pos[1]), float(s.pos[2])))
	else:
		for xf in battle.spawner.spawn_points:
			_anchors.append(xf.origin)
	if _anchors.is_empty():
		_anchors.append(Vector3.ZERO)


func make_scatter_point(index: int) -> Vector3:
	var anchor := _anchors[index % _anchors.size()]
	var angle := float(index) * SCATTER_STEP_RAD
	var radius := SCATTER_MIN_M + fmod(float(index) * 7.0, SCATTER_SPAN_M)
	return anchor + Vector3(cos(angle), 0.0, sin(angle)) * radius


## Moves every synthetic human to a scattered point.
func apply_human_positions(battle: Battle, humans: Array) -> void:
	for i in humans.size():
		(humans[i] as Herc).global_position = battle.infantry.make_on_ground(make_scatter_point(i))


## Spawns soldier bots until the battle holds `target` of them (the raid has populated its own sites already).
## Does nothing when no soldier pack is installed (the fallback then has AI Hercs from its config).
func apply_bots(battle: Battle, target: int, tree: SceneTree) -> void:
	var pack := InfantryCatalog.make_default_pack()
	if pack == "" or target <= 0:
		return
	var have := int(ServerMetrics.make_entity_counts(battle).bots)
	var bots := battle.infantry.bots
	for i in range(have, target):
		var spec := bots.make_bot_spec(pack, i)
		spec.xf = Transform3D((spec.xf as Transform3D).basis, battle.infantry.make_on_ground(make_scatter_point(i + 1000)))
		bots.spawn_bot(spec, InfantryBots.BOT_SKILL)
		if i % BOTS_PER_FRAME == 0:
			await tree.process_frame
