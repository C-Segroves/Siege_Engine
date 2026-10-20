extends Node
## The bot LOD director (engine/bot_sleep.gd, docs/DEDICATED_SERVER_SCALING.md 4.2) in a real battle with one human:
##   * tiers from the flat distance to the human, read from battle.entities: NEAR / MID / FAR / ASLEEP, with the
##     hysteresis (NEAR keeps its tier a margin further out; an awake unit sleeps only past sight + margin, a
##     sleeping one wakes at sight, so nobody flaps at the edge);
##   * a unit on a human's radar is never ASLEEP (FAR for a soldier), an unseen one beyond sight sleeps;
##   * pinned units (objective, keep_awake) never sleep; dormant units keep their tier; without a human all are NEAR;
##   * the scope (wake_area) and damage wake a sleeper and hold it awake for a while;
##   * a FAR soldier walks straight toward its goal each step, on the ground, no faster than its FAR speed.
##   godot --headless --audio-driver Dummy --path game res://tests/bot_lod_check.tscn
## Prints "bot_lod_check: OK" or "FAILED"; exit code 0 / 1.

const MAP := "tribes:Raindance"
const SETTLE_FRAMES := 20
const SIGHT_M := 800.0
const MARGIN_M := 60.0
const NEAR_M := 150.0
const NEAR_MARGIN_M := 25.0
const FIRST_BOT_PEER := 90
## Bots stand on a line from the human along +x.
const NEAR_AT := 100.0
const NEAR_STAY_AT := 160.0     # past near_m, inside near_m + near_margin: a NEAR unit keeps NEAR
const MID_AT := 400.0
const EDGE_AT := 830.0          # between sight and sight + margin
const BEYOND_AT := 1000.0
const WARM_UP_S := 2.0       # before FAR-vs-NEAR distances are compared: the NEAR soldier's ramp up to speed

var _failures := 0
var _battle: Battle
var _sleep: BotSleep
var _human: Infantry
var _next_peer := FIRST_BOT_PEER


func _ready() -> void:
	await get_tree().process_frame
	await _start_battle()
	_check_setup()
	_check_tiers_by_distance()
	_check_hysteresis()
	_check_radar()
	_check_pinned_and_dormant()
	await _check_far_walk()
	await _check_far_matches_near()
	await _check_mid_matches_near()
	_check_wake_by_scope()
	_check_wake_by_damage()
	_check_no_human()
	print("bot_lod_check: %s (%d failures)" % ["OK" if _failures == 0 else "FAILED", _failures])
	get_tree().quit(1 if _failures > 0 else 0)


