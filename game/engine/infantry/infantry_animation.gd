class_name InfantryAnimation
extends RefCounted
## Plays a soldier's armour sequences (shape.ds_sequences, ShapeCycles) by movement state, as the originals'
## Player picks its action animation (docs/formats/tribes_infantry.md section 2):
##   Tribes 1   the PlayerData animData names (scripts/ArmorData.cs): "root", "run", "runback", "side left"
##              (played backwards for a step right: animData[4] direction -1), "jet", "fall", "landing", the
##              "die ..." sequences;
##   Tribes 2   the TSShapeConstructor names (<armour>.cs, the .dsq files tools/export_tribes2.py merges): "root",
##              "run", "back", "side", "jet", "fall", "land", "death1" .. "death11".
## A move cycle plays at the soldier's speed over the speed the cycle was authored for (its ground travel per
## cycle), at most MAX_TIME_SCALE times as fast. Its foot triggers (Darkstar frame triggers / Torque sequence
## triggers, 1 = left foot, 2 = right foot) are where the footsteps fall: `footsteps` lists the ones crossed in
## the last update (InfantrySounds plays them).
## apply_layers() then composes the look, head and recoil layers onto that pose (InfantryAnimationLayers, a NEAR soldier only).

## Candidate sequence names per role, Tribes 1 first.
const ROOT := ["root"]
const RUN := ["run"]
const RUN_BACK := ["runback", "back"]
const SIDE := ["side left", "side"]
const JET := ["jet"]
const FALL := ["fall"]
const LAND := ["landing", "land"]
const DEATH_PREFIXES := ["die ", "death"]
## Tribes 1 death sequences that need a pose the remake never takes (crouching).
const DEATH_EXCLUDED := ["crouch die"]
## Below this ground speed (m/s) the soldier stands.
const STAND_SPEED := 0.4
## Torque PlayerData::maxTimeScale default (Tribes 2 player.cs sets none): the fastest a move cycle plays
## relative to its authored speed. Tribes 1 is assumed to cap the same way.
const MAX_TIME_SCALE := 1.5
## Trigger states of the feet.
const LEFT_FOOT := 1
const RIGHT_FOOT := 2

## Foot trigger states (LEFT_FOOT / RIGHT_FOOT) crossed in the last update().
var footsteps: Array[int] = []
## The movement of the last update(): velocity in the soldier's frame, in the air.
var local_velocity := Vector3.ZERO
var airborne := false

var _shape: ShapeInstance
var _index := {}          # lower sequence name -> index
var _deaths: Array[int] = []
var _current := -1
var _phase := 0.0
var _landing_left := 0.0
var _was_airborne := false
var _posed := false       # the last update() posed a base sequence (the layers compose onto it)
var _layers: InfantryAnimationLayers


func _init(shape: ShapeInstance, shape_id := "") -> void:
	_shape = shape
	_layers = InfantryAnimationLayers.new(shape, shape_id)
	var seqs: Array = shape.shape.get("ds_sequences", [])
	for i in seqs.size():
		var n := str(seqs[i].get("name", "")).to_lower()
		if not _index.has(n):
			_index[n] = i
		if _is_death_name(n) and not _deaths.has(i):
			_deaths.append(i)


## True when the body has look, head or recoil layers (apply_layers does something).
func has_layers() -> bool:
	return _layers.has_layers()


## Composes the layers onto the pose of the last update(): look `pitch` (up positive, within +-`limit`), the head's `yaw` off the
## body, weapon `w` in hand (null = unarmed). Not for a soldier posed by apply_death or apply_hold.
func apply_layers(pitch: float, yaw: float, limit: float, w: Weapon, delta: float) -> void:
	if _posed and _current >= 0:
		_layers.apply(_current, pitch, yaw, limit, w, delta)


## The layer machinery, for tests.
func get_layers() -> InfantryAnimationLayers:
	return _layers


func has_sequences() -> bool:
	return _find(ROOT) >= 0


## True when the run cycle carries foot triggers (both games' armours do).
func has_foot_triggers() -> bool:
	var i := _find(RUN)
	return i >= 0 and not (_shape.shape.ds_sequences[i].get("triggers", []) as Array).is_empty()


## Every death sequence of the shape, in shape order.
func death_count() -> int:
	return _deaths.size()


## One frame of movement: `p_local_velocity` in the soldier's frame (x right, z back), `airborne`, `jetting`.
func update(p_local_velocity: Vector3, p_airborne: bool, jetting: bool, delta: float) -> void:
	footsteps.clear()
	_posed = false
	local_velocity = p_local_velocity
	airborne = p_airborne
	_apply_landing(airborne, delta)
	var role := make_role(local_velocity, airborne, jetting) if _landing_left <= 0.0 else LAND
	var i := _find(role)
	if i < 0:
		i = _find(ROOT)
	if i < 0:
		return
	var rate := 1.0
	if role in [RUN, RUN_BACK, SIDE]:
		rate = minf(Vector2(local_velocity.x, local_velocity.z).length() / maxf(_ground_speed_of(i), 0.1), MAX_TIME_SCALE)
		if role == SIDE and local_velocity.x > 0.0:
			rate = -rate   # both games' side cycle steps left (its ground travel goes to -x)
	_play(i, rate, delta, role != LAND)


