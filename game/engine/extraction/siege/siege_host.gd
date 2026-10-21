class_name SiegeHost
extends RefCounted
## The host's brain of the Cybrid siege (docs/design/cybrid_siege.md), built on the shared mission blocks:
##   hidden chain   SiegeRelays (AreaTriggers) + SiegeChain (MissionTimers): three buried relays woken in a per-raid order
##   warning        MissionAnnouncer lines to everyone, a MissionTimers countdown (SiegeTimeline), the truce (TeamRelations)
##   siege          WaveDirector / SpawnWave waves from the map's edges (SiegeSpawner, SiegeCommander), exfils closing on the
##                  timeline, the shrinking safe area enforced by the LeftAreaRule FailRule plus damage (SiegeEnforcer)
##   final          a MissionEnder carries out "nothing survives" after the final time
## CybridSiege (the node) owns the network side and calls apply_tick; every public apply_* here is what a test can drive.

signal phase_changed(phase: int)

var node: CybridSiege
var director: ExtractionDirector
var battle: Battle
var rng := RandomNumberGenerator.new()
var phase: int = SiegePhase.ARMED
var cybrid_team := -1
var wave_number := 0
var last_zone := -1
var chain: SiegeChain
var relays := SiegeRelays.new()
var fragments := SiegeFragments.new()
var timeline := SiegeTimeline.new()
var sink := SiegeSink.new()
var announcer := MissionAnnouncer.new(sink, MissionAnnouncer.Discipline.FIFO)
var waves: WaveDirector
var spawner: SiegeSpawner
var commander: SiegeCommander
var zone: SiegeZone
var enforcer: SiegeEnforcer
var ender: MissionEnder
var _scan_clock := MissionClock.new()
var _step_clock := MissionClock.new()
var _retarget_clock := MissionClock.new()


func _init(p_node: CybridSiege) -> void:
	node = p_node
	director = p_node.director
	battle = director.battle
	sink.say = node.say_all
	ender = MissionEnder.new(_annihilate, func() -> bool: return false)
	timeline.announced.connect(_on_announced)
	timeline.arrived.connect(apply_siege_start)
	timeline.exfil_closing.connect(_on_exfil_closing)
	timeline.last_exfil_open.connect(_on_last_exfil_open)
	timeline.final_stand.connect(_on_final_stand)


## Lays the hidden chain out on the built map; false when the map or the install cannot carry the siege.
func start(built: Dictionary, seed_value: int) -> bool:
	if not CybridRules.is_available(built):
		return false
	cybrid_team = CybridRules.make_cybrid_team()
	if cybrid_team < 0:
		return false
	rng.seed = seed_value
	var data := CybridRules.map_data(built)
	_apply_relays(data, built)
	if relays.points.size() < 3:
		return false
	chain = SiegeChain.make(SiegeChain.make_shuffled(relays.points.keys(), rng), float(CybridRules.section("trigger").get("chain_window_s", 600.0)))
	_apply_fragments(data)
	relays.band_changed.connect(func(peer: int, band: int, _id: String) -> void: node.tell_band(peer, band))
	spawner = SiegeSpawner.new(director, cybrid_team, rng.randi())
	commander = SiegeCommander.new(spawner)
	waves = WaveDirector.new(_spawn_wave, func(_group: String) -> int: return spawner.count_alive())
	SiegeWaves.apply_to(waves)
	return true


func _apply_relays(data: Dictionary, built: Dictionary) -> void:
	var trigger := CybridRules.section("trigger")
	for r in data.get("relays", []):
		for s in (built.map as Dictionary).get("sites", []):
			var areas: Array = s.get("spawn_areas", [])
			if str(s.id) == str(r.site) and not areas.is_empty():
				var a: Array = areas[clampi(int(r.get("area", 0)), 0, areas.size() - 1)]
				relays.apply_add(str(r.id), director.map.make_ground(Vector2(float(a[0]), float(a[1]))),
					float(trigger.get("reach_m", 3.5)), float(trigger.get("sense_m", 14.0)))


