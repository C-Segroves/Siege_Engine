class_name InfantryBot
extends Node
## The brain of an AI soldier (InfantryBots; host only; docs/formats/tribes_infantry.md section 7). It writes the
## soldier's controls as a player's InfantryPilot would and uses the same directors (bot id = its peer id):
##   ROAM    no enemy in sensor range: head for the nearest enemy anywhere;
##   FIGHT   strafe round the target at the chosen weapon's good range, aim (leading the target, lobbing
##           grenade shells), fire; throw a grenade at middle range;
##   COVER   hurt: run to a spot the target can't see (a crude sample round the bot), out of the fight;
##   REFILL  hurt or low on ammunition: walk onto the nearest usable inventory (refit, heal) or ammo station;
##   BOARD   light armour, no enemy near: walk to an EMPTY vehicle of its team whose pilot seat it may take
##           (BoardingRules: hatch for non-Tribes vehicles, touch for Tribes ones) - the vehicle's AI pilot
##           drives / flies it (InfantryBots); it gets out when the vehicle is crippled;
##   in a passenger seat it fires within the seat's arc, in a gunner seat it works the turret.
## Terrain: it follows a walkable path to its goal (InfantryBotRoute over BattleNavigation: into and out of bases),
## else runs straight at it, jumps and jets over what blocks its way (a knee-high probe ahead),
## jets up to goals above it (also from right below them) and when it gets stuck, keeping an energy reserve; stuck,
## it also sidesteps for a moment. A station or vehicle it gets no nearer to is given up for a while
## (InfantryBotProgress). With no enemy left alive it wanders instead of standing still. It fires only at
## targets within FIGHT_RANGE and, out of a fight, keeps the jet reserve from its energy weapons.
## A guard (guard_radius > 0, the extraction mode's faction squads) does not hunt enemies across the map: with
## nobody in sensor range it wanders within guard_radius of guard_point.
##   OBJECTIVE  a game mode's goal (GameModeBrains, `objective`): run there (urgent: a flag carrier, a grab, before
##           any fight; otherwise once no enemy is within FIGHT_RANGE), hold there when asked, shoot the
##           objective's target (an objective to destroy, a carrier to hunt).

enum Task { ROAM, FIGHT, COVER, REFILL, BOARD, OBJECTIVE }

const THINK_SECONDS := 0.4
const SENSOR_RANGE := 600.0
const FIGHT_RANGE := 250.0
const BOARD_SEARCH := 150.0
const BOARD_SAFE_DISTANCE := 120.0
const BOARD_MIN_INTEGRITY := 0.6
## A bot walks to this far from a non-Tribes hull (inside BoardingRules.HATCH_REACH).
const BOARD_HATCH_GAP := 1.5
const CRIPPLED_INTEGRITY := 0.3
const COVER_INTEGRITY := 0.4
const REFILL_INTEGRITY := 0.5
const REFILL_AMMO_FRACTION := 0.25
const STATION_SEARCH := 400.0
const COVER_SAMPLES := 8
const COVER_DISTANCE := 12.0
const ARRIVE := 2.0
## Obstacle probe: knee height, this far ahead (m).
const KNEE := 0.6
const PROBE_AHEAD := 2.5
## Jets when the goal is this much higher and this near (m).
const CLIMB_HEIGHT := 3.0
const CLIMB_NEAR := 40.0
## Starts jetting with this share of its energy, stops below this share.
const JET_START := 0.35
const JET_STOP := 0.08
const JET_HOLD := 0.6
const STUCK_SECONDS := 2.0
const STUCK_DISTANCE := 1.0
## A wall (a hit this steep: normal y below WALL_NORMAL_Y) in its way: it steers round it, trying these turns
## off its way (degrees) - slopes it jets up instead.
const WALL_NORMAL_Y := 0.3
const STEER_ANGLES_DEG := [40.0, -40.0, 80.0, -80.0, 120.0, -120.0]
## Stuck: it sidesteps (left or right of its way, a little forward) for this long.
const DETOUR_SECONDS := 1.2
const DETOUR_FORWARD := 0.3
## No enemy alive anywhere: it wanders to points this far away.
const WANDER_DISTANCE := 60.0
const AIM_TOLERANCE := 0.08
const AIM_HEIGHT_SOLDIER := 1.0
const AIM_HEIGHT_VEHICLE := 3.0
const GRENADE_RANGE := Vector2(12.0, 40.0)
const GRENADE_COOLDOWN := 5.0
const GRENADE_HOLD := 1.0
## Weapons are scored for a target inside this share of their range.
const GOOD_RANGE := 0.8
const STRAFE_WEIGHT := 0.7
const LEAVE_USELESS_SEAT := 2.0

