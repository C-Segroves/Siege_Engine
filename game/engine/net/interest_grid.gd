class_name InterestGrid
extends RefCounted
## Per-client relevance over the EntityTable (docs/DEDICATED_SERVER_SCALING.md section 3.1 and 3.3).
##
## A uniform cell grid on the ground plane (x, z) is rebuilt once per server tick from the table. For every
## registered client, evaluate_client() computes the set of relevant entity ids: entities in the cells within
## view range, the client's own unit, team and target, and whatever radar shows; each gets a tier
## (NEAR / MID / FAR) that sets how often its state is sent. Mid entities behind terrain are demoted to FAR.
## The snapshot codec reads tier_of / should_send; entering and leaving relevance is reported as entered_ids /
## left_ids so the server can send spawn and forget messages.
##
## Radar and line of sight are injected as Callables so this module stays free of Nodes and physics:
##   radar_probe(client_id: int, entity_id: int) -> bool     (wrap RadarContacts.is_on_scope)
##   occlusion_probe(client_id: int, entity_id: int) -> bool (wrap LineOfSight.is_clear, cache about 2 s)

enum Tier { NEAR, MID, FAR }

const DEFAULT_CELL_M := 128.0              # same order as the nav TILE_SIZE (96)
const DEFAULT_NEAR_M := 100.0
const DEFAULT_MID_M := 400.0
const SOLDIER_VIEW_M := 300.0              # per-class view range (section 3.1)
const VEHICLE_VIEW_M := 800.0
const NOT_RELEVANT := -1

const NO_ENTITY := -1
const NO_TEAM := -1
const CELL_KEY_OFFSET := 32768
const CELL_KEY_STRIDE := 65536

## false: everybody sees everything at NEAR (LAN, 24 players).
var enabled := true
var cell_m := DEFAULT_CELL_M
var near_m := DEFAULT_NEAR_M
var mid_m := DEFAULT_MID_M
var soldier_view_m := SOLDIER_VIEW_M
var vehicle_view_m := VEHICLE_VIEW_M
## Own team is always relevant (Tribes sensor net / com link already makes allies known).
var team_always_relevant := true
## Send interval in ticks per Tier: every tick / every 3rd / every 5th.
var tier_interval: Array[int] = [1, 3, 5]
var radar_probe := Callable()
var occlusion_probe := Callable()
## Optional batch form of radar_probe: Callable(client_id, entity_ids: PackedInt32Array, tiers: Dictionary) -> PackedInt32Array of
## the ids (not already in `tiers`) that are on the client's radar. One call per client instead of one per entity.
var radar_batch_probe := Callable()

var _no_rows := PackedInt32Array()
var _cells := {}                            # packed cell key -> PackedInt32Array of table rows
var _soldier_cells := CellIndex.new()       # the same cells, soldiers only / everything else only: a client asks each class
var _vehicle_cells := CellIndex.new()       #   within its own view range, so far soldiers are never visited
var _team_rows := {}                        # team -> PackedInt32Array of table rows (ascending), as of the last rebuild
var _indexed_rows := -1                     # table size at the last rebuild
var _table: EntityTable
var _clients := {}                          # client id -> ClientInterest


## The populated cells of one class of entity (cell x, cell z, rows), so a client visits the few cells that hold something
## inside its view box instead of looking up every cell of the box.
class CellIndex:
	extends RefCounted
	var cell_x := PackedInt32Array()
	var cell_z := PackedInt32Array()
	var rows: Array[PackedInt32Array] = []
	var _slot_of := {}                      # packed cell key -> index into cell_x / cell_z / rows

	func clear() -> void:
		cell_x.clear()
		cell_z.clear()
		rows.clear()
		_slot_of.clear()

	func add(key: int, cx: int, cz: int, row: int) -> void:
		var slot: int = _slot_of.get(key, -1)
		if slot < 0:
			slot = rows.size()
			_slot_of[key] = slot
			cell_x.append(cx)
			cell_z.append(cz)
			rows.append(PackedInt32Array())
		rows[slot].append(row)


## One client's state: who it is and what it currently sees.
class ClientInterest:
	extends RefCounted
	var own_id := InterestGrid.NO_ENTITY
	var team := InterestGrid.NO_TEAM
	var target_id := InterestGrid.NO_ENTITY
	var tiers := {}                         # entity id -> Tier
	var entered := PackedInt32Array()
	var left := PackedInt32Array()


## Registers (or re-registers) a client. `own_entity_id` is the unit it controls, `team` its team (NO_TEAM none).
func add_client(client_id: int, own_entity_id: int, team: int) -> void:
	var client := ClientInterest.new()
	client.own_id = own_entity_id
	client.team = team
	_clients[client_id] = client