func _expect(ok: bool, what: String) -> void:
	print("  %s %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failures += 1


func _frames(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _start_battle() -> void:
	var config := BattleSetup.make_default_config("es1:RAPTOR")
	config.merge({"mode": "vs", "respawn": true, "teams": true, "map": MAP, "start": BattleInfantry.START_ON_FOOT,
		"frag_limit": 50, "ai": []}, true)
	_battle = load("res://games/es1/battle.tscn").instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)
	get_tree().current_scene = _battle
	await _frames(SETTLE_FRAMES)
	_sleep = _battle.bot_sleep
	_human = _battle.player as Infantry


## The director's rules as the check expects them; its own timer is off (the check calls apply_tick), the map's fog
## does not shorten the sight range.
func _check_setup() -> void:
	print("setup:")
	_expect(_sleep != null and BotSleep.is_enabled(), "the battle has an enabled BotSleep")
	_sleep.set_physics_process(false)
	var rules := ExtractionRules.data()["bot_sleep"] as Dictionary
	rules["range_m"] = SIGHT_M
	rules["margin_m"] = MARGIN_M
	rules["near_m"] = NEAR_M
	rules["near_margin_m"] = NEAR_MARGIN_M
	_sleep._fog_searched = true
	_sleep._fog_end = INF
	_expect(is_equal_approx(_sleep.make_sight_range(), SIGHT_M), "sight range is the rule's range_m (%.0f m)" % _sleep.make_sight_range())
	_expect(_human != null and _human.alive, "a living human soldier is the viewer")
	_human.set_physics_process(false)
	_human.global_position = Vector3(0.0, MapBuilder.ground_height(_battle, Vector3.ZERO) + 1.0, 0.0)
	_battle.bounds.set_physics_process(false)   # the bots stand far out; nobody is killed for leaving the area


## A bot soldier `x` metres east of the human, with its brain (like an extraction garrison soldier).
func _spawn_bot(x: float) -> Array:
	var peer := _next_peer
	_next_peer += 1
	var at := _human.global_position + Vector3(x, 0.0, 0.0)
	at.y = MapBuilder.ground_height(_battle, at) + 0.5
	var s := _battle.spawn_soldier_for(peer, _human.team, "Bot %d" % peer, Transform3D(Basis(), at))
	var brain := InfantryBot.make(s, peer, 0.0)
	s.add_child(brain)
	s.set_physics_process(false)   # the body stays where the check puts it
	return [s, brain]


func _place(unit: Node3D, x: float) -> void:
	unit.global_position = Vector3(_human.global_position.x + x, unit.global_position.y, _human.global_position.z)


func _tick() -> void:
	_sleep.apply_tick()


func _tier(bot: Array) -> int:
	return BotSleep.tier_of(bot[0])


func _tier_name(t: int) -> String:
	return BotSleep.Tier.keys()[t]


func _expect_tier(bot: Array, want: int, what: String) -> void:
	_expect(_tier(bot) == want, "%s: %s (is %s)" % [what, _tier_name(want), _tier_name(_tier(bot))])


## The bots are the human's allies, so his radar shows them (RadarMode.can_see) within its range, or anywhere on a
## map with a sensor net; a hidden one is unseen (RadarContacts.apply_hidden).
func _hide(bot: Array, hidden := true) -> void:
	RadarContacts.apply_hidden(bot[0], hidden)


func _free_bots(bots: Array) -> void:
	for b in bots:
		for k in _battle.vehicles.keys():
			if _battle.vehicles[k] == b[0]:
				_battle.vehicles.erase(k)
		b[0].free()


# ------------------------------------------------------------------ tiers

func _check_tiers_by_distance() -> void:
	print("tiers by flat distance:")
	var near := _spawn_bot(NEAR_AT)
	var mid := _spawn_bot(MID_AT)
	var far_hidden := _spawn_bot(BEYOND_AT)
	_hide(far_hidden)
	_tick()
	_expect_tier(near, BotSleep.Tier.NEAR, "a bot %.0f m away" % NEAR_AT)
	_expect_tier(mid, BotSleep.Tier.MID, "a bot %.0f m away" % MID_AT)
	_expect_tier(far_hidden, BotSleep.Tier.ASLEEP, "an unseen bot %.0f m away (beyond sight)" % BEYOND_AT)
	var nb: InfantryBot = near[1]
	var mb: InfantryBot = mid[1]
	_expect(nb.ai_lod == 0 and not (near[0] as Infantry).far_lod and near[0].visible, "NEAR: full logic, visible")
	_expect(mb.ai_lod == 1 and (mid[0] as Infantry).far_lod and mid[0].visible, "MID: simplified logic (ai_lod 1, far_lod on), visible")
	var asleep: Node = far_hidden[0]
	_expect(BotSleep.is_asleep(asleep) and not asleep.visible and not asleep.is_physics_processing() \
			and not (far_hidden[1] as Node).is_physics_processing(), "ASLEEP: hidden, unit and brain stop processing")
	_expect(int(_sleep.tier_counts[BotSleep.Tier.ASLEEP]) >= 1 and _sleep.sleeping_count >= 1, "the director counts its sleepers (%s)" % [_sleep.tier_counts])
	# the distance is the flat one: height does not count
	var tall := _spawn_bot(MID_AT)
	tall[0].global_position.y += 900.0
	_tick()
	_expect_tier(tall, BotSleep.Tier.MID, "a bot %.0f m away and 900 m up (flat distance)" % MID_AT)
	_free_bots([near, mid, far_hidden, tall])


func _check_hysteresis() -> void:
	print("hysteresis:")
	var bot := _spawn_bot(NEAR_AT)
	_hide(bot)
	_tick()
	_expect_tier(bot, BotSleep.Tier.NEAR, "starts NEAR at %.0f m" % NEAR_AT)
	_place(bot[0], NEAR_STAY_AT)
	_tick()
	_expect_tier(bot, BotSleep.Tier.NEAR, "a NEAR bot keeps NEAR at %.0f m (near_m %.0f + margin %.0f)" % [NEAR_STAY_AT, NEAR_M, NEAR_MARGIN_M])
	_place(bot[0], NEAR_M + NEAR_MARGIN_M + 10.0)
	_tick()
	_expect_tier(bot, BotSleep.Tier.MID, "past the margin it drops to MID")
	_place(bot[0], NEAR_STAY_AT)
	_tick()
	_expect_tier(bot, BotSleep.Tier.MID, "a MID bot does not return to NEAR at %.0f m (needs <= %.0f)" % [NEAR_STAY_AT, NEAR_M])
	_place(bot[0], EDGE_AT)
	_tick()
	_expect_tier(bot, BotSleep.Tier.MID, "an awake bot between sight and sight + margin (%.0f m) stays MID" % EDGE_AT)
	_place(bot[0], SIGHT_M + MARGIN_M + 20.0)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "past sight + margin an unseen bot falls asleep")
	_place(bot[0], EDGE_AT)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "a sleeper between sight and sight + margin stays asleep (no flapping at %.0f m)" % EDGE_AT)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "...and on the next tick too")
	_place(bot[0], SIGHT_M - 20.0)
	_tick()
	_expect_tier(bot, BotSleep.Tier.MID, "inside sight it wakes to MID")
	_expect(bot[0].visible and bot[0].is_physics_processing() and (bot[1] as Node).is_physics_processing(), "...visible and processing again")
	_free_bots([bot])


