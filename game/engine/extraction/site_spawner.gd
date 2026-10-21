class_name SiteSpawner
extends Node
## The site populations of a raid on a map with faction sites (Varuna's Fall; map "sites"; extraction_rules.json
## "site_spawns"; docs/design/extraction_map_varuna.md), CoD DMZ style. Host-authoritative: bots are spawned on every
## peer like all raid bots (ExtractionSquads), a client only sees them.
##   monitor     every site keeps a target headcount (its size's range, the horde's more at night) and, when soldiers
##               are missing and a player is within activation_radius_m, refills a batch at one of its 2-4 spawn areas
##               each time its timer runs out; the timer is shorter under attack (a loss, a destroyed base object, a
##               stolen flag of the faction), longer for humans and shorter for the horde at night
##   patrols     now and then a few soldiers of a faction walk from one of its sites to another and join its garrison
##   raids       the horde's caves send a raiding party at night-weighted intervals against the weakest site in range
##   day         a clock (day.length_s) with a night phase (DayCycle); the sky, sun and fog follow it (DayCycleLight) and it weighs the timers
## It is a child "SiteSpawner" of the ExtractionDirector; the director asks it for the opening populations (they give
## the kill and flag tasks their targets) and the sites' faction teams.

const NODE_NAME := "SiteSpawner"
## Meta of a soldier a rifle scope looked at: until this tick (ms) he keeps the full step rate (far_lod off).
const META_LOD_HOLD := "scope_lod_hold_until_ms"

var director: ExtractionDirector
var rng := RandomNumberGenerator.new()
## Per site: {id, name, faction, team, size, pos, pad_radius, areas: [Vector3], headcount: [lo, hi], reinforce_s: [lo, hi],
## target, bots: [InfantryBot], timer, attacked_until, spawned, awake, active}.
var sites: Array[Dictionary] = []
## faction id -> [Vector3] loot areas of its sites (RaidTasks finds its bases there).
var placed_areas := {}
var clock_s := 0.0
var patrols: Array = []
var raids: Array = []
var raid_count := 0
var patrol_count := 0
## The Cybrid siege (CybridSiege) stretches the reinforcement timers by this factor and stops patrols and raids.
var refill_factor := 1.0
var movement_paused := false
## Id of the patrol and the raid timer in _timers.
const TIMER_PATROL := "patrol"
const TIMER_RAID := "raid"
const TRIGGER_REINFORCE := "reinforce:"

var _clock := MissionClock.new()               # the monitor tick (rules().tick_s)
var _timers := MissionTimers.new()             # the patrol and raid intervals
var _waves: WaveDirector                       # one reinforcement batch per site (group = site id)
var _budget := 0                               # soldiers the batches of this monitor tick may still bring


static func rules() -> Dictionary:
	return ExtractionRules.data().get("site_spawns", {})


## True when the built map has faction sites.
static func has_sites(built: Dictionary) -> bool:
	var m = built.get("map")
	return m is Dictionary and not (m.get("sites", []) as Array).is_empty()


func _init(p_director: ExtractionDirector) -> void:
	director = p_director
	name = NODE_NAME
	_waves = WaveDirector.new(_spawn_batch, count_alive_of_group)


## Host: reads the map's sites; the sites of a faction this install cannot field are left out.
func start_host(rng_seed: int) -> void:
	rng.seed = rng_seed
	var m: Dictionary = director.built.map
	var available := ExtractionFactions.make_available().map(func(f: Dictionary) -> String: return str(f.id))
	var faction_ids: Array = ExtractionRules.factions().map(func(f: Dictionary) -> String: return str(f.id))
	clock_s = DayCycle.make_start_clock(day_timing())
	for s in m.sites:
		var fid := str(s.faction)
		if not available.has(fid):
			continue
		var site := {"id": str(s.id), "name": str(s.name), "faction": fid, "team": ExtractionFactions.make_team(faction_ids.find(fid)),
			"size": str(s.size), "pad_radius": float(s.pad_radius), "headcount": s.headcount, "reinforce_s": s.reinforce_s,
			"pos": make_ground_point(Vector2(float(s.pos[0]), float(s.pos[2]))), "areas": [], "bots": [], "spawned": 0,
			"attacked_until": -1.0, "awake": false}
		for a in s.spawn_areas:
			site.areas.append(make_ground_point(Vector2(float(a[0]), float(a[1]))))
		site["target"] = make_target(site)
		site["timer"] = make_timer_of(site)
		_waves.apply_add(SpawnWave.make_wave(str(site.id), TRIGGER_REINFORCE + str(site.id)))
		sites.append(site)
	for a in m.get("loot_areas", []):
		var fid := str(a.faction)
		if available.has(fid):
			if not placed_areas.has(fid):
				placed_areas[fid] = []
			placed_areas[fid].append(make_ground_point(Vector2(float(a.pos[0]), float(a.pos[1]))))
	apply_patrol_in(roll_seconds("patrol"))
	_timers.apply_add(TIMER_RAID, MissionTimer.make_timer(roll_seconds("raid"), MissionTimer.Mode.ONE_SHOT, TIMER_RAID))