var bot_id := 0
var soldier: Infantry
var skill := 0.5
var task := Task.ROAM
var goal := Vector3.ZERO
var target: Herc
## Where a guard stays (guard_radius 0: no guard post, it roams the map).
var guard_point := Vector3.ZERO
var guard_radius := 0.0
var _station := -1
var _vehicle_goal: Herc
var _think := 0.0
var _strafe := 1.0
var _jet_left := 0.0
var _grenade_t := 0.0
var _stuck_t := 0.0
var _stuck_from := Vector3.ZERO
var _useless_seat_t := 0.0
var _detour_t := 0.0
var _detour_side := 1.0
var _progress := InfantryBotProgress.new()
## The walkable way to the goal (BattleNavigation paths).
var _route := InfantryBotRoute.new()
## The game mode's goal ({} none): {point: Vector3, urgent: bool, radius: float, hold: bool, target: Node3D}.
var objective := {}


static func make(s: Infantry, id: int, p_skill: float) -> InfantryBot:
	var b := InfantryBot.new()
	b.soldier = s
	b.bot_id = id
	b.skill = p_skill
	b.name = "Bot"
	return b


func battle() -> Battle:
	return soldier.get_parent() as Battle


func _physics_process(delta: float) -> void:
	if not multiplayer.is_server() or soldier == null or not soldier.alive or battle().is_over():
		return
	_grenade_t -= delta
	_think -= delta
	if _think <= 0.0:
		_think = THINK_SECONDS
		_reconsider()
	if soldier.stowed:
		_ride(delta)
		return
	_aim_and_fire()
	_move(delta)


# ------------------------------------------------------------------ deciding

func _reconsider() -> void:
	target = _find_target()
	var hunted = objective.get("target")
	if hunted is Herc and is_instance_valid(hunted) and hunted.alive \
			and soldier.global_position.distance_to(hunted.global_position) < FIGHT_RANGE:
		target = hunted
	if soldier.stowed:
		return
	var d := soldier.global_position.distance_to(target.global_position) if target else INF
	if target and randf() < 0.3:
		_strafe = -_strafe
	if task != Task.BOARD or not _is_vehicle_free(_vehicle_goal):
		battle().infantry.bots.apply_release(bot_id)
		_vehicle_goal = null
	_choose_task(d)
	_apply_weapon_choice(d)


func _choose_task(d: float) -> void:
	_station = _find_refill_station() if _needs_refill() else -1
	if _station >= 0:
		task = Task.REFILL
		goal = (_stations().stations[_station].xf as Transform3D).origin
		_apply_refit()
	elif bool(objective.get("urgent", false)):
		_apply_objective_task()
	elif target and d < FIGHT_RANGE and soldier.integrity < COVER_INTEGRITY:
		task = Task.COVER
		goal = _find_cover(target)
	elif target and d < FIGHT_RANGE:
		task = Task.FIGHT
		goal = _make_fight_point(d)
	elif not objective.is_empty():
		_apply_objective_task()
	elif _choose_vehicle(d):
		task = Task.BOARD
		goal = _make_hatch_point(_vehicle_goal)
		_apply_board_when_near()
	else:
		var far := _find_target(INF) if guard_radius <= 0.0 else null
		goal = far.global_position if far else _make_wander_goal()
		task = Task.ROAM


func _apply_objective_task() -> void:
	var point: Vector3 = objective.point
	var radius := float(objective.get("radius", 10.0))
	var flat := Vector2(point.x - soldier.global_position.x, point.z - soldier.global_position.z)
	if bool(objective.get("hold", false)) and flat.length() < radius:
		goal = _make_wander_goal() if task == Task.OBJECTIVE else soldier.global_position
		goal = point + (goal - point).limit_length(radius)
	else:
		goal = point
	task = Task.OBJECTIVE


