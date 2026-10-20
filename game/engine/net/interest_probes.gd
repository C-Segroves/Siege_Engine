class_name InterestProbes
extends RefCounted
## The radar and line-of-sight questions of the InterestGrid, answered from the Battle's nodes and cached
## (docs/DEDICATED_SERVER_SCALING.md section 3.1): the radar answer is kept RADAR_CACHE_MS (1 s), the occlusion answer
## OCCLUSION_CACHE_MS, both in simulated time, each with a per-entity jitter so the refreshes spread over ticks
## instead of landing together. Nodes are found through two resolvers so this module needs no Battle:
##   viewer_of: Callable(client_id) -> Node3D (the unit the client controls, null when it has none)
##   unit_of:   Callable(entity_id) -> Node3D
##   now_ms:    Callable() -> int (simulated milliseconds)

const RADAR_CACHE_MS := 1000
## A client's whole radar picture is reused this long (so a pass over every entity runs about twice a second).
const PICTURE_MS := 500
const OCCLUSION_CACHE_MS := 2000
## The refreshes of one client's answers spread over half the cache life (they used to land within 97 ms of each other,
## a burst of evaluations or ray casts every second or two).
const RADAR_JITTER_MS := RADAR_CACHE_MS / 2
const TEAM_KEY_STRIDE := 64
const JITTER_STRIDE := 37
const EYE_HEIGHT_M := 2.0
const TARGET_HEIGHT_M := 1.0

var viewer_of := Callable()
var unit_of := Callable()
var now_ms := Callable()
## Probe calls that went to the radar / the physics ray (cache misses): the work the caches save.
var radar_evaluations := 0
var ray_casts := 0

var _team_radar := {}                       # entity id * stride + team -> [shown, expires_ms] (sensor-net maps)
var _radar_hits := {}                       # client id -> [ids on its radar, expires_ms]
var _team_hits := {}                        # team (sensor-net maps) -> [ids on the radar of every client of that team, expires_ms]
var _radar := {}                            # client id -> {entity id: [shown, expires_ms]}
var _occluded := {}


func _init(p_viewer_of: Callable, p_unit_of: Callable, p_now_ms: Callable) -> void:
	viewer_of = p_viewer_of
	unit_of = p_unit_of
	now_ms = p_now_ms


## InterestGrid.radar_probe: the entity is on the client's radar scope (RadarContacts.is_on_scope).
func is_on_radar(client_id: int, entity_id: int) -> bool:
	var answers: Dictionary = _radar.get(client_id, {})
	_radar[client_id] = answers
	var now: int = now_ms.call()
	var until: int = answers.get(entity_id, 0)
	if absi(until) <= now:
		var shown := _evaluate_radar(client_id, entity_id)
		until = now + RADAR_CACHE_MS + (entity_id * JITTER_STRIDE) % RADAR_JITTER_MS
		until = until if shown else -until
		answers[entity_id] = until
	return until > 0


## InterestGrid.radar_batch_probe: the ids among `entity_ids` (and not keys of `skip`) on the client's radar. The same
## cache as is_on_radar, read with the clock asked once. An answer is one int: its expiry, negative when not shown.
func make_radar_hits(client_id: int, entity_ids: PackedInt32Array, skip: Dictionary) -> PackedInt32Array:
	var now: int = now_ms.call()
	var team := _make_picture_team(viewer_of.call(client_id))
	if team >= 0:
		return _filter_hits(_make_team_picture(team, client_id, entity_ids, now), skip)
	var cached: Array = _radar_hits.get(client_id, [])
	if not cached.is_empty() and cached[1] > now:   # the client's whole radar picture is reused for half a cache life
		return _filter_hits(cached[0], skip)
	var hits := PackedInt32Array()
	var answers: Dictionary = _radar.get(client_id, {})
	_radar[client_id] = answers
	for entity_id in entity_ids:
		if skip.has(entity_id):
			continue
		var until: int = answers.get(entity_id, 0)
		if absi(until) <= now:
			var shown := _evaluate_radar(client_id, entity_id)
			until = now + RADAR_CACHE_MS + (entity_id * JITTER_STRIDE) % RADAR_JITTER_MS
			until = until if shown else -until
			answers[entity_id] = until
		if until > 0:
			hits.append(entity_id)
	_radar_hits[client_id] = [hits, now + PICTURE_MS]
	return hits