func _apply_fragments(data: Dictionary) -> void:
	var f: Dictionary = data.get("fragments", {})
	fragments.apply_roll(chain.order, f.get("lines", {}))
	var dry := func(p: Vector2) -> bool: return director.map.is_inside(p) and not MapWater.is_in_water(battle.get_tree(), director.map.make_ground(p))
	for pl in SiegeFragments.make_placements(f.get("spots", []), int(CybridRules.section("fragments").get("per_rank", 2)), chain.order.size(), rng, dry):
		director.add_container({"kind": SiegeFragments.RECORDER_KIND, "stacks": [[SiegeFragments.make_item_id(int(pl.rank)), 1]], "money": 0},
			director.map.make_ground(pl.pos))
	fragments.apply_echoes(f.get("echoes", []), dry)
	fragments.echoed.connect(func(peer: int, rank: int) -> void: node.tell_hint(peer, rank, CybridRules.section("fragments").get("echo_text", "%s") % fragments.hints[rank]))


# ------------------------------------------------------------------ every physics frame

func apply_tick(delta: float) -> void:
	announcer.apply_tick(delta)
	if phase == SiegePhase.ARMED:
		_tick_armed(_scan_clock.make_step(delta, float(CybridRules.data().get("tick_s", 0.5))))
	elif phase != SiegePhase.ENDED:
		_tick_active(delta)
	ender.apply_tick(delta)


func _tick_armed(dt: float) -> void:
	if dt <= 0.0:
		return
	var positions := _make_player_positions()
	relays.apply_scan(positions)
	fragments.apply_scan(positions)
	chain.apply_tick(dt)


func _tick_active(delta: float) -> void:
	timeline.apply_tick(delta)
	if phase != SiegePhase.SIEGE:
		return
	waves.apply_tick(delta)
	var dt := _step_clock.make_step(delta, float(CybridRules.data().get("tick_s", 0.5)))
	if dt > 0.0:
		enforcer.apply_tick(dt, timeline.siege_s)
	if _retarget_clock.make_step(delta, float(CybridRules.section("waves").get("retarget_s", 8.0))) > 0.0:
		commander.apply_retarget()


func _make_player_positions() -> Dictionary:
	var out := {}
	for peer in director.make_raid_peers():
		var s := battle.occupancy.soldier_of(int(peer))
		if s != null and s.alive and not s.stowed:
			out[int(peer)] = s.global_position
	return out


# ------------------------------------------------------------------ the chain

## A player digs where he stands: the plate in reach is woken, or the hum answers.
func apply_dig(peer: int) -> void:
	if phase != SiegePhase.ARMED or not director.is_in_raid(peer):
		return
	var relay := relays.make_reachable_relay(peer)
	if relay == "":
		if relays.make_band(peer) == SiegeRelays.Band.SENSE:
			node.tell(peer, CybridRules.text("trigger", "sense_use"), 3.0)
		return
	apply_relay(peer, relay)


## Relay `relay_id` is woken by `peer` (no reach test: apply_dig did it).
func apply_relay(peer: int, relay_id: String) -> void:
	match chain.apply_activate(relay_id):
		SiegeChain.Result.STEP:
			node.tell(peer, CybridRules.text("trigger", "step"), 3.0)
		SiegeChain.Result.RESET:
			node.tell(peer, CybridRules.text("trigger", "reset"), 3.0)
		SiegeChain.Result.DONE:
			apply_warning()


## The fragment items among `stacks` that `peer` took tell their lines.
func apply_stacks_taken(peer: int, stacks: Array) -> void:
	for st in stacks:
		var rank := SiegeFragments.make_rank_of_item(str(st[0]))
		if rank >= 0 and rank < fragments.hints.size():
			node.tell_hint(peer, rank, CybridRules.section("fragments").get("taken_text", "%s") % fragments.hints[rank])


# ------------------------------------------------------------------ warning and siege

## The chain is complete: the broadcast, the truce and the countdown.
func apply_warning() -> void:
	_set_phase(SiegePhase.WARNING)
	_apply_truce()
	var warning := CybridRules.section("warning")
	for line in warning.get("lines", []):
		announcer.apply_say(MissionMessage.make_message(str(line), 6.0))
	timeline.apply_warning(float(warning.get("countdown_s", 90.0)))


func _apply_truce() -> void:
	var teams := director.faction_teams.duplicate()
	for peer in battle.config.get("roster", {}):
		teams[director.make_player_team(int(peer))] = ""
	teams[cybrid_team] = str(CybridRules.data().get("cybrid_faction", "cybrid"))
	SiegeRelations.apply_truce(teams)
	node.send_truce()