## The nearest enemy within `reach` it can sense (a jamming soldier hides beyond his jam radius).
func _find_target(reach := SENSOR_RANGE) -> Herc:
	var best: Herc = null
	var best_d := reach
	for v in soldier.get_tree().get_nodes_in_group("vehicles"):
		var h := v as Herc
		if h == null or h == soldier or not h.alive or not TeamRelations.is_hostile(soldier.team, h.team) or h.has_meta("dormant"):
			continue
		var d := soldier.global_position.distance_to(h.global_position)
		if d < best_d and not InfantryPack.is_hidden_at(h, d):
			best_d = d
			best = h
	return best


func _needs_refill() -> bool:
	if soldier.integrity < REFILL_INTEGRITY:
		return true
	var with_ammo := soldier.weapons.filter(func(w: Weapon) -> bool: return w.ammo_max > 0)
	return not with_ammo.is_empty() and with_ammo.all(func(w: Weapon) -> bool:
		return float(w.ammo) < float(w.ammo_max) * REFILL_AMMO_FRACTION)


func _stations() -> TribesStations:
	return battle().get_node_or_null("Stations") as TribesStations


## The nearest usable station it has not given up: an inventory station heals and refits, an ammo station
## only refills.
func _find_refill_station() -> int:
	var st := _stations()
	if st == null:
		return -1
	var kinds := ["inventory"] if soldier.integrity < REFILL_INTEGRITY else ["inventory", "ammo"]
	var best := -1
	var best_d := STATION_SEARCH
	for i in st.stations.size():
		if not (str(st.stations[i].kind) in kinds) or not st.may_use(soldier, i) 				or _progress.is_unreachable(InfantryBotProgress.make_station_key(i)):
			continue
		var d := soldier.global_position.distance_to((st.stations[i].xf as Transform3D).origin)
		if d < best_d:
			best_d = d
			best = i
	return best


## No enemy anywhere: the current wander point until it gets there, then another WANDER_DISTANCE away.
func _make_wander_goal() -> Vector3:
	var flat := Vector2(goal.x - soldier.global_position.x, goal.z - soldier.global_position.z)
	if task == Task.ROAM and flat.length() > ARRIVE * 2.0:
		return goal
	var dir := Basis(Vector3.UP, randf() * TAU) * Vector3.FORWARD
	if guard_radius > 0.0:
		return battle().infantry.make_on_ground(guard_point + dir * randf() * guard_radius)
	return battle().infantry.make_on_ground(soldier.global_position + dir * WANDER_DISTANCE)


## Standing on its inventory station: the same kit again, full (ammo stations refill by themselves).
func _apply_refit() -> void:
	var st := _stations()
	if st.find_station(soldier) == _station and st.stations[_station].kind == "inventory":
		st.apply_inventory(bot_id, soldier.armor_id, soldier.make_loadout(),
			{"grenade": soldier.kit.grenade_id, "pack": soldier.kit.pack_id})


## A spot near the bot that `from` can't see (a ray from it to the spot hits something), else away from it.
func _find_cover(from: Herc) -> Vector3:
	var space := soldier.get_world_3d().direct_space_state
	var eye := from.aim_origin()
	for i in COVER_SAMPLES:
		var dir := Basis(Vector3.UP, TAU * i / COVER_SAMPLES) * Vector3.FORWARD
		var spot := battle().infantry.make_on_ground(soldier.global_position + dir * COVER_DISTANCE)
		var q := PhysicsRayQueryParameters3D.create(eye, spot + Vector3.UP * AIM_HEIGHT_SOLDIER, 0xFFFFFFFF,
			[from.get_rid(), soldier.get_rid()])
		if not space.intersect_ray(q).is_empty():
			return spot
	var away := (soldier.global_position - from.global_position).normalized()
	return soldier.global_position + away * COVER_DISTANCE


## Where to stand in a fight: at the weapon's good range from the target, circling it.
func _make_fight_point(d: float) -> Vector3:
	var w := soldier.current_weapon()
	var want := w.weapon_range * GOOD_RANGE * 0.6 if w else 30.0
	var to := (target.global_position - soldier.global_position)
	to.y = 0.0
	var side := to.normalized().cross(Vector3.UP) * _strafe
	return soldier.global_position + to.normalized() * (d - want) + side * want * STRAFE_WEIGHT


