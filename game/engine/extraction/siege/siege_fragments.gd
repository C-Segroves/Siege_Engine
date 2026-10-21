class_name SiegeFragments
extends RefCounted
## The radio fragments that hint the order of the relays (host). Per raid the order is rolled; fragment `rank` (first,
## second, third) tells the line of the relay that has that place. Recorders lying at wreck sites hold them as loot
## (valuable "radio_fragment_a/b/c", per_rank copies each) and static speaks the same lines to whoever walks into an echo
## place once (AreaTrigger per place). The map's lines are data (map "cybrid_siege".fragments).

const ITEM_KEYS := ["radio_fragment_a", "radio_fragment_b", "radio_fragment_c"]
const ITEM_KIND := "valuable"
const RECORDER_KIND := "recorder"

signal echoed(peer: int, rank: int)

## rank -> the line (set by apply_roll).
var hints: Array = []
var _echo_triggers: Array[AreaTrigger] = []
var _heard := {}            # "peer|echo index" -> true


## The line each rank tells for `order` (relay ids first to last) from `lines` ({relay id: [first, second, third]}).
static func make_hints(order: Array, lines: Dictionary) -> Array:
	var out := []
	for rank in order.size():
		var own: Array = lines.get(order[rank], [])
		out.append(str(own[rank]) if rank < own.size() else "")
	return out


static func make_item_id(rank: int) -> String:
	return ExtractionItems.make_id(ITEM_KIND, ITEM_KEYS[clampi(rank, 0, ITEM_KEYS.size() - 1)])


## The rank of fragment item `item_id` (-1 for any other item).
static func make_rank_of_item(item_id: String) -> int:
	for rank in ITEM_KEYS.size():
		if item_id == make_item_id(rank):
			return rank
	return -1


func apply_roll(order: Array, lines: Dictionary) -> void:
	hints = make_hints(order, lines)


## [{rank, pos: Vector2}]: `per_rank` recorders for each rank on distinct dry `spots` (shuffled by `rng`).
static func make_placements(spots: Array, per_rank: int, ranks: int, rng: RandomNumberGenerator, is_dry: Callable) -> Array:
	var pool := spots.filter(func(s: Array) -> bool: return is_dry.call(Vector2(float(s[0]), float(s[1]))))
	pool = SiegeChain.make_shuffled(pool, rng)
	var out := []
	for i in mini(pool.size(), per_rank * ranks):
		out.append({"rank": i % ranks, "pos": Vector2(float(pool[i][0]), float(pool[i][1]))})
	return out


## The echo places [{pos: [x, z], radius}] (the dry ones) become triggers; a player entering one hears the next rank.
func apply_echoes(echoes: Array, is_dry: Callable) -> void:
	_echo_triggers.clear()
	for e in echoes:
		var at := Vector2(float(e.pos[0]), float(e.pos[1]))
		if not is_dry.call(at):
			continue
		var index := _echo_triggers.size()
		var t := AreaTrigger.new(AreaShape.make_cylinder(Vector3(at.x, 0.0, at.y), float(e.get("radius", 30.0)), 100000.0))
		t.entered.connect(_on_echo_entered.bind(index))
		_echo_triggers.append(t)


func apply_scan(positions: Dictionary) -> void:
	for t in _echo_triggers:
		t.apply_scan(positions)


func _on_echo_entered(peer: Variant, index: int) -> void:
	var key := "%d|%d" % [int(peer), index]
	if _heard.has(key) or hints.is_empty():
		return
	_heard[key] = true
	echoed.emit(int(peer), index % hints.size())