## The Cybrids arrive: the waves start, the safe area begins to shrink, the exfils get their closing times.
func apply_siege_start() -> void:
	if phase != SiegePhase.WARNING:
		return
	_set_phase(SiegePhase.SIEGE)
	last_zone = _find_last_zone()
	var zones := director.map.zones
	timeline.apply_siege_start(zones, last_zone)
	zone = SiegeZone.make(director.map.make_center(), Vector2(zones[last_zone].x, zones[last_zone].z))
	enforcer = SiegeEnforcer.new(battle, zone, cybrid_team)
	enforcer.warned.connect(func(h: Herc) -> void:
		node.tell(director.peer_of_unit(h), str(CybridRules.section("safe_area").get("warn_text", "")), 3.0))
	director.transports.delay_factor = float(CybridRules.section("exfil").get("delay_factor", 0.5))
	if director.site_spawner != null:
		director.site_spawner.refill_factor = float(CybridRules.section("waves").get("garrison_refill_factor", 3.0))
		director.site_spawner.movement_paused = true
	waves.apply_trigger(SiegeWaves.TRIGGER_START)
	announcer.apply_say(MissionMessage.make_message(str(CybridRules.section("warning").get("arrival_line", "")), 6.0))


## The exfil that stays open longest: the map's last_exfil label, else the zone nearest the map's centre.
func _find_last_zone() -> int:
	var label := str(CybridRules.map_data(director.built).get("last_exfil", ""))
	var exfils: Array = (director.built.map as Dictionary).get("exfil", [])
	for i in exfils.size():
		if str(exfils[i].label) == label:
			return i
	var c := director.map.make_center()
	var best := 0
	for i in director.map.zones.size():
		if Vector2(director.map.zones[i].x, director.map.zones[i].z).distance_to(c) < Vector2(director.map.zones[best].x, director.map.zones[best].z).distance_to(c):
			best = i
	return best


func _spawn_wave(_group: String, n: int) -> void:
	wave_number = n
	spawner.spawn_wave(n)


func _on_announced(seconds_left: int) -> void:
	announcer.apply_say(MissionMessage.make_message(str(CybridRules.section("warning").get("countdown_line", "%d")) % seconds_left, 4.0))


func _on_exfil_closing(zone_index: int, _is_last: bool) -> void:
	director.transports.apply_close(zone_index)
	announcer.apply_say(MissionMessage.make_message(str(CybridRules.section("exfil").get("close_line", "%s")) % ExtractionTransports.make_zone_name(zone_index), 4.0))


func _on_last_exfil_open(zone_index: int, seconds_left: float) -> void:
	announcer.apply_say(MissionMessage.make_message(str(CybridRules.section("exfil").get("last_line", "%s %d")) % [ExtractionTransports.make_zone_name(zone_index), int(seconds_left)], 5.0))


func _on_final_stand() -> void:
	var final := CybridRules.section("final")
	announcer.apply_say(MissionMessage.make_message(str(final.get("line", "")), 6.0))
	ender.apply_verdict(MissionVerdict.make_loss(int(final.get("code", 7)), str(final.get("line", "")), float(final.get("delay_s", 6.0))))


## The ender's end call: nothing in the basin but the Cybrids survives.
func _annihilate(_success: bool, _code: int, _text: String) -> void:
	_set_phase(SiegePhase.ENDED)
	for h in battle.vehicles.values().duplicate():
		if enforcer.is_subject(h):
			(h as Herc).apply_environment_damage(1.0, KillText.CAUSE_BOUNDS)


func _set_phase(p: int) -> void:
	phase = p
	phase_changed.emit(p)


## The bonus a siege extraction pays on a haul worth `value` (0 outside the siege).
func make_extraction_bonus(value: int) -> int:
	if phase != SiegePhase.SIEGE:
		return 0
	var bonus := CybridRules.section("exfil").get("bonus", {}) as Dictionary
	return int(bonus.get("flat", 0)) + roundi(float(value) * float(bonus.get("fraction", 0.0)))


## The state every peer shows (the HUD and the wall).
func make_state() -> Dictionary:
	var s := {"phase": phase, "wave": wave_number, "units": spawner.count_alive() if spawner != null else 0}
	if phase == SiegePhase.WARNING:
		s["t"] = timeline.make_warning_left()
	elif phase == SiegePhase.SIEGE:
		var c := zone.make_centre(timeline.siege_s)
		s.merge({"cx": c.x, "cz": c.y, "r": zone.make_radius(timeline.siege_s), "final_left": timeline.make_final_left(),
			"next_close": -1.0, "last_zone": -1, "last_left": 0.0})
		var next := timeline.make_next_closing()
		if not next.is_empty():
			s["next_close" if not bool(next.last) else "last_left"] = float(next.at_s) - timeline.siege_s
			s["last_zone"] = last_zone if bool(next.last) else -1
	return s
