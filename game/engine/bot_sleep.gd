class_name BotSleep
extends Node
## Bot LOD director, every map and mode (child "BotSleep" of the Battle, host only; docs/DEDICATED_SERVER_SCALING.md
## section 4.2). Every AI soldier and AI Herc gets a tier from its flat distance to the nearest human, read from the
## battle's EntityTable (no per-bot scans of Nodes):
##   NEAR   close to a human (near_m for soldiers, herc_near_m for Hercs) or held awake by the rifle scope: full combat
##          logic, vision rays and pathing, the brain deciding at 5 Hz.
##   MID    out to the sight range: the brain decides at 5 Hz with a simplified threat assessment (the target is
##          searched every mid_search_every-th decision) and simplified nav (no obstacle probes, no line-of-sight
##          rays); a soldier steps its movement every 4th physics tick (Infantry.far_lod).
##   FAR    beyond sight, but on a human's radar scope or pinned (objective, formation, engaged order): a soldier's
##          physics and pathing are off and it walks its route in a straight line every tick_s (InfantryBot.
##          apply_far_step), so its blip moves plausibly; a Herc stays MID.
##   ASLEEP beyond sight and on nobody's radar: process and physics_process off and hidden; the body and collision stay
##          and the unit stays in vehicles/radar/mission lists, so counts, objectives and timers run as before.
## Sight range = min(the map's fog end, rules bot_sleep.range_m); sleep_at adds margin_m (the hysteresis). Anything on a
## human's radar scope (RadarContacts.is_on_scope: inside the radar's actual range and mode, or a com tower's reach) is
## never ASLEEP, but it is only ever MID/FAR: the radar needs a moving position, not a simulation. Pinned units are never
## asleep either: objective, formation leader or follower, an engaged or moving Herc order, meta "keep_awake", scope
## hold; "dormant" and dead ones never change tier. Without a living human everything stays NEAR. Flyers are untouched.
## A damaged unit wakes to NEAR and stays there damage_hold_s (5) seconds. The zoomed Laser Rifle (RifleScope) calls wake_area (SiteSpawner.wake_area in the
## extraction mode) along its view cone up to the rifle's 1000 m range, so units the player looks at from beyond the
## sight range act.

enum Tier { NEAR, MID, FAR, ASLEEP }

const META_ASLEEP := "bot_asleep"
const META_HIBERNATING := "bot_hibernating"   # asleep or in the FAR linear walk: physics and process off
const META_TIER := "bot_lod_tier"
const META_HOLD_UNTIL := "bot_wake_hold_until_ms"
const META_DAMAGE_HOLD_UNTIL := "bot_damage_hold_until_ms"
const META_KEEP_AWAKE := "keep_awake"
## How long a unit that was hit stays NEAR (rules bot_sleep.damage_hold_s): it answers the fire instead of dozing off
## at the next director step.
const DAMAGE_HOLD_S := 5.0
## A server steps the table in this many slices per period (see apply_tick).
const SERVER_SLICES := 4
## The longest time one FAR step covers (s); a longer gap is walked in several steps.
const MAX_STEP_S := 10.0
## A sleeper that wakes walks off the time it slept (up to this long, s), so a bot with somewhere to go is not late.
const MAX_CATCH_UP_S := 120.0
const META_SLEPT_AT := "bot_slept_at_ms"

var battle: Node
var _t := 0.0
var _fog_end := INF
var _fog_searched := false
var _brains := {}          # unit instance id -> its AI brain node: no get_children scan per tick
var _tick := 0
var _last_step_ms := 0
var sleeping_count := 0
var tier_counts := [0, 0, 0, 0]
var _slice := 0
var _sensor_net := false   # the battle's radar is a Tribes sensor net (set by _has_unbounded_radar each step)
var _slice_counts := {}    # slice -> tier counts of the units it stepped last
var _unit_step_ms := {}    # net id -> ticks msec of the unit's last step
var _net_viewers: Array = []   # sensor net: the first viewer of each (side, radar mode): the rest answer the same
var _viewer_x := PackedFloat32Array()   # this step's viewers' ground positions (no property reads per unit)
var _viewer_z := PackedFloat32Array()
var _viewer_team := PackedInt32Array()
var _tower_allies := {}   # tower index -> the viewers on its side (this step)
var _max_range := 0.0   # the longest radar range among this step's viewers


