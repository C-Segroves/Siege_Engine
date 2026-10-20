class_name MissionKit
extends RefCounted
## The mission blocks of one running mission, composed (docs/MECHANICS_UNIFICATION.md section 2): clock, timers,
## triggers, objectives, fail rules, waves, announcer, ender, script and vars. MissionRuntimeBase owns one as `kit`;
## a game's adapter fills in the blocks it uses and leaves the others null or empty.
##
## apply_tick runs the blocks in one fixed order: timers, triggers, script, waves, objectives, fail rules, announcer,
## ender. `delta` is the physics step (timers); `dt` is the rules step (everything else; 0 skips the rules blocks).

var clock := MissionClock.new()
var timers := MissionTimers.new()
var triggers: Array[AreaTrigger] = []
## Returns the Dictionary AreaTrigger.apply_scan takes ({id: position}); unset = triggers are scanned by the game.
var trigger_candidates := Callable()
var objectives := ObjectiveSet.new()
var fail_rules: Array = []
var waves: WaveDirector = null
var announcer: MissionAnnouncer = null
var ender: MissionEnder = null
var mission_script: MissionScript = null
var vars: MissionVars = null


## Runs one step. Returns the payloads of the timers that ran out, in order, for the game to act on.
func apply_tick(world: MissionWorld, delta: float, dt: float) -> Array:
	var fired := timers.apply_tick(delta)
	if dt <= 0.0:
		return fired
	if trigger_candidates.is_valid():
		for t in triggers:
			t.apply_scan(trigger_candidates.call())
	if mission_script != null:
		mission_script.step(dt)
	if waves != null:
		waves.apply_tick(dt)
	if world != null:
		objectives.apply_tick(world, dt)
	if ender != null and world != null:
		ender.apply_verdict(FailRule.make_first_verdict(fail_rules, world, dt))
	if announcer != null:
		announcer.apply_tick(dt)
	if ender != null:
		ender.apply_tick(dt)
	return fired