func make_ground_point(p: Vector2) -> Vector3:
	return director.battle.infantry.make_on_ground(Vector3(p.x, 0.0, p.y))


## {team: faction id} of the factions that hold sites here.
func make_teams() -> Dictionary:
	var out := {}
	for s in sites:
		out[int(s.team)] = str(s.faction)
	return out


## Host: fills every site to initial_fraction of its target (the tasks need targets from the first second).
func spawn_initial() -> void:
	var fraction := float(rules().get("initial_fraction", 0.5))
	for s in sites:
		_spawn_at_site(s, ceili(float(s.target) * fraction))


# ------------------------------------------------------------------ time

## Position in the day (0..1).
func make_phase() -> float:
	return DayCycle.make_phase(day_timing(), clock_s)


## The raid's day: the record the sky and sun follow too (DayCycleLight), so night here is dark there.
static func day_timing() -> Dictionary:
	return rules().get("day", {})


func is_night() -> bool:
	return DayCycle.is_night(day_timing(), make_phase())


func _night_factor(table_key: String, faction_id: String) -> float:
	if not is_night():
		return 1.0
	var table: Dictionary = (rules().get("day", {}) as Dictionary).get(table_key, {})
	return float(table.get(ExtractionFactions.kind_of(faction_id), 1.0))


func roll_seconds(key: String) -> float:
	var pair: Array = (rules().get(key, {}) as Dictionary).get("interval_s", [60.0, 90.0])
	return rng.randf_range(float(pair[0]), float(pair[1]))


## The headcount a site aims for now.
func make_target(site: Dictionary) -> int:
	var pair: Array = site.headcount
	return roundi(float(rng.randi_range(int(pair[0]), int(pair[1]))) * _night_factor("night_headcount_factor", str(site.faction)))


## The countdown to the site's next reinforcement batch (site["timer"]; it only counts while the site is awake and
## short of its target, and stays run out until the batch could come).
func make_timer_of(site: Dictionary) -> MissionTimer:
	return MissionTimer.make_timer(make_timer(site))


## Seconds until the site's next reinforcement batch.
func make_timer(site: Dictionary) -> float:
	var pair: Array = site.reinforce_s
	var t := rng.randf_range(float(pair[0]), float(pair[1]))
	if clock_s < float(site.attacked_until):
		t *= float(rules().get("under_attack_timer_factor", 0.5))
	return t * _night_factor("night_timer_factor", str(site.faction)) * refill_factor


# ------------------------------------------------------------------ monitor

func find_site(site_id: String) -> Dictionary:
	for s in sites:
		if str(s.id) == site_id:
			return s
	return {}


## Live soldiers of the site's garrison (dead and removed ones are dropped from its list).
func count_alive(site: Dictionary) -> int:
	var alive := []
	for b in site.bots:
		if is_instance_valid(b) and (b as InfantryBot).soldier.alive:
			alive.append(b)
	if alive.size() < site.bots.size():
		site["attacked_until"] = clock_s + float(rules().get("under_attack_s", 90.0))
		_apply_shorter_timer(site)
	site["bots"] = alive
	return alive.size()


func count_total_alive() -> int:
	var n := 0
	for s in sites:
		n += count_alive(s)
	for r in raids:
		n += (r.bots as Array).filter(func(b) -> bool: return is_instance_valid(b) and (b as InfantryBot).soldier.alive).size()
	return n