func remove_client(client_id: int) -> void:
	_clients.erase(client_id)


func has_client(client_id: int) -> bool:
	return _clients.has(client_id)


func make_client_ids() -> Array:
	return _clients.keys()


## The entity the client targets stays NEAR wherever it is.
func apply_target(client_id: int, entity_id: int) -> void:
	if _clients.has(client_id):
		_clients[client_id].target_id = entity_id


## Rebuilds the grid from `table`. Call once per server tick, after EntityTable.update_from_nodes.
func rebuild(table: EntityTable) -> void:
	_table = table
	_cells.clear()
	_soldier_cells.clear()
	_vehicle_cells.clear()
	_team_rows.clear()
	_indexed_rows = table.size()
	for row in table.size():
		var cx := _cell_of(table.pos_x[row])
		var cz := _cell_of(table.pos_z[row])
		var key := _make_key(cx, cz)
		if not _cells.has(key):
			_cells[key] = PackedInt32Array()
		_cells[key].append(row)
		(_soldier_cells if (table.flags[row] & EntityTable.FLAG_SOLDIER) != 0 else _vehicle_cells).add(key, cx, cz, row)
		var side := int(table.team[row])
		if not _team_rows.has(side):
			_team_rows[side] = PackedInt32Array()
		_team_rows[side].append(row)


## Recomputes the client's relevant set; afterwards entered_ids / left_ids list the change since the last call.
func evaluate_client(client_id: int) -> void:
	var client: ClientInterest = _clients.get(client_id)
	if client == null or _table == null:
		return
	var fresh := _make_relevance(client_id, client)
	client.entered = _make_ids_missing_from(fresh, client.tiers)
	client.left = _make_ids_missing_from(client.tiers, fresh)
	client.tiers = fresh


func evaluate_all_clients() -> void:
	for client_id in _clients:
		evaluate_client(client_id)


func make_visible_ids(client_id: int) -> PackedInt32Array:
	return PackedInt32Array(_clients[client_id].tiers.keys()) if _clients.has(client_id) else PackedInt32Array()


## The client's entity id -> Tier map itself (not a copy): the snapshot stream walks it once instead of asking per entity.
func get_tier_map(client_id: int) -> Dictionary:
	return _clients[client_id].tiers if _clients.has(client_id) else {}


func is_relevant(client_id: int, entity_id: int) -> bool:
	return tier_of(client_id, entity_id) != NOT_RELEVANT


## The entity's Tier for the client, NOT_RELEVANT when the client does not see it.
func tier_of(client_id: int, entity_id: int) -> int:
	return _clients[client_id].tiers.get(entity_id, NOT_RELEVANT) if _clients.has(client_id) else NOT_RELEVANT


## Entities that became relevant at the last evaluate_client (send each a full spawn state).
func entered_ids(client_id: int) -> PackedInt32Array:
	return _clients[client_id].entered if _clients.has(client_id) else PackedInt32Array()


## Entities that stopped being relevant at the last evaluate_client (send a forget).
func left_ids(client_id: int) -> PackedInt32Array:
	return _clients[client_id].left if _clients.has(client_id) else PackedInt32Array()


## Whether the entity's state goes into this tick's packet for the client. Rotation is staggered by entity id so
## load spreads evenly; a freshly entered entity is always sent.
func should_send(client_id: int, entity_id: int, tick: int) -> bool:
	var tier := tier_of(client_id, entity_id)
	if tier == NOT_RELEVANT:
		return false
	if entered_ids(client_id).has(entity_id):
		return true
	return (tick + entity_id) % maxi(1, tier_interval[tier]) == 0


# ------------------------------------------------------------------ relevance

func _make_relevance(client_id: int, client: ClientInterest) -> Dictionary:
	var tiers := {}
	if not enabled:
		for row in _table.size():
			tiers[_table.ids[row]] = Tier.NEAR
		return tiers
	var own_row := _table.make_row(client.own_id)
	if own_row != EntityTable.NO_ROW:
		_add_nearby(tiers, client_id, client, own_row)
	_add_always_relevant(tiers, client, own_row)
	_add_radar_contacts(tiers, client_id)
	return tiers


func _add_nearby(tiers: Dictionary, client_id: int, client: ClientInterest, own_row: int) -> void:
	var at := _table.make_position(own_row)
	_add_class_within(tiers, client_id, client, at, _soldier_cells, soldier_view_m)
	_add_class_within(tiers, client_id, client, at, _vehicle_cells, vehicle_view_m)