## Game time in ms: physics frames, so it follows Engine.time_scale and a headless run's pace (not the wall clock).
static func make_game_ms() -> int:
	return int(Engine.get_physics_frames() * 1000.0 / Engine.physics_ticks_per_second)


static func rules() -> Dictionary:
	return ExtractionRules.data().get("bot_sleep", {})


static func is_enabled() -> bool:
	return bool(rules().get("enabled", true))


func _init(p_battle: Node) -> void:
	battle = p_battle
	name = "BotSleep"


## Tier counts of the whole table: the sum of what each slice stepped last.
func _update_counts() -> void:
	tier_counts = [0, 0, 0, 0]
	for c: Array in _slice_counts.values():
		for t in 4:
			tier_counts[t] += c[t]
	sleeping_count = tier_counts[Tier.ASLEEP]


## `o` as a Herc; null for a freed unit a vehicles table still lists (casting a freed object is an error).
static func _herc_of(o: Variant) -> Herc:
	return o as Herc if is_instance_valid(o) else null


static func is_asleep(unit: Node) -> bool:
	return unit != null and bool(unit.get_meta(META_ASLEEP, false))


static func tier_of(unit: Node) -> int:
	return int(unit.get_meta(META_TIER, Tier.NEAR)) if unit != null else Tier.NEAR


## Sight range of the sleep rule (m).
func make_sight_range() -> float:
	if not _fog_searched:
		_fog_searched = true
		for we in battle.find_children("*", "WorldEnvironment", true, false):
			var env := (we as WorldEnvironment).environment
			if env != null and env.fog_enabled:
				_fog_end = minf(_fog_end, env.fog_depth_end)
	return minf(_fog_end, float(rules().get("range_m", 800.0)))


func _physics_process(delta: float) -> void:
	if not is_inside_tree() or not multiplayer.is_server() or not is_enabled():
		return
	_t -= delta
	if _t > 0.0:
		return
	var slices := SERVER_SLICES if ServerProfile.is_collision_only() else 1
	_t = float(rules().get("tick_s", 0.5)) / float(slices)
	apply_tick(slices, _slice)
	_slice = (_slice + 1) % slices