## Soldiers that count against max_alive: the living awake ones (BotSleep sleepers cost nothing, so they must not fill
## the cap and stop the sites near a player from refilling).
func count_awake_alive() -> int:
	var n := 0
	var lists: Array = []
	for s in sites:
		lists.append(s.bots)
	for r in raids:
		lists.append(r.bots)
	for l in lists:
		for b in l:
			if is_instance_valid(b) and (b as InfantryBot).soldier.alive and not BotSleep.is_asleep((b as InfantryBot).soldier):
				n += 1
	return n


## The site is under attack for `seconds` (a destroyed base object, a stolen flag).
func apply_alert(site: Dictionary, seconds: float) -> void:
	site["attacked_until"] = maxf(float(site.attacked_until), clock_s + seconds)
	_apply_shorter_timer(site)


## The site's timer restarts at the shorter of what is left and a fresh roll.
func _apply_shorter_timer(site: Dictionary) -> void:
	site["timer"] = MissionTimer.make_timer(minf((site.timer as MissionTimer).make_time_left(), make_timer(site)))


## Seconds left on the site's reinforcement timer.
func make_timer_left(site: Dictionary) -> float:
	return (site.timer as MissionTimer).make_time_left()


## The next patrol sets out in `seconds`.
func apply_patrol_in(seconds: float) -> void:
	_timers.apply_add(TIMER_PATROL, MissionTimer.make_timer(seconds, MissionTimer.Mode.ONE_SHOT, TIMER_PATROL))


func is_under_attack(site: Dictionary) -> bool:
	return clock_s < float(site.attacked_until)


func _physics_process(delta: float) -> void:
	if not is_inside_tree() or not multiplayer.is_server() or sites.is_empty():
		return
	clock_s += delta
	var dt := _clock.make_step(delta, float(rules().get("tick_s", 0.5)))
	if dt > 0.0:
		apply_tick(dt)


## One monitor step of `dt` seconds (the physics tick; tests call it with their own clock).
func apply_tick(dt: float) -> void:
	_apply_alerts()
	var players := _find_player_positions()
	_apply_soldier_lod(players)
	_budget = int(rules().get("max_spawn_per_tick", 3))
	for s in sites:
		s["awake"] = _is_near(s.pos, players)
		var alive := count_alive(s)
		s["target"] = maxi(int(s.target), 0)
		if alive >= int(s.target) or not bool(s.awake):
			continue
		var timer: MissionTimer = s.timer
		timer.apply_tick(dt)
		if timer.make_time_left() <= 0.0 and _budget > 0 and count_awake_alive() < int(rules().get("max_alive", 70)):
			_waves.apply_trigger(TRIGGER_REINFORCE + str(s.id))
			s["timer"] = make_timer_of(s)
	var due := _timers.apply_tick(dt)
	_apply_patrols(due.has(TIMER_PATROL) and not movement_paused)
	_apply_raids(due.has(TIMER_RAID) and not movement_paused)


## A reinforcement batch of the site `group` is due (WaveDirector arrival): a rolled number of soldiers, cut to what
## is missing and to the tick's spawn budget.
func _spawn_batch(group: String, _count: int) -> void:
	var s := find_site(group)
	var missing := int(s.target) - count_alive(s)
	var batch := mini(ExtractionRules.roll_range(rng, rules().get("batch", [1, 2])), missing)
	_budget -= _spawn_at_site(s, batch)


## Living soldiers of site `group`.
func count_alive_of_group(group: String) -> int:
	return count_alive(find_site(group))


## Soldiers farther than lod_radius_m from every player step at a reduced rate (Infantry.far_lod).
func _apply_soldier_lod(players: Array) -> void:
	if BotSleep.is_enabled():
		return   # the BotSleep tier director sets far_lod for every AI soldier
	var reach := float(rules().get("lod_radius_m", 150.0))
	for v in director.battle.vehicles.values():
		var h := v as Infantry
		if h == null or not is_instance_valid(h):
			continue
		var far := not players.is_empty()
		for q in players:
			if Vector2(h.global_position.x - q.x, h.global_position.z - q.z).length() <= reach:
				far = false
				break
		h.far_lod = far and not h.stowed and director.faction_teams.has(h.team) 				and Time.get_ticks_msec() >= int(h.get_meta(META_LOD_HOLD, 0))


