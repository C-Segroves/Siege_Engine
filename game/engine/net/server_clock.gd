class_name ServerClock
extends Node
## The fixed simulation tick of a networked battle (docs/DEDICATED_SERVER_SCALING.md section 2.4). It counts
## `tick` at `tick_hz` of simulated time, so the network (snapshot cadence, snapshot timestamps) follows the tick
## number and never the wall clock or the render FPS. It is fed by the physics step (a fixed delta); when the
## process falls behind, at most `max_catchup_steps` ticks run per advance and the rest are dropped (and counted),
## so a stall cannot snowball into a spiral of death.
## A pilot-hosted (LAN) battle ticks at LAN_HZ, one tick per physics step as before; a dedicated server ticks at
## its configured rate (DedicatedServer sets `dedicated_hz`).

signal ticked(tick: int)

const DEFAULT_HZ := 30
const LAN_HZ := 60
const DEFAULT_MAX_CATCHUP_STEPS := 2
const MILLISECONDS := 1000.0
## The headless server renders at most this many frames per tick (the spare ones absorb timing jitter).
const FRAME_CAP_FACTOR := 2
## Float slack so 60 physics steps of 1/60 s always make exactly 60 ticks.
const STEP_TOLERANCE := 1e-6

## The tick rate a dedicated server runs its battles at; DedicatedServer sets it from its config.
static var dedicated_hz := DEFAULT_HZ
static var dedicated_max_catchup_steps := DEFAULT_MAX_CATCHUP_STEPS
## The server config left tick_hz at 0: each battle runs at its game's NetProfile tick rate.
static var follows_profile := false

var tick_hz: int
var max_catchup_steps: int
## Ticks run so far.
var tick := 0
## Ticks skipped because a stall exceeded the catch-up cap.
var dropped_ticks := 0
## Most ticks one advance had to run (1 in steady state).
var catchup_steps_max := 0
var _carry := 0.0


func _init(p_tick_hz := DEFAULT_HZ, p_max_catchup_steps := DEFAULT_MAX_CATCHUP_STEPS) -> void:
	tick_hz = maxi(p_tick_hz, 1)
	max_catchup_steps = maxi(p_max_catchup_steps, 1)
	name = "ServerClock"


## The clock of a battle in this session: the dedicated server's rate (the game's profile rate `profile_hz` when the
## server config follows it), else LAN_HZ.
static func make_for_session(profile_hz := 0) -> ServerClock:
	if Net.dedicated:
		if follows_profile and profile_hz > 0 and profile_hz != dedicated_hz:
			configure_dedicated(profile_hz, dedicated_max_catchup_steps)
		return ServerClock.new(dedicated_hz, dedicated_max_catchup_steps)
	return ServerClock.new(LAN_HZ, dedicated_max_catchup_steps)


## Dedicated server: makes `hz` the tick rate of its battles and of the engine's physics step, caps the engine's
## catch-up steps per frame and the frame rate (so the headless process sleeps instead of spinning).
static func configure_dedicated(hz: int, max_catchup_steps: int) -> void:
	dedicated_hz = maxi(hz, 1)
	dedicated_max_catchup_steps = maxi(max_catchup_steps, 1)
	Engine.physics_ticks_per_second = dedicated_hz
	Engine.max_physics_steps_per_frame = dedicated_max_catchup_steps
	Engine.max_fps = dedicated_hz * FRAME_CAP_FACTOR


## Every how many ticks a stream of `stream_hz` sends (at least 1; the nearest whole number of ticks).
static func make_interval(p_tick_hz: int, stream_hz: float) -> int:
	return maxi(roundi(float(p_tick_hz) / maxf(stream_hz, 0.001)), 1)


func make_step_seconds() -> float:
	return 1.0 / float(tick_hz)


## Simulated milliseconds at tick `n`.
func make_time_ms(n: int) -> int:
	return roundi(float(n) * MILLISECONDS / float(tick_hz))


func _physics_process(delta: float) -> void:
	advance(delta)


## Adds `delta` seconds of simulated time and runs the ticks that fell due (at most max_catchup_steps; the excess is
## dropped). Returns the number of ticks run.
func advance(delta: float) -> int:
	_carry += delta
	var step := make_step_seconds()
	var due := floori((_carry + STEP_TOLERANCE) / step)
	var run := mini(due, max_catchup_steps)
	dropped_ticks += due - run
	_carry = maxf(_carry - float(due) * step, 0.0)
	catchup_steps_max = maxi(catchup_steps_max, run)
	for i in run:
		tick += 1
		ticked.emit(tick)
	return run