## Takes the best weapon for the distance: the most damage per second among those in range with rounds or
## energy (splash weapons need room: not point-blank).
func _apply_weapon_choice(d: float) -> void:
	var best := soldier.weapon_slot
	var best_score := -1.0
	for i in soldier.weapons.size():
		var w: Weapon = soldier.weapons[i]
		if w.ammo == 0 or (d < INF and d > w.weapon_range * GOOD_RANGE) or (w.splash > 0.0 and d < ARRIVE * 3.0):
			continue
		var score := w.armor_damage * (1.0 + w.splash) / maxf(w.refire, 0.05)
		if score > best_score:
			best_score = score
			best = i
	if best != soldier.weapon_slot:
		soldier.apply_weapon_slot(best)


# ------------------------------------------------------------------ vehicles

func _choose_vehicle(enemy_distance: float) -> bool:
	if enemy_distance < BOARD_SAFE_DISTANCE or not bool(soldier.armor.get("can_pilot", false)):
		return false
	if _is_vehicle_free(_vehicle_goal):
		return true
	var best_d := BOARD_SEARCH
	for h in battle().vehicles.values():
		if not _is_vehicle_free(h):
			continue
		var d := soldier.global_position.distance_to((h as Herc).global_position)
		if d < best_d:
			best_d = d
			_vehicle_goal = h
	if _vehicle_goal:
		battle().infantry.bots.apply_claim(_vehicle_goal, bot_id)
	return _vehicle_goal != null


## An armed, sound, EMPTY vehicle of its team whose pilot seat it may take, no other bot heading for it.
func _is_vehicle_free(h) -> bool:
	if not is_instance_valid(h) or h is Infantry or not h.alive or h.team != soldier.team or h.weapons.is_empty():
		return false
	var v := h as Herc
	var occ := VehicleOccupancy.of(v)
	if not occ.is_empty() or v.integrity < BOARD_MIN_INTEGRITY or battle().infantry.bots.is_claimed_by_other(v, bot_id) 			or _progress.is_unreachable(InfantryBotProgress.make_vehicle_key(v)):
		return false
	var choice := BoardingRules.make_seat_choice(soldier, v, occ)
	return bool(choice.ok) and int(choice.seat) == VehicleOccupancy.PILOT_SEAT


## Beside the hull on the bot's side, within the hatch reach (a Tribes vehicle: touching it).
func _make_hatch_point(v: Herc) -> Vector3:
	var out := soldier.global_position - v.global_position
	out.y = 0.0
	var gap := BOARD_HATCH_GAP if not BoardingRules.is_boarded_by_touch(v.def) else 0.0
	return v.global_position + out.normalized() * (BoardingRules.make_hull_radius(v) + gap)


## Non-Tribes vehicles are boarded through the hatch (Tribes ones by walking into them).
func _apply_board_when_near() -> void:
	if not BoardingRules.is_boarded_by_touch(_vehicle_goal.def) and BoardingRules.is_within_hatch_reach(soldier, _vehicle_goal):
		battle().occupancy.apply_enter_exit(bot_id)


## Seated: out of a crippled vehicle or a seat that does nothing; fires from an armed seat, guns a turret.
func _ride(delta: float) -> void:
	var occupancy := battle().occupancy
	var v := occupancy.vehicle_of(bot_id)
	if v == null:
		return
	var role := VehicleSeats.make_role(v.vehicle_id, VehicleOccupancy.of(v).seat_of(bot_id))
	var useless := role == VehicleSeats.PASSENGER or (role != VehicleSeats.PILOT and not VehicleOccupancy.of(v).has_pilot())
	_useless_seat_t = _useless_seat_t + delta if useless else 0.0
	if v.integrity < CRIPPLED_INTEGRITY or _useless_seat_t > LEAVE_USELESS_SEAT:
		occupancy.apply_exit(bot_id, v)
		return
	if role == VehicleSeats.ARMED:
		_aim_and_fire()
	elif role == VehicleSeats.GUNNER:
		_gun_turret(v)


func _gun_turret(v: Herc) -> void:
	var crew := TurretCrew.find(v)
	if crew == null:
		return
	if target == null:
		crew.apply_idle()
		return
	var look := _make_look_point(target)
	var to := look - v.aim_origin()
	crew.torso_target = wrapf(atan2(-to.x, -to.z) - v.global_rotation.y, -PI, PI)
	crew.pitch_target = atan2(to.y, Vector2(to.x, to.z).length())
	var on_target := (-crew.make_aim_basis().z).angle_to(to.normalized()) < AIM_TOLERANCE * 2.0
	crew.apply_fire_groups(on_target, on_target and to.length() < FIGHT_RANGE)