## Removes up to `n` living garrison soldiers, the ones farthest from every player (the Cybrid siege takes their room under
## the bot cap, BotBudget); returns how many left.
func apply_retire_farthest(n: int) -> int:
	var players := _find_player_positions()
	var ranked := []
	for s in sites:
		for b in s.bots:
			if is_instance_valid(b) and (b as InfantryBot).soldier.alive:
				ranked.append({"bot": b, "site": s, "far": _make_nearest_distance((b as InfantryBot).soldier.global_position, players)})
	ranked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.far) > float(b.far))
	var gone := 0
	for r in ranked.slice(0, n):
		(r.site.bots as Array).erase(r.bot)
		director.battle.remove_vehicle((r.bot as InfantryBot).soldier.net_id)
		gone += 1
	return gone


static func _make_nearest_distance(at: Vector3, points: Array) -> float:
	var best := INF
	for p in points:
		best = minf(best, Vector2(at.x - p.x, at.z - p.z).length())
	return best


## Wakes the units within `radius` of `center` (BotSleep.wake_area; the rifle scope's TODO names this call).
func wake_area(center: Vector3, radius: float, hold_s := 1.0) -> int:
	var hold_until := Time.get_ticks_msec() + int(hold_s * 1000.0)
	for v in director.battle.vehicles.values():
		var h := v as Infantry
		if h != null and is_instance_valid(h) and Vector2(h.global_position.x - center.x, h.global_position.z - center.z).length() <= radius:
			h.far_lod = false
			h.set_meta(META_LOD_HOLD, hold_until)   # _apply_soldier_lod keeps him at the full rate meanwhile
	return director.battle.bot_sleep.wake_area(center, radius, hold_s)


func _find_player_positions() -> Array:
	var out := []
	for peer in director.make_raid_peers():
		var soldier := director.battle.occupancy.soldier_of(int(peer))
		if soldier != null and soldier.alive:
			out.append(soldier.global_position)
	return out


func _is_near(p: Vector3, players: Array) -> bool:
	var reach := float(rules().get("activation_radius_m", 900.0))
	for q in players:
		if Vector2(p.x - q.x, p.z - q.z).length() <= reach:
			return true
	return false


## Raid tasks of a stolen flag put the owner's sites under attack; a destroyed base object does so at the site it stood in.
func _apply_alerts() -> void:
	var response = director.tasks.response if director.tasks != null else null
	if response == null:
		return
	for r in response.responses.values():
		if str(r.state) != "done":
			for s in sites:
				if str(s.faction) == str(r.faction):
					apply_alert(s, float(rules().get("under_attack_s", 90.0)))


## A base object was destroyed at `p`: the nearest site is under attack (ExtractionDirector connects TribesBase).
func apply_object_destroyed(p: Vector3) -> void:
	var best := {}
	var best_d := INF
	for s in sites:
		var d := Vector2(p.x - s.pos.x, p.z - s.pos.z).length()
		if d < best_d:
			best_d = d
			best = s
	if not best.is_empty() and best_d < float(best.pad_radius) * 3.0 + 200.0:
		apply_alert(best, float(rules().get("under_attack_s", 90.0)))


## Spawns `n` soldiers at random spawn areas of `site`; returns how many came.
func _spawn_at_site(site: Dictionary, n: int) -> int:
	var made := 0
	if director.squads == null or site.areas.is_empty():
		return 0
	for i in n:
		LoadKeepAlive.pump()
		var at: Vector3 = site.areas[rng.randi_range(0, site.areas.size() - 1)]
		var b := director.squads.spawn_site_soldier(str(site.faction), int(site.team), at, int(site.spawned), site.pos,
			float(site.pad_radius) * float(rules().get("guard_radius_factor", 1.6)))
		site["spawned"] = int(site.spawned) + 1
		if b != null:
			site.bots.append(b)
			made += 1
	return made


# ------------------------------------------------------------------ patrols and raids

func _apply_patrols(is_due: bool) -> void:
	var pr: Dictionary = rules().get("patrol", {})
	for p in patrols.duplicate():
		_advance_patrol(p, float(pr.get("arrive_m", 45.0)))
		if p.bots.is_empty():
			patrols.erase(p)
	if not is_due:
		return
	apply_patrol_in(roll_seconds("patrol"))
	var order := sites.duplicate()
	order.shuffle()
	var size := ExtractionRules.roll_range(rng, pr.get("size", [2, 3]))
	for src in order:
		var peers := sites.filter(func(s: Dictionary) -> bool: return str(s.faction) == str(src.faction) and s != src)
		if peers.is_empty() or count_alive(src) < int(pr.get("min_site_alive", 3)) + size:
			continue
		var dest: Dictionary = peers[rng.randi_range(0, peers.size() - 1)]
		var walkers: Array = []
		for k in size:
			var b: InfantryBot = src.bots.pop_back()
			b.guard_radius = 0.0
			b.objective = {"point": dest.pos, "radius": float(pr.get("arrive_m", 45.0)), "urgent": false, "hold": false}
			walkers.append(b)
		patrols.append({"bots": walkers, "dest": dest, "src": src})
		patrol_count += 1
		return