## One director step (tests call it directly). With `slices` > 1 it steps only the units whose place in the vehicle
## table is `slice` modulo `slices` (a server steps a quarter of them every quarter period: the same cadence per unit,
## without a long stall once per period).
func apply_tick(slices := 1, slice := 0) -> void:
	var entities: EntityTable = battle.entities
	_tick += 1
	for k in battle.vehicles:
		var unit := _herc_of(battle.vehicles[k])
		if unit != null and is_instance_valid(unit) and not entities.has_entity(int(k)):
			entities.register(int(k), unit)
	entities.update_from_nodes(_tick)
	SensorTowers.begin_cache(battle.get_tree())   # the radar questions of this step see the same towers (end_cache below)
	var viewers := _find_human_nodes()
	var hx := PackedFloat32Array()
	var hz := PackedFloat32Array()
	var ranges := PackedFloat32Array()
	var teams := PackedInt32Array()
	_max_range = 0.0
	for h in viewers:
		hx.append(h.global_position.x)
		hz.append(h.global_position.z)
		teams.append(int(h.get("team")))
		ranges.append(RadarContacts.make_range(h))
		_max_range = maxf(_max_range, ranges[-1])
	var reach_unbounded := _has_unbounded_radar()
	_viewer_x = hx
	_viewer_z = hz
	_viewer_team = teams
	_tower_allies.clear()
	_net_viewers = _make_net_viewers(viewers) if _sensor_net else []
	var sight := make_sight_range()
	var sleep_at := sight + float(rules().get("margin_m", 60.0))
	var near_m := float(rules().get("near_m", 150.0))
	var herc_near_m := float(rules().get("herc_near_m", 400.0))
	var margin := float(rules().get("near_margin_m", 25.0))
	var leaders := {}
	for v in battle.vehicles.values():
		var pilot := _brain_of(v) as AIPilot
		if pilot != null and pilot.leader != null:
			leaders[pilot.leader] = true
	var now_ms := Time.get_ticks_msec()
	var game_ms := make_game_ms()
	var counts := [0, 0, 0, 0]
	var index := -1
	for k in battle.vehicles:
		index += 1
		if index % slices != slice:
			continue
		var unit := _herc_of(battle.vehicles[k])
		if unit == null or not is_instance_valid(unit):
			continue
		# game time, not wall time: under Engine.time_scale (or a headless run faster than real time) a wall-clock
		# step would be too short and the FAR soldier would walk slower than the same one at NEAR
		var last_ms: int = _unit_step_ms.get(k, -1)
		var step_dt := clampf((game_ms - last_ms) / 1000.0, 0.0, MAX_STEP_S) if last_ms >= 0 else float(rules().get("tick_s", 0.5))
		_unit_step_ms[k] = game_ms
		var brain := _brain_of(unit)
		if brain == null:
			continue
		var tier: int
		if not unit.alive or unit.has_meta("dormant"):
			tier = tier_of(unit)
		elif hx.is_empty():
			tier = Tier.NEAR
		else:
			var row := entities.make_row(int(k))
			var d := _nearest_flat(entities.pos_x[row], entities.pos_z[row], hx, hz)
			tier = _make_tier(unit, brain, d, viewers, ranges, reach_unbounded, leaders, sight, sleep_at,
				near_m if brain is InfantryBot else herc_near_m, margin, now_ms)
		_apply_tier(unit, brain, tier)
		counts[tier] += 1
		if tier == Tier.FAR and brain is InfantryBot:
			(brain as InfantryBot).apply_far_step(step_dt)
	SensorTowers.end_cache()
	_slice_counts[slice % slices] = counts
	_update_counts()


func _make_tier(unit: Herc, brain: Node, d: float, viewers: Array, ranges: PackedFloat32Array, reach_unbounded: bool,
		leaders: Dictionary, sight: float, sleep_at: float, near_m: float, margin: float, now_ms: int) -> int:
	var old := tier_of(unit)
	if now_ms < int(unit.get_meta(META_HOLD_UNTIL, 0)) or now_ms < int(unit.get_meta(META_DAMAGE_HOLD_UNTIL, 0)):
		return Tier.NEAR
	if d <= near_m + (margin if old == Tier.NEAR else 0.0):
		return Tier.NEAR
	if d <= (sleep_at if old < Tier.FAR else sight):   # an awake unit sleeps past sight + margin, a sleeper wakes inside sight
		return Tier.MID
	# beyond sight: a pinned unit or one on a radar stays awake, cheaply
	var cheap := Tier.FAR if brain is InfantryBot else Tier.MID
	if not _may_sleep(unit, brain, leaders):
		return cheap
	return cheap if _is_on_radar(unit, d, viewers, ranges, reach_unbounded) else Tier.ASLEEP


## True when `unit` is on the radar scope of a human viewer. Only viewers whose radar reaches it are asked (the
## range is part of RadarContacts.is_on_scope), unless a sensor net or com tower reaches without a range.
func _is_on_radar(unit: Node, nearest_m: float, viewers: Array, ranges: PackedFloat32Array, reach_unbounded: bool) -> bool:
	if _sensor_net:   # a sensor net's answer depends on the viewer's side and radar mode only, not on where it stands
		for h in _net_viewers:
			if RadarContacts.is_on_scope(h, unit):
				return true
		return false
	var reaching := SensorTowers.make_reaching_towers(unit as Node3D) if reach_unbounded else PackedInt32Array()
	if nearest_m > _max_range + 0.1 and reaching.is_empty():
		return false   # beyond every viewer's radar range and no com tower reaches it
	var revealed := {}   # viewer index -> a working com tower of its side (or an ally's) reaches the unit
	for tower in reaching:
		for i in _make_tower_allies(tower):
			revealed[i] = true
	var p := (unit as Node3D).global_position
	for i in viewers.size():
		if Vector2(_viewer_x[i] - p.x, _viewer_z[i] - p.z).length() > ranges[i] and not revealed.has(i):
			continue   # beyond its radar range, and no com tower of its side reaches the unit
		if RadarContacts.is_on_scope(viewers[i], unit):
			return true
	return false