## The role a soldier moving at `local_velocity` plays (one of the role constants).
static func make_role(velocity: Vector3, in_air: bool, jetting: bool) -> Array:
	if jetting:
		return JET
	if in_air:
		return FALL
	var flat := Vector2(velocity.x, velocity.z)
	if flat.length() < STAND_SPEED:
		return ROOT
	if absf(flat.x) > absf(flat.y):
		return SIDE
	return RUN if velocity.z < 0.0 else RUN_BACK


## The name of the sequence a soldier moving so plays ("" when the shape has none).
func make_sequence_name(velocity: Vector3, in_air: bool, jetting: bool) -> String:
	var i := _find(make_role(velocity, in_air, jetting))
	return str(_shape.shape.ds_sequences[i].name) if i >= 0 else ""


## Death sequence `choice` (wrapped over the shape's deaths) `seconds` after death, held on its last frame.
## Every peer passes the same choice (Infantry: net id + deaths), so they show the same death.
func apply_death(seconds: float, choice: int) -> void:
	if _deaths.is_empty():
		return
	_layers.release()
	var i := _deaths[posmod(choice, _deaths.size())]
	var duration := ShapeCycles.cycle_seconds(_shape, i, 0.0)
	ShapeCycles.pose(_shape, i, seconds / maxf(duration, 0.01), false)


## The name of death `choice` ("" when the shape has none).
func make_death_name(choice: int) -> String:
	return "" if _deaths.is_empty() else str(_shape.shape.ds_sequences[_deaths[posmod(choice, _deaths.size())]].name)


func _apply_landing(airborne: bool, delta: float) -> void:
	_landing_left -= delta
	if _was_airborne and not airborne:
		var land := _find(LAND)
		_landing_left = ShapeCycles.cycle_seconds(_shape, land, 0.0) if land >= 0 else 0.0
	_was_airborne = airborne


func _play(i: int, rate: float, delta: float, wrap: bool) -> void:
	if i != _current:
		_current = i
		_phase = 0.0
	var duration := ShapeCycles.cycle_seconds(_shape, i, 0.0)
	var before := _phase
	_phase += delta * rate / maxf(duration, 0.01)
	_collect_footsteps(i, before, _phase)
	_posed = true
	ShapeCycles.pose(_shape, i, _phase if wrap else minf(_phase, 1.0), wrap)


## Name of the sequence playing ("" before the first).
func make_current_name() -> String:
	return str(_shape.shape.ds_sequences[_current].name) if _current >= 0 else ""


## Holds a seat pose: the first of the sequences `names` the shape has, looping (no footsteps are wanted, so
## none are collected). False when the shape has none of them.
func apply_hold(names: Array, delta: float) -> bool:
	for n in names:
		var i := int(_index.get(str(n).to_lower(), -1))
		if i >= 0:
			_layers.release()
			_play(i, 1.0, delta, true)
			_posed = false
			footsteps.clear()
			return true
	return false


## The foot triggers of sequence `i` between cycle positions `from` and `to` (either direction, any wraps).
func _collect_footsteps(i: int, from: float, to: float) -> void:
	var triggers: Array = _shape.shape.ds_sequences[i].get("triggers", [])
	if triggers.is_empty() or is_equal_approx(from, to):
		return
	var lo := minf(from, to)
	var hi := maxf(from, to)
	for cycle in range(int(floor(lo)), int(floor(hi)) + 1):
		for t in triggers:
			var at := cycle + float(t[0])
			if at > lo and at <= hi and int(t[1]) in [LEFT_FOOT, RIGHT_FOOT]:
				footsteps.append(int(t[1]))


## Ground speed (m/s) sequence `i` was authored for: its ground travel per cycle over its duration, else a
## light armour's running speed.
func _ground_speed_of(i: int) -> float:
	var travel := ShapeCycles.ground_travel(_shape, i)
	var duration := ShapeCycles.cycle_seconds(_shape, i, 0.0)
	return travel / duration if travel > 0.0 and duration > 0.0 else DEFAULT_RUN_SPEED


func _find(role: Array) -> int:
	for n in role:
		if _index.has(n):
			return int(_index[n])
	return -1


static func _is_death_name(n: String) -> bool:
	if n in DEATH_EXCLUDED:
		return false
	for prefix in DEATH_PREFIXES:
		if n.begins_with(prefix):
			return true
	return false


## Tribes light armour maxForwardSpeed (scripts/ArmorData.cs larmor), used when a cycle has no ground travel.
const DEFAULT_RUN_SPEED := 11.0