# ------------------------------------------------------------------ acting

## What it shoots at: its target, else a live objective target (a structure to destroy) within FIGHT_RANGE.
func _make_aim_node() -> Node3D:
	if target:
		return target
	var t = objective.get("target")
	if t is Node3D and is_instance_valid(t) and bool(t.get("alive")) \
			and soldier.global_position.distance_to((t as Node3D).global_position) < FIGHT_RANGE:
		return t
	return null


func _make_look_point(h: Node3D) -> Vector3:
	var height := AIM_HEIGHT_SOLDIER if h is Infantry else AIM_HEIGHT_VEHICLE
	var p := h.global_position + Vector3.UP * height
	var w := soldier.current_weapon()
	if w and not w.fires_beam() and w.projectile_speed > 1.0 and h is CharacterBody3D:
		p += (h as CharacterBody3D).velocity * soldier.aim_origin().distance_to(p) / w.projectile_speed
	return p


## Looks at the target (else the goal) and fires the weapon in hand when it is on target and in range.
func _aim_and_fire() -> void:
	var aim_node := _make_aim_node()
	var look := _make_look_point(aim_node) if aim_node else goal + Vector3.UP * soldier.eye.position.y
	var to := look - soldier.aim_origin()
	if Vector2(to.x, to.z).length() < ARRIVE:
		to = -soldier.aim_basis().z   # arrived: keep looking the same way
	var err := (1.0 - skill) * AIM_TOLERANCE
	soldier.torso_target = atan2(-to.x, -to.z) + randf_range(-err, err)
	soldier.pitch_target = atan2(to.y, Vector2(to.x, to.z).length()) + _make_lob_angle(to)
	var w := soldier.current_weapon()
	var aim_ok := aim_node != null and (-soldier.aim_basis().z).angle_to(to.normalized()) < AIM_TOLERANCE + absf(_make_lob_angle(to))
	var in_range := w != null and to.length() < minf(w.weapon_range, FIGHT_RANGE) and _may_spend_energy(w)
	for weapon in soldier.weapons:
		weapon.trigger = aim_ok and weapon == w and in_range
	if target and not soldier.stowed:
		_throw_grenade(to.length())


## Out of a fight an energy weapon keeps the jet reserve (JET_START): a bot that shoots its energy away can't
## jet over what blocks its way.
func _may_spend_energy(w: Weapon) -> bool:
	return w.per_shot <= 0 or task == Task.FIGHT or soldier.capacitor > soldier.capacitor_max * JET_START


## Extra pitch for a lobbed shell to land `to` away (the low ballistic arc), 0 for straight shots.
func _make_lob_angle(to: Vector3) -> float:
	var w := soldier.current_weapon()
	if w == null or target == null:
		return 0.0
	var g := float((w.def.get("projectile", {}) if w.def.get("projectile") is Dictionary else {}).get("gravity", 0.0))
	if g <= 0.0:
		return 0.0
	var s := g * Vector2(to.x, to.z).length() / (w.projectile_speed * w.projectile_speed)
	return 0.5 * asin(clampf(s, -1.0, 1.0))


func _throw_grenade(d: float) -> void:
	if _grenade_t > 0.0 or d < GRENADE_RANGE.x or d > GRENADE_RANGE.y or soldier.kit.count(soldier.kit.grenade_id) <= 0:
		return
	_grenade_t = GRENADE_COOLDOWN
	battle().infantry.gear.apply_throw(bot_id, InfantryGearDirector.SLOT_GRENADE, GRENADE_HOLD)