## The indices of this step's viewers on the side of the tower at `index` or allied to it (remembered per step).
func _make_tower_allies(index: int) -> PackedInt32Array:
	if not _tower_allies.has(index):
		var side := SensorTowers.make_tower_team(index)
		var out := PackedInt32Array()
		for i in _viewer_team.size():
			if _viewer_team[i] == side or TeamRelations.is_allied(_viewer_team[i], side):
				out.append(i)
		_tower_allies[index] = out
	return _tower_allies[index]


## The first viewer of every (side, radar mode): with a sensor net the others would answer the same.
func _make_net_viewers(viewers: Array) -> Array:
	var seen := {}
	var out := []
	for h in viewers:
		var key := int(h.get("team")) * 2 + (1 if RadarMode.is_emitting(h) else 0)
		if not seen.has(key):
			seen[key] = true
			out.append(h)
	return out


## A sensor net (Tribes) or a working com tower reports contacts at any distance, so the range prefilter is off.
func _has_unbounded_radar() -> bool:
	var base := TribesBase.of(battle)
	_sensor_net = base != null and base.sensor_net != null
	if _sensor_net:
		return true
	return not battle.get_tree().get_nodes_in_group(SensorTowers.GROUP).is_empty()


## True when `unit` is on the radar scope of any of the human `viewers` (a unit a player's radar shows is never asleep).
static func is_on_any_radar(unit: Node, viewers: Array) -> bool:
	for h in viewers:
		if RadarContacts.is_on_scope(h, unit):
			return true
	return false


func _find_human_nodes() -> Array:
	var peers := [multiplayer.get_unique_id()]
	peers.append_array(multiplayer.get_peers())
	var out := []
	for v in battle.vehicles.values():
		var h := _herc_of(v)
		if h != null and is_instance_valid(h) and h.alive and _brain_of(h) == null and (h == battle.player or peers.has(h.owner_peer)):
			out.append(h)
	return out


## The AI brain node of a unit (InfantryBot on a soldier, AIPilot on a Herc), null for human-driven and flyers.
## Cached per unit; the first lookup scans the children once.
func _brain_of(v: Variant) -> Node:   # Variant: a freed unit a vehicles table still lists is refused by a typed parameter
	if not is_instance_valid(v) or v is Flyer:
		return null
	var id: int = v.get_instance_id()
	var cached = _brains.get(id)
	if cached != null and is_instance_valid(cached) and cached.get_parent() == v:
		return cached
	for c in v.get_children():
		if c is InfantryBot or c is AIPilot:
			_brains[id] = c
			return c
	_brains.erase(id)   # a human's Herc (or one whose brain is not attached yet): look again next time
	return null


func _may_sleep(unit: Herc, brain: Node, leaders: Dictionary) -> bool:
	if not unit.alive or unit.has_meta("dormant") or unit.has_meta(META_KEEP_AWAKE) or leaders.has(unit) \
			or Time.get_ticks_msec() < int(unit.get_meta(META_HOLD_UNTIL, 0)):
		return false
	if brain is InfantryBot:
		return not (unit as Infantry).stowed and (brain as InfantryBot).objective.is_empty()
	var pilot := brain as AIPilot
	return unit.is_on_floor() and pilot.leader == null and pilot.objective.is_empty() and not pilot.engaging \
			and pilot.order in [AIPilot.Order.GUARD, AIPilot.Order.SLEEP]


static func _nearest_flat(x: float, z: float, hx: PackedFloat32Array, hz: PackedFloat32Array) -> float:
	var best := INF
	for i in hx.size():
		best = minf(best, Vector2(x - hx[i], z - hz[i]).length())
	return best