# ------------------------------------------------------------------ radar, pins

func _check_radar() -> void:
	print("radar:")
	var seen := _spawn_bot(BEYOND_AT)
	var unseen := _spawn_bot(BEYOND_AT)
	_hide(unseen)
	_tick()
	_expect(RadarContacts.is_on_scope(_human, seen[0]) and not RadarContacts.is_on_scope(_human, unseen[0]),
		"the scope shows the first bot and not the hidden one")
	_expect_tier(seen, BotSleep.Tier.FAR, "a soldier on the radar beyond sight (never asleep)")
	_expect(not BotSleep.is_asleep(seen[0]) and not seen[0].is_physics_processing() and not seen[0].visible,
		"FAR: no physics, no drawing, not marked asleep")
	_expect_tier(unseen, BotSleep.Tier.ASLEEP, "the same bot off the radar")
	_hide(unseen, false)
	_tick()
	_expect_tier(unseen, BotSleep.Tier.FAR, "it moves to FAR the tick it shows on the radar")
	_hide(unseen)
	_tick()
	_expect_tier(unseen, BotSleep.Tier.ASLEEP, "...and sleeps again when it leaves the radar")
	var base := TribesBase.of(_battle)
	if base == null or base.sensor_net == null:   # a sensor net reports contacts at any range: only then the range is moot
		RadarContacts.apply_range(_human, BEYOND_AT / 2.0)
		_tick()
		_expect_tier(seen, BotSleep.Tier.ASLEEP, "beyond the radar's range (%.0f m) the visible bot sleeps" % (BEYOND_AT / 2.0))
		RadarContacts.apply_range(_human, BEYOND_AT * 1.5)
		_tick()
		_expect_tier(seen, BotSleep.Tier.FAR, "inside the radar's range it is FAR again")
		_human.remove_meta(RadarContacts.RANGE_META)
	_free_bots([seen, unseen])