## Runs at the goal (strafing in a fight), jumping and jetting over obstacles and up to high goals.
func _move(delta: float) -> void:
	var step := _route.make_next_point(battle(), soldier.global_position, goal, delta)
	var to := step - soldier.global_position
	var flat := Vector3(to.x, 0.0, to.z)
	var arrived := step == goal and flat.length() <= ARRIVE
	var wish := flat.normalized() if not arrived and flat.length() > 0.01 else Vector3.ZERO
	if task == Task.FIGHT and target:
		var side := (target.global_position - soldier.global_position).normalized().cross(Vector3.UP) * _strafe
		wish = (wish + side * STRAFE_WEIGHT).normalized()
	_detour_t -= delta
	if _detour_t > 0.0 and wish != Vector3.ZERO:
		wish = (wish.cross(Vector3.UP) * _detour_side + wish * DETOUR_FORWARD).normalized()
	wish = _make_steered_wish(wish)
	var local := Basis(Vector3.UP, -soldier.torso_target) * wish
	soldier.throttle = -local.z
	soldier.turn = local.x
	var climb := to.y > CLIMB_HEIGHT and flat.length() < CLIMB_NEAR   # also from right below the goal
	_apply_jet(delta, climb or (wish != Vector3.ZERO and (_is_blocked(wish) or _is_stuck(delta, wish))))
	if task == Task.BOARD and is_instance_valid(_vehicle_goal):
		goal = _make_hatch_point(_vehicle_goal)
		_apply_board_when_near()
	_apply_progress(delta)


## Gives up a station or vehicle it gets no nearer to (InfantryBotProgress) and decides afresh.
func _apply_progress(delta: float) -> void:
	var key := ""
	if task == Task.REFILL and _station >= 0:
		key = InfantryBotProgress.make_station_key(_station)
	elif task == Task.BOARD and is_instance_valid(_vehicle_goal):
		key = InfantryBotProgress.make_vehicle_key(_vehicle_goal)
	if key == "" or soldier.global_position.distance_to(goal) <= ARRIVE * 2.0:
		return   # there (standing on the station): no progress to make
	_progress.apply_sample(key, soldier.global_position.distance_to(goal), delta)
	if _progress.is_unreachable(key):
		_think = 0.0


func _apply_jet(delta: float, wanted: bool) -> void:
	var energy := soldier.capacitor / maxf(soldier.capacitor_max, 1.0)
	if wanted and energy > JET_START:
		_jet_left = JET_HOLD
	_jet_left = _jet_left - delta if energy > JET_STOP else 0.0
	soldier.jet_input = _jet_left > 0.0
	soldier.jump_input = _jet_left > 0.0 and soldier.is_on_floor()


## Something knee-high in the way along `wish`.
func _is_blocked(wish: Vector3) -> bool:
	return not _probe_ahead(wish).is_empty()


## `wish` turned round a wall ahead (the first of STEER_ANGLES_DEG with nothing in the way); unchanged when
## nothing or only a slope is ahead, or when every way is blocked (it jets then).
func _make_steered_wish(wish: Vector3) -> Vector3:
	if wish == Vector3.ZERO or not _is_wall(_probe_ahead(wish)):
		return wish
	for deg in STEER_ANGLES_DEG:
		var turned := Basis(Vector3.UP, deg_to_rad(deg) * _detour_side) * wish
		if _probe_ahead(turned).is_empty():
			return turned
	return wish


static func _is_wall(hit: Dictionary) -> bool:
	return not hit.is_empty() and (hit.normal as Vector3).y < WALL_NORMAL_Y


## The knee-high ray hit PROBE_AHEAD along `wish` ({} when clear; soldiers don't count).
func _probe_ahead(wish: Vector3) -> Dictionary:
	var from := soldier.global_position + Vector3.UP * KNEE
	var exclude: Array[RID] = [soldier.get_rid()]
	if task == Task.BOARD and is_instance_valid(_vehicle_goal):
		exclude.append(_vehicle_goal.get_rid())   # walking up to it, not over it
	var q := PhysicsRayQueryParameters3D.create(from, from + wish * PROBE_AHEAD, 0xFFFFFFFF, exclude)
	var hit := soldier.get_world_3d().direct_space_state.intersect_ray(q)
	return {} if hit.is_empty() or hit.collider is Infantry else hit


## Wanting to move but not getting anywhere for STUCK_SECONDS (then it also starts a sidestep, DETOUR_SECONDS).
func _is_stuck(delta: float, wish: Vector3) -> bool:
	_stuck_t += delta
	if _stuck_t < STUCK_SECONDS:
		return false
	var stuck := wish != Vector3.ZERO and soldier.global_position.distance_to(_stuck_from) < STUCK_DISTANCE
	_stuck_t = 0.0
	_stuck_from = soldier.global_position
	if stuck:
		_detour_t = DETOUR_SECONDS
		_detour_side = -_detour_side
	return stuck