## Puts `unit` and its brain into `tier`.
func _apply_tier(unit: Herc, brain: Node, tier: int) -> void:
	if tier_of(unit) == tier and bool(unit.get_meta(META_HIBERNATING, false)) == (tier >= Tier.FAR):
		return
	apply(unit, brain, tier == Tier.ASLEEP, tier == Tier.FAR)
	unit.set_meta(META_TIER, tier)
	var lod := mini(tier, Tier.MID)
	brain.set("ai_lod", lod)
	var soldier := unit as Infantry
	if soldier != null:
		soldier.far_lod = lod >= Tier.MID and not soldier.stowed


## Sleeps (asleep) or hibernates in the FAR linear walk (linear) a unit and its brain; both false wakes it.
static func apply(unit: Herc, brain: Node, asleep: bool, linear := false) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var hibernate := asleep or linear
	if bool(unit.get_meta(META_HIBERNATING, false)) == hibernate and is_asleep(unit) == asleep:
		return
	var was_asleep := is_asleep(unit)
	if asleep and not was_asleep:
		unit.set_meta(META_SLEPT_AT, make_game_ms())
	unit.set_meta(META_ASLEEP, asleep)
	unit.set_meta(META_HIBERNATING, hibernate)
	if not hibernate:
		unit.set_meta(META_TIER, Tier.NEAR)
	unit.set_physics_process(not hibernate)
	unit.set_process(not hibernate)
	unit.visible = not hibernate
	if brain != null and is_instance_valid(brain):
		brain.set_physics_process(not hibernate)
		brain.set_process(not hibernate)
		if not hibernate:
			brain.set("ai_lod", Tier.NEAR)
	if hibernate and not unit.damaged.is_connected(_wake_on_damage):
		unit.damaged.connect(_wake_on_damage.bind(brain), CONNECT_ONE_SHOT)
	if was_asleep and not asleep:
		_apply_catch_up(unit, brain)


## A sleeper that wakes (or goes FAR) first walks the game time it slept, toward its goal: sleeping changes the cost, not
## where the bot is by now. Guards stay on their post.
static func _apply_catch_up(unit: Herc, brain: Node) -> void:
	var bot := brain as InfantryBot
	var since := int(unit.get_meta(META_SLEPT_AT, -1))
	unit.remove_meta(META_SLEPT_AT)
	if bot == null or since < 0 or bot.guard_radius > 0.0:
		return
	var left := minf((make_game_ms() - since) / 1000.0, MAX_CATCH_UP_S)
	while left > 0.05:
		var chunk := minf(left, MAX_STEP_S)
		bot.apply_far_step(chunk)
		left -= chunk


static func _wake_on_damage(unit: Herc, _attacker: Node, brain: Node) -> void:
	apply(unit, brain, false)
	unit.set_meta(META_DAMAGE_HOLD_UNTIL, Time.get_ticks_msec() + int(float(rules().get("damage_hold_s", DAMAGE_HOLD_S)) * 1000.0))
	if unit is Infantry:
		(unit as Infantry).far_lod = false


## Wakes every sleeping or sleep-capable AI unit within `radius` of `center` and keeps it awake (NEAR) for `hold_s` seconds.
func wake_area(center: Vector3, radius: float, hold_s := 1.0) -> int:
	var woke := 0
	for v in battle.vehicles.values():
		var unit := _herc_of(v)
		if unit == null or not is_instance_valid(unit):
			continue
		var brain := _brain_of(unit)
		if brain != null and Vector2(unit.global_position.x - center.x, unit.global_position.z - center.z).length() <= radius:
			unit.set_meta(META_HOLD_UNTIL, Time.get_ticks_msec() + int(hold_s * 1000.0))
			apply(unit, brain, false)
			brain.set("ai_lod", Tier.NEAR)
			unit.set_meta(META_TIER, Tier.NEAR)
			if unit is Infantry:
				(unit as Infantry).far_lod = false
			woke += 1
	return woke