## Where a sensor net decides the radar, every client of a team sees the same picture: one pass over the entities per
## team and half a cache life, however many clients the team has (`client_id` is only the one asked first).
func _make_team_picture(team: int, client_id: int, entity_ids: PackedInt32Array, now: int) -> PackedInt32Array:
	var cached: Array = _team_hits.get(team, [])
	if not cached.is_empty() and cached[1] > now:
		return cached[0]
	var hits := PackedInt32Array()
	var answers: Dictionary = _radar.get(client_id, {})
	_radar[client_id] = answers
	for entity_id in entity_ids:
		var until: int = answers.get(entity_id, 0)
		if absi(until) <= now:
			var shown := _evaluate_radar(client_id, entity_id)
			until = now + RADAR_CACHE_MS + (entity_id * JITTER_STRIDE) % RADAR_JITTER_MS
			until = until if shown else -until
			answers[entity_id] = until
		if until > 0:
			hits.append(entity_id)
	_team_hits[team] = [hits, now + PICTURE_MS]
	return hits


## The cached `hits` that are not keys of `skip` (an entity gone from the table stays listed until the next full pass).
static func _filter_hits(hits: PackedInt32Array, skip: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for entity_id in hits:
		if not skip.has(entity_id):
			out.append(entity_id)
	return out


## InterestGrid.occlusion_probe: terrain or structures block the client's view of the entity (not
## LineOfSight.is_clear).
func is_occluded(client_id: int, entity_id: int) -> bool:
	return _make_cached(_occluded, client_id, entity_id, OCCLUSION_CACHE_MS, _evaluate_occlusion)


func forget_client(client_id: int) -> void:
	_radar.erase(client_id)
	_radar_hits.erase(client_id)
	_occluded.erase(client_id)


## Drops the cached answers that have expired (call now and then; the caches only grow with entities seen).
func purge_expired() -> void:
	var now: int = now_ms.call()
	for k: int in _team_radar.keys():
		if _team_radar[k][1] <= now:
			_team_radar.erase(k)
	for client_id: int in _radar:
		var radar_answers: Dictionary = _radar[client_id]
		for entity_id: int in radar_answers.keys():
			if absi(radar_answers[entity_id]) <= now:
				radar_answers.erase(entity_id)
	for client_id: int in _occluded:
		var answers: Dictionary = _occluded[client_id]
		for entity_id: int in answers.keys():
			if answers[entity_id][1] <= now:
				answers.erase(entity_id)


func _make_cached(cache: Dictionary, client_id: int, entity_id: int, lifetime_ms: int, evaluate: Callable) -> bool:
	var answers: Dictionary = cache.get(client_id, {})
	cache[client_id] = answers
	var now: int = now_ms.call()
	var hit: Array = answers.get(entity_id, [])
	if not hit.is_empty() and hit[1] > now:
		return hit[0]
	var value: bool = evaluate.call(client_id, entity_id)
	answers[entity_id] = [value, now + lifetime_ms + (entity_id * JITTER_STRIDE) % maxi(lifetime_ms / 2, 1)]
	return value


func _evaluate_radar(client_id: int, entity_id: int) -> bool:
	radar_evaluations += 1
	var viewer: Node3D = viewer_of.call(client_id)
	var unit: Node3D = unit_of.call(entity_id)
	if not is_instance_valid(viewer) or not is_instance_valid(unit):
		return false
	var team_key := _make_team_key(viewer, entity_id)
	if team_key < 0:
		return RadarContacts.is_on_scope(viewer, unit)
	var now: int = now_ms.call()
	var hit: Array = _team_radar.get(team_key, [])
	if not hit.is_empty() and hit[1] > now:
		return hit[0]
	var shown := RadarContacts.is_on_scope(viewer, unit)
	_team_radar[team_key] = [shown, now + RADAR_CACHE_MS + (entity_id * JITTER_STRIDE) % RADAR_JITTER_MS]
	return shown


## Where a sensor net decides the radar (Tribes) and the viewer's radar emits, the answer depends on the viewer's team
## and the unit only, so every client of a team shares one evaluation: a key for it, -1 where the answer is the viewer's own.
func _make_team_key(viewer: Node3D, entity_id: int) -> int:
	var team := _make_picture_team(viewer)
	return -1 if team < 0 else entity_id * TEAM_KEY_STRIDE + team


## The viewer's team where a sensor net decides what its radar shows (Tribes) and its radar emits, else -1.
func _make_picture_team(viewer: Node3D) -> int:
	if not is_instance_valid(viewer) or not RadarMode.is_emitting(viewer):
		return -1
	var base := TribesBase.of(viewer.get_parent())
	if base == null or base.sensor_net == null:
		return -1
	return int(viewer.get("team")) & (TEAM_KEY_STRIDE - 1)


func _evaluate_occlusion(client_id: int, entity_id: int) -> bool:
	var viewer := viewer_of.call(client_id) as CollisionObject3D
	var unit: Node3D = unit_of.call(entity_id)
	if not is_instance_valid(viewer) or not is_instance_valid(unit) or not viewer.is_inside_tree():
		return false
	ray_casts += 1
	var from := viewer.global_position + Vector3.UP * EYE_HEIGHT_M
	var to := unit.global_position + Vector3.UP * TARGET_HEIGHT_M
	return not LineOfSight.is_clear(viewer, from, unit, to)
