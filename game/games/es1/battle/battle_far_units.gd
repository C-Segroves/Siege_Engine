class_name BattleFarUnits
extends Node
## The client's far bots (docs/DEDICATED_SERVER_SCALING.md chunk L): a bot the server drops to the FAR tier (or out of
## interest) loses its scene node here and, while FAR, is drawn as a FarBots proxy; when it comes back to MID / NEAR
## the node is built again from the spawn spec the client kept, at the place the proxy was. Only bots are treated
## so (AI Hercs and soldier bots): other pilots, the local player and the target keep their nodes, which keeps
## scoreboards, targeting and the radar exactly as they were.
## Created on clients only (a host and a single player never drop units).

const ALLY_COLOR := Color(0.2, 0.9, 0.3)
const FOE_COLOR := Color(0.95, 0.25, 0.2)

var battle: Battle
var far_bots := FarBots.new()
## unit id -> spawn spec, kept for every bot of the match.
var _specs := {}
## unit id -> true while the unit has no node (a proxy, or nothing).
var _parked := {}
## unit id -> RadarProxy: the radar contact of each proxy (position, team, alive), so radar, command map and T see it.
var _contacts := {}
## Counters for tests and the benchmark.
var parked_total := 0
var restored_total := 0


func _init(p_battle: Battle) -> void:
	battle = p_battle
	name = "FarUnits"


func _ready() -> void:
	add_child(far_bots)


## Remembers the spawn spec of a bot (call for every spawn message).
func note_spawn(spec: Dictionary) -> void:
	if is_bot_spec(spec):
		_specs[int(spec.net_id)] = spec


static func is_bot_spec(spec: Dictionary) -> bool:
	return (spec.get("ai", {}) as Dictionary).has("skill") or bool(spec.get("bot", false))


func make_bot_ids() -> Array:
	return _specs.keys()


func is_parked(id: int) -> bool:
	return _parked.has(id)


## Whether the node of `h` may go: a bot that is neither the local player nor his target.
func can_park(h: Herc) -> bool:
	if not _specs.has(h.net_id) or h.is_local_player():
		return false
	return not (is_instance_valid(battle.player) and battle.player.target == h)


## Frees the node of bot `id` (it can be built again from its spec).
func park(h: Herc) -> void:
	var id := h.net_id
	battle.vehicles.erase(id)
	battle.entities.unregister(id)
	h.queue_free()
	_parked[id] = true
	parked_total += 1


## Draws the parked bot `id` as a proxy reaching `pos` / `yaw` in `seconds`.
func show_proxy(id: int, pos: Vector3, yaw: float, seconds: float) -> void:
	var spec: Dictionary = _specs[id]
	far_bots.apply_pose(id, make_kind(spec), pos, yaw, seconds)
	far_bots.apply_color(id, make_color(int(spec.team)))
	_note_contact(id, spec, pos)


func apply_alive(id: int, alive: bool) -> void:
	far_bots.apply_alive(id, alive)
	if _contacts.has(id):
		(_contacts[id] as RadarProxy).alive = alive


## The radar contact of proxy `id`, null without one.
func make_contact(id: int) -> RadarProxy:
	return _contacts.get(id)


## Targeting a contact: the node of parked bot `id` again, where its proxy stands (null when it is not parked).
func promote(id: int) -> Herc:
	return restore(id) if _parked.has(id) else null


func _note_contact(id: int, spec: Dictionary, pos: Vector3) -> void:
	var c: RadarProxy = _contacts.get(id)
	if c == null:
		c = RadarProxy.new(id, int(spec.team), spec.has("armor"))
		c.display_name = str(spec.get("name", ""))
		add_child(c)
		_contacts[id] = c
	c.global_position = pos


func _drop_contact(id: int) -> void:
	var c: RadarProxy = _contacts.get(id)
	if c:
		_contacts.erase(id)
		c.remove_from_group(RadarProxy.GROUP)
		c.queue_free()


func hide_proxy(id: int) -> void:
	_drop_contact(id)
	far_bots.remove(id)


## The pose of the proxy of `id` (see FarBots.make_pose).
func make_proxy_pose(id: int) -> Dictionary:
	return far_bots.make_pose(id)


## Builds the node of the parked bot `id` again, where its proxy stands (at its spawn place without one).
func restore(id: int) -> Herc:
	var pose := far_bots.make_pose(id)
	far_bots.remove(id)
	_drop_contact(id)
	_parked.erase(id)
	var h := battle.build_unit(_specs[id])
	if not pose.is_empty():
		h.global_position = pose.pos
		h.rotation.y = pose.yaw
	restored_total += 1
	return h


## A snapshot state for bot `id` before any node state exists (SnapshotCodec.IDX_*): at its spawn place, whole.
func make_placeholder_state(id: int) -> Array:
	var spec: Dictionary = _specs[id]
	var xf: Transform3D = spec.xf
	var state := [id, xf.origin, xf.basis.get_euler().y, 0.0, 0.0, 0.0, true, 0.0, 0.0, 1.0, 0.0, 0, 0, 0,
		PackedByteArray(), null, Vector2.ZERO, false]
	if spec.has("armor"):
		state[SnapshotCodec.IDX_EXTRA] = [false, 0, false, PackedInt32Array(), []]
	return state


## The server removed unit `id` from the match.
func apply_removed(id: int) -> void:
	_specs.erase(id)
	_parked.erase(id)
	far_bots.remove(id)
	_drop_contact(id)


func make_kind(spec: Dictionary) -> FarBots.Kind:
	return FarBots.Kind.SOLDIER if spec.has("armor") else FarBots.Kind.VEHICLE


func make_color(team: int) -> Color:
	var viewer: Herc = battle.player
	return ALLY_COLOR if is_instance_valid(viewer) and TeamRelations.is_allied(viewer.team, team) else FOE_COLOR