func _check_pinned_and_dormant() -> void:
	print("pinned and dormant:")
	var objective := _spawn_bot(BEYOND_AT)
	_hide(objective)
	(objective[1] as InfantryBot).objective = {"point": objective[0].global_position, "urgent": false}
	var keep := _spawn_bot(BEYOND_AT)
	_hide(keep)
	keep[0].set_meta(BotSleep.META_KEEP_AWAKE, true)
	var dormant := _spawn_bot(NEAR_AT)
	_tick()
	dormant[0].set_meta("dormant", true)
	_hide(dormant)
	_place(dormant[0], BEYOND_AT)
	_tick()
	_expect_tier(objective, BotSleep.Tier.FAR, "a bot with an objective is never asleep, unseen or not")
	_expect_tier(keep, BotSleep.Tier.FAR, "a bot with meta keep_awake is never asleep")
	_expect_tier(dormant, BotSleep.Tier.NEAR, "a dormant bot keeps the tier it had")
	_free_bots([objective, keep, dormant])


# ------------------------------------------------------------------ FAR walk

func _check_far_walk() -> void:
	print("FAR soldier straight-line steps:")
	var bot := _spawn_bot(BEYOND_AT)
	var soldier: Infantry = bot[0]
	var brain: InfantryBot = bot[1]
	_tick()
	_expect_tier(bot, BotSleep.Tier.FAR, "the bot is FAR")
	var goal := soldier.global_position + Vector3(-300.0, 0.0, 120.0)
	brain.goal = goal
	brain._think = 1000.0     # no re-plan during the steps: the goal stays what the check set
	var step_dt := 1.0
	var start := soldier.global_position
	brain.apply_far_step(step_dt)
	var after := soldier.global_position
	var flat_moved := Vector2(after.x - start.x, after.z - start.z).length()
	var max_step := soldier.max_speed * InfantryBot.FAR_SPEED_SHARE * step_dt
	_expect(flat_moved > 0.5 and flat_moved <= max_step + 0.01, "one step moves %.1f m (at most %.1f m = max speed x FAR share)" % [flat_moved, max_step])
	var toward := Vector2(goal.x - start.x, goal.z - start.z).normalized().dot(Vector2(after.x - start.x, after.z - start.z).normalized())
	_expect(toward > 0.99, "the step points at the goal (cosine %.3f)" % toward)
	_expect(is_equal_approx(after.y, MapTerrain.ground_height(soldier, after)), "the soldier stands on the terrain after the step")
	var d0 := Vector2(goal.x - start.x, goal.z - start.z).length()
	for i in 5:
		brain.apply_far_step(step_dt)
	var d1 := Vector2(goal.x - soldier.global_position.x, goal.z - soldier.global_position.z).length()
	_expect(d1 < d0 - 3.0 * max_step, "five more steps close in on the goal (%.0f m -> %.0f m)" % [d0, d1])
	# the director drives it: a tick steps by the real time since the last one
	var before_tick := soldier.global_position
	await get_tree().create_timer(0.3).timeout
	_tick()
	_expect(soldier.global_position != before_tick, "the director's tick steps a FAR soldier")
	_free_bots([bot])


## LOD changes the cost, not the outcome: over the same game time a FAR soldier covers the distance a NEAR one does.
func _check_far_matches_near() -> void:
	print("FAR covers the distance NEAR does:")
	var seconds := 5.0   # open ground: the NEAR bot jets only over obstacles, which the FAR walk does not see
	var near := _spawn_bot(NEAR_AT)
	var far := _spawn_bot(BEYOND_AT)
	_hide(far)
	(far[1] as InfantryBot).objective = {"point": far[0].global_position, "urgent": false}
	var heading := _make_flattest_heading(near[0].global_position)
	for b in [near, far]:
		var s: Infantry = b[0]
		(b[1] as InfantryBot)._think = 1000.0
		(b[1] as InfantryBot).goal = s.global_position + heading * 600.0
	_tick()
	_expect_tier(near, BotSleep.Tier.NEAR, "the first soldier is NEAR")
	_expect_tier(far, BotSleep.Tier.FAR, "the second is FAR")
	var ns: Infantry = near[0]
	ns.set_physics_process(true)
	(near[1] as Node).set_physics_process(true)
	await _run_game_seconds(WARM_UP_S)   # the NEAR soldier accelerates to its running speed; FAR steps at it at once
	var near_from := ns.global_position
	var far_from: Vector3 = far[0].global_position
	await _run_game_seconds(seconds)
	var near_d := Vector2(ns.global_position.x - near_from.x, ns.global_position.z - near_from.z).length()
	var far_d := Vector2(far[0].global_position.x - far_from.x, far[0].global_position.z - far_from.z).length()
	_expect(near_d > 5.0 and absf(far_d - near_d) <= 0.1 * near_d,
		"in %.0f s NEAR covers %.1f m, FAR %.1f m (within 10%%)" % [seconds, near_d, far_d])
	_free_bots([near, far])