## Patrol soldiers that reached the destination join its garrison.
func _advance_patrol(p: Dictionary, arrive: float) -> void:
	var dest: Dictionary = p.dest
	for b in (p.bots as Array).duplicate():
		if not is_instance_valid(b) or not (b as InfantryBot).soldier.alive:
			p.bots.erase(b)
		elif Vector2(b.soldier.global_position.x - dest.pos.x, b.soldier.global_position.z - dest.pos.z).length() <= arrive:
			b.objective = {}
			b.guard_point = dest.pos
			b.guard_radius = float(dest.pad_radius) * float(rules().get("guard_radius_factor", 1.6))
			dest.bots.append(b)
			p.bots.erase(b)


func _apply_raids(is_due: bool) -> void:
	var rr: Dictionary = rules().get("raid", {})
	for r in raids.duplicate():
		_advance_raid(r, float(rr.get("arrive_m", 70.0)))
		if r.bots.is_empty():
			raids.erase(r)
	if not is_due:
		return
	var interval := roll_seconds("raid") * (float(rr.get("night_interval_factor", 0.5)) if is_night() else 1.0)
	_timers.apply_add(TIMER_RAID, MissionTimer.make_timer(interval, MissionTimer.Mode.ONE_SHOT, TIMER_RAID))
	start_raid()


## The raiding faction's caves send a party at the weakest other site in range; false when it has no site or no target.
func start_raid() -> bool:
	var rr: Dictionary = rules().get("raid", {})
	var faction := str(rr.get("faction", "bioderm"))
	if count_awake_alive() >= int(rules().get("max_alive", 70)):
		return false
	var sources := sites.filter(func(s: Dictionary) -> bool: return str(s.faction) == faction)
	if sources.is_empty():
		return false
	var src: Dictionary = sources[rng.randi_range(0, sources.size() - 1)]
	var target := find_weakest_site(src, faction, float(rr.get("range_m", 2600.0)))
	if target.is_empty():
		return false
	var party: Array = []
	for k in ExtractionRules.roll_range(rng, rr.get("size", [4, 7])):
		var at: Vector3 = src.areas[rng.randi_range(0, src.areas.size() - 1)]
		var b := director.squads.spawn_site_soldier(faction, int(src.team), at, k, src.pos, 0.0)
		if b != null:
			b.guard_radius = 0.0
			b.objective = {"point": target.pos, "radius": float(rr.get("arrive_m", 70.0)), "urgent": true, "hold": false}
			party.append(b)
	if party.is_empty():
		return false
	raids.append({"bots": party, "target": target})
	raid_count += 1
	return true


## The site (not of `faction`, within `range_m` of `from`) with the lowest garrison fraction.
func find_weakest_site(from: Dictionary, faction: String, range_m: float) -> Dictionary:
	var best := {}
	var best_f := INF
	for s in sites:
		if str(s.faction) == faction or Vector2(s.pos.x - from.pos.x, s.pos.z - from.pos.z).length() > range_m:
			continue
		var f := float(count_alive(s)) / maxf(float(s.target), 1.0)
		if f < best_f:
			best_f = f
			best = s
	return best


## Raiders that reached the target hold there as roaming guards (they fight whoever they meet).
func _advance_raid(r: Dictionary, arrive: float) -> void:
	var target: Dictionary = r.target
	for b in (r.bots as Array).duplicate():
		if not is_instance_valid(b) or not (b as InfantryBot).soldier.alive:
			r.bots.erase(b)
		elif Vector2(b.soldier.global_position.x - target.pos.x, b.soldier.global_position.z - target.pos.z).length() <= arrive:
			b.objective = {}
			b.guard_point = target.pos
			b.guard_radius = float(target.pad_radius) * 2.0