## Every entity of one class (a CellIndex) within `view_m` of `at` gets its tier.
func _add_class_within(tiers: Dictionary, client_id: int, client: ClientInterest, at: Vector3, index: CellIndex, view_m: float) -> void:
	var first_x := _cell_of(at.x - view_m)
	var last_x := _cell_of(at.x + view_m)
	var first_z := _cell_of(at.z - view_m)
	var last_z := _cell_of(at.z + view_m)
	var view_sq := view_m * view_m
	var xs := _table.pos_x
	var zs := _table.pos_z
	var ids := _table.ids
	for slot in index.rows.size():
		var cx := index.cell_x[slot]
		var cz := index.cell_z[slot]
		if cx < first_x or cx > last_x or cz < first_z or cz > last_z:
			continue
		for row in index.rows[slot]:
			var dx := at.x - xs[row]
			var dz := at.z - zs[row]
			var dist_sq := dx * dx + dz * dz
			if dist_sq <= view_sq:
				tiers[ids[row]] = _make_tier(client_id, client, ids[row], sqrt(dist_sq))


func _add_always_relevant(tiers: Dictionary, client: ClientInterest, own_row: int) -> void:
	var has_origin := own_row != EntityTable.NO_ROW
	var at := _table.make_position(own_row) if has_origin else Vector3.ZERO
	for row in _make_always_relevant_rows(client):
		var entity_id := _table.ids[row]
		if tiers.has(entity_id):
			continue
		if entity_id == client.own_id or entity_id == client.target_id:
			tiers[entity_id] = Tier.NEAR
		elif team_always_relevant and client.team != NO_TEAM and _table.team[row] == client.team:
			tiers[entity_id] = _make_distance_tier(_make_flat_distance(at, row)) if has_origin else Tier.FAR


## The rows _add_always_relevant has to look at, ascending: the client's own unit and target and its team's units (every
## other row falls through its tests), so the rows of the other teams are never visited.
func _make_always_relevant_rows(client: ClientInterest) -> PackedInt32Array:
	if _indexed_rows != _table.size():   # the table changed after the last rebuild: look at every row
		var all := PackedInt32Array()
		all.resize(_table.size())
		for row in all.size():
			all[row] = row
		return all
	var rows: PackedInt32Array = _no_rows
	if team_always_relevant and client.team != NO_TEAM:
		rows = _team_rows.get(client.team, _no_rows)
	for entity_id in [client.own_id, client.target_id]:
		var row := _table.make_row(entity_id)
		if row == EntityTable.NO_ROW or rows.has(row):
			continue
		rows = rows.duplicate()
		rows.append(row)
		rows.sort()
	return rows


func _add_radar_contacts(tiers: Dictionary, client_id: int) -> void:
	if radar_batch_probe.is_valid():
		for entity_id in radar_batch_probe.call(client_id, _table.ids, tiers):
			tiers[entity_id] = Tier.FAR
		return
	if not radar_probe.is_valid():
		return
	for entity_id in _table.ids:
		if not tiers.has(entity_id) and radar_probe.call(client_id, entity_id):
			tiers[entity_id] = Tier.FAR   # a blip needs position only


func _make_tier(client_id: int, client: ClientInterest, entity_id: int, distance_m: float) -> int:
	if entity_id == client.own_id or entity_id == client.target_id:
		return Tier.NEAR
	var tier := _make_distance_tier(distance_m)
	if tier == Tier.MID and occlusion_probe.is_valid() and occlusion_probe.call(client_id, entity_id):
		return Tier.FAR   # behind terrain: a bandwidth knob, not hiding (anti-wallhack is out of scope)
	return tier


func _make_distance_tier(distance_m: float) -> int:
	if distance_m < near_m:
		return Tier.NEAR
	return Tier.MID if distance_m < mid_m else Tier.FAR


func _make_view_range(row: int) -> float:
	return soldier_view_m if _table.is_flagged(row, EntityTable.FLAG_SOLDIER) else vehicle_view_m


# ------------------------------------------------------------------ helpers

func _make_flat_distance(at: Vector3, row: int) -> float:
	return Vector2(at.x - _table.pos_x[row], at.z - _table.pos_z[row]).length()


func _cell_of(metres: float) -> int:
	return floori(metres / cell_m)


static func _make_key(cx: int, cz: int) -> int:
	return (cx + CELL_KEY_OFFSET) * CELL_KEY_STRIDE + (cz + CELL_KEY_OFFSET)


## Ids that are keys of `wanted` and not of `have`.
static func _make_ids_missing_from(wanted: Dictionary, have: Dictionary) -> PackedInt32Array:
	var out := PackedInt32Array()
	for entity_id in wanted:
		if not have.has(entity_id):
			out.append(entity_id)
	return out