## A MID soldier (the cheap body step, InfantryCheapStep) covers the distance a NEAR soldier does on the same ground, stays
## on the floor and switches both ways without a jump.
func _check_mid_matches_near() -> void:
	print("MID (cheap body step) covers the distance NEAR does:")
	var seconds := 5.0
	var held := _spawn_bot(MID_AT)
	var mid := _spawn_bot(MID_AT + 6.0)
	(held[0] as Node).set_meta(BotSleep.META_HOLD_UNTIL, Time.get_ticks_msec() + 600000)   # held NEAR beside the MID one
	var heading := _make_flattest_heading(held[0].global_position)
	for b in [held, mid]:
		var s: Infantry = b[0]
		(b[1] as InfantryBot)._think = 1000.0
		(b[1] as InfantryBot).goal = s.global_position + heading * 600.0
		s.set_physics_process(true)
		(b[1] as Node).set_physics_process(true)
	_tick()
	_expect_tier(held, BotSleep.Tier.NEAR, "the held soldier is NEAR")
	_expect_tier(mid, BotSleep.Tier.MID, "the other is MID")
	await _run_game_seconds(WARM_UP_S)
	var held_from: Vector3 = held[0].global_position
	var mid_from: Vector3 = mid[0].global_position
	await _run_game_seconds(seconds)
	var held_d := Vector2(held[0].global_position.x - held_from.x, held[0].global_position.z - held_from.z).length()
	var mid_d := Vector2(mid[0].global_position.x - mid_from.x, mid[0].global_position.z - mid_from.z).length()
	_expect(held_d > 5.0 and absf(mid_d - held_d) <= 0.1 * held_d,
		"in %.0f s NEAR covers %.1f m, MID %.1f m (within 10%%)" % [seconds, held_d, mid_d])
	var ground := MapBuilder.ground_height(_battle, mid[0].global_position)
	_expect(absf(mid[0].global_position.y - ground) < 1.0, "the MID soldier stands on the ground (%.2f m off)" % (mid[0].global_position.y - ground))
	_expect((mid[0] as Infantry).far_lod and (mid[0] as Infantry).cheap_floor, "he moved by the cheap step and is grounded in it")
	await _check_promotion(mid)
	_free_bots([held, mid])


## Promoted to NEAR the soldier keeps his place (no jump) and stays on the floor.
func _check_promotion(bot: Array) -> void:
	var s: Infantry = bot[0]
	var before := s.global_position
	s.set_meta(BotSleep.META_HOLD_UNTIL, Time.get_ticks_msec() + 600000)
	_tick()
	_expect_tier(bot, BotSleep.Tier.NEAR, "promoted to NEAR")
	await _frames(10)
	var moved := (s.global_position - before).length()
	var ground := MapBuilder.ground_height(_battle, s.global_position)
	_expect(moved < 8.0 and absf(s.global_position.y - ground) < 1.0 and s.is_on_floor(),
		"promotion neither jumps nor drops him (moved %.1f m, %.2f m off the ground, floor %s)" % [moved, s.global_position.y - ground, s.is_on_floor()])


## Runs `seconds` of game time (physics frames), ticking the LOD director twice a second.
func _run_game_seconds(seconds: float) -> void:
	var ticks := int(seconds * Engine.physics_ticks_per_second)
	for i in ticks:
		await get_tree().physics_frame
		if i % 30 == 0:
			_tick()
	_tick()


## The compass heading (of 16) from `at` whose first 120 m are the flattest, so the NEAR bot has no hill to jet over.
func _make_flattest_heading(at: Vector3) -> Vector3:
	var best := Vector3.FORWARD
	var best_range := INF
	for i in 16:
		var dir := Basis(Vector3.UP, TAU * i / 16.0) * Vector3.FORWARD
		var lo := INF
		var hi := -INF
		for m in range(0, 121, 8):
			var h := MapBuilder.ground_height(_battle, at + dir * float(m))
			lo = minf(lo, h)
			hi = maxf(hi, h)
		if hi - lo < best_range:
			best_range = hi - lo
			best = dir
	return best


# ------------------------------------------------------------------ waking

func _check_wake_by_scope() -> void:
	print("wake by the rifle scope (wake_area):")
	var asleep := _spawn_bot(BEYOND_AT)
	var aside := _spawn_bot(BEYOND_AT)
	aside[0].global_position.z += 600.0
	_hide(asleep)
	_hide(aside)
	_tick()
	_expect_tier(asleep, BotSleep.Tier.ASLEEP, "a distant unseen bot sleeps")
	var woke := _sleep.wake_area(asleep[0].global_position, 100.0, 1.0)
	_expect(woke == 1, "wake_area wakes the one bot inside its circle (%d)" % woke)
	_expect_tier(asleep, BotSleep.Tier.NEAR, "it is NEAR now")
	_expect(not BotSleep.is_asleep(asleep[0]) and asleep[0].visible and asleep[0].is_physics_processing(), "...awake, visible, processing")
	_expect_tier(aside, BotSleep.Tier.ASLEEP, "the bot outside the circle sleeps on")
	_tick()
	_expect_tier(asleep, BotSleep.Tier.NEAR, "the director keeps the woken bot NEAR during the hold")
	asleep[0].set_meta(BotSleep.META_HOLD_UNTIL, Time.get_ticks_msec() - 1)
	_tick()
	_expect_tier(asleep, BotSleep.Tier.ASLEEP, "it sleeps again once the hold has ended")
	_free_bots([asleep, aside])


func _check_wake_by_damage() -> void:
	print("wake by damage:")
	var bot := _spawn_bot(BEYOND_AT)
	_hide(bot)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "a distant unseen bot sleeps")
	var soldier: Infantry = bot[0]
	soldier.damaged.emit(soldier, _human)
	_expect(not BotSleep.is_asleep(soldier) and soldier.visible and soldier.is_physics_processing() \
			and (bot[1] as Node).is_physics_processing(), "a hit wakes it at once: awake, visible, processing")
	_expect_tier(bot, BotSleep.Tier.NEAR, "...at NEAR")
	_tick()
	_expect_tier(bot, BotSleep.Tier.NEAR, "the director keeps a bot that was just hit NEAR (it answers the fire)")
	soldier.set_meta(BotSleep.META_DAMAGE_HOLD_UNTIL, Time.get_ticks_msec() - 1)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "it sleeps again after the hold")
	_hide(bot, false)
	_tick()
	_expect_tier(bot, BotSleep.Tier.FAR, "on the radar it walks FAR")
	soldier.damaged.emit(soldier, _human)
	_expect_tier(bot, BotSleep.Tier.NEAR, "a hit takes a FAR soldier to NEAR")
	_free_bots([bot])


func _check_no_human() -> void:
	print("without a living human:")
	var bot := _spawn_bot(BEYOND_AT)
	_hide(bot)
	_tick()
	_expect_tier(bot, BotSleep.Tier.ASLEEP, "the bot sleeps while the human lives")
	_human.alive = false
	_tick()
	_expect_tier(bot, BotSleep.Tier.NEAR, "every bot is NEAR when no human is alive")
	_human.alive = true
	_free_bots([bot])
