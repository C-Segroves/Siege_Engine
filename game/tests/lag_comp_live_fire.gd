extends Node
## Live-fire lag compensation (docs/DEDICATED_SERVER_SCALING.md chunk M, after chunk J): two processes over ENet. The host
## runs a real Battle with the dedicated server's pieces on (packed snapshots, input frames, hit history) and drives one
## unit along a line at 16 m/s. The client has 100 ms of simulated latency each way (BattleNetSync.simulated_one_way_ms),
## aims at the target as its screen shows it and holds the trigger of its laser. Phase 1 the host rewinds the shots
## (BattleNetSync.make_rewind): they hit the unit where the client saw it. Phase 2 the profile's lag compensation is
## off: the same shots test the unit where it is now, 1.6 m or more ahead of the aim, and miss.
##   godot --headless --audio-driver Dummy --path game res://tests/lag_comp_live_fire.tscn
## Prints "lag_comp_live_fire: OK|FAILED: <why>"; exit code 0 / 1.

const PORT := 47773
const CONNECT_SECONDS := 30.0
const SETTLE_SECONDS := 6.0
const PHASE_SECONDS := 12.0
const ONE_WAY_MS := 100
const CLIENT_SECONDS := 60.0
const TARGET_DISTANCE_M := 70.0
const TARGET_SPEED := 16.0   # m/s: 100 ms each way puts the displayed unit about 5 m behind the real one
const TARGET_SPAN_M := 40.0
const AIM_WARMUP_SECONDS := 3.0
const MIN_SHOTS := 10
const MIN_REWOUND_HITS := 6      # the aim is off at the line's turning points, where the unit stands still for a moment
const MAX_PLAIN_HITS := 2        # the shots a unit that is slow at the turn lets through anyway
const BATTLE_SCENE := "res://games/es1/battle.tscn"

var _role := "host"
var _battle: Battle
var _target: Herc
var _shooter: Herc
var _origin := Vector3.ZERO
var _forward := Vector3.FORWARD
var _right := Vector3.RIGHT
var _driving := false
var _drive_t := 0.0
var _hits := 0
var _shots := 0
var _last_cooldown := 0.0
var _aim_seconds := 0.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
	Net.player_name = _role.capitalize()
	Net.game_starting.connect(_on_game_starting)
	if _role == "host":
		BattleNetSync.packed_in_lan = true
		BattleNetSync.prediction_in_lan = true
		BattleNetSync.lag_comp_in_lan = true
		_run_host.call_deferred()
	else:
		BattleNetSync.simulated_one_way_ms = ONE_WAY_MS
		_run_client.call_deferred()


func _on_game_starting(config: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)


func _finish(ok: bool, why := "") -> void:
	print("lag_comp_live_fire%s: %s" % ["" if _role == "host" else " client", "OK" if ok else "FAILED: " + why])
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _find_pilot_of(peer: int) -> Herc:
	for h: Herc in _battle.vehicles.values():
		if h.owner_peer == peer and not h.has_meta("ai"):
			return h
	return null


# ------------------------------------------------------------------ host

func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	var args := ["--headless", "--audio-driver", "Dummy", "--path", ProjectSettings.globalize_path("res://"),
		"res://tests/lag_comp_live_fire.tscn", "--", "--role=client"]
	var pid := OS.create_process(OS.get_executable_path(), args)
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 2, CONNECT_SECONDS):
		OS.kill(pid)
		_finish(false, "the client never joined")
		return
	MatchFlow.apply_free_for_all_teams()
	var config := MatchFlow.make_match_config({"mode": "vs", "teams": false, "ai": 0, "world_idx": 0}, [])
	config["start"] = BattleInfantry.START_IN_VEHICLE   # the pilots fly their Hercs (a laser beam), not walk
	Net.start_game(config)
	await get_tree().create_timer(1.0).timeout
	_target = _find_pilot_of(1)
	_shooter = _find_pilot_of(multiplayer.get_peers()[0])
	if _target == null or _shooter == null or _battle.pilot == null:
		OS.kill(pid)
		_finish(false, "the battle lacks the host's or the client's Herc")
		return
	_battle.pilot.set_physics_process(false)
	_battle.get_node(BattleBounds.NODE_NAME).set_physics_process(false)   # the target runs along the map edge
	_target.damaged.connect(_on_target_damaged)
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	_origin = _shooter.global_position
	_forward = -_shooter.global_basis.orthonormalized().z   # the line runs across the Herc's front, inside its torso limit
	_right = _shooter.global_basis.orthonormalized().x
	_driving = true
	var sync: BattleNetSync = _battle.get_node("NetSync")
	var with_rewind := await _fire_phase(sync, true)
	var without_rewind := await _fire_phase(sync, false)
	_driving = false
	print("lag_comp_live_fire: rewound %s | now %s" % [with_rewind, without_rewind])
	OS.kill(pid)   # the client only aims and fires; the verdict is the host's
	var verdict := _judge(with_rewind, without_rewind)
	_finish(verdict == "", verdict)


## Counts the shooter's hits and puts the target back on its feet, so that it can take them all test long.
func _on_target_damaged(_herc: Herc, attacker: Node) -> void:
	_hits += 1 if attacker == _shooter else 0
	_restore_target.call_deferred()


func _restore_target() -> void:
	_target.respawn(_target.global_transform)
	_target.end_spawn_protection()


## Runs one phase and returns {shots, hits}.
func _fire_phase(sync: BattleNetSync, rewind_on: bool) -> Dictionary:
	sync.profile.lag_comp_enabled = rewind_on
	_hits = 0
	_shots = 0
	await get_tree().create_timer(PHASE_SECONDS).timeout
	return {"shots": _shots, "hits": _hits}


func _judge(with_rewind: Dictionary, without_rewind: Dictionary) -> String:
	if int(with_rewind.shots) < MIN_SHOTS or int(without_rewind.shots) < MIN_SHOTS:
		return "too few shots (%s, %s): the client did not hold its aim" % [with_rewind, without_rewind]
	if int(with_rewind.hits) < MIN_REWOUND_HITS:
		return "rewound shots hit %d of %d" % [with_rewind.hits, with_rewind.shots]
	if int(without_rewind.hits) > MAX_PLAIN_HITS or int(without_rewind.hits) * 3 > int(with_rewind.hits):
		return "%d shots hit without rewind: the test would pass on a server that does not compensate" % without_rewind.hits
	return ""


func _physics_process(delta: float) -> void:
	if _role == "client":
		if _battle != null and is_instance_valid(_battle) and is_instance_valid(_shooter):
			_client_aim()
		return
	if not _driving or not is_instance_valid(_target):
		return
	_drive_t += delta
	var phase := fposmod(_drive_t * TARGET_SPEED, TARGET_SPAN_M * 4.0)
	var offset := phase - TARGET_SPAN_M if phase < TARGET_SPAN_M * 2.0 else TARGET_SPAN_M * 3.0 - phase
	var at := _origin + _forward * TARGET_DISTANCE_M + _right * offset
	at.y = MapBuilder.ground_height(_battle, at)
	_target.global_position = at
	_count_shots()


func _count_shots() -> void:
	var cooldown: float = _shooter.weapons[0].cooldown
	if cooldown > _last_cooldown + 0.001:
		_shots += 1
	_last_cooldown = cooldown


# ------------------------------------------------------------------ client

func _run_client() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_for(func() -> bool: return _battle != null and _battle.player != null, CONNECT_SECONDS + 3.0):
		_finish(false, "no client battle")
		return
	await get_tree().process_frame
	_battle.pilot.set_physics_process(false)   # the test aims and fires, not the keyboard
	_shooter = _battle.player
	await get_tree().create_timer(CLIENT_SECONDS).timeout
	_finish(true)


## The client sees the host's Herc (the puppet) and keeps its laser on it while the sights are on.
func _client_aim() -> void:
	var host_herc: Herc = _battle.vehicles.get(_find_host_herc_id())
	if host_herc == null:
		return
	var capsule := host_herc.make_hit_capsule()
	var aim_at := host_herc.global_position + Vector3.UP * capsule.y * 0.5
	var local := _shooter.global_basis.orthonormalized().inverse() * (aim_at - _shooter.aim_origin()).normalized()
	var yaw := atan2(-local.x, -local.z)
	var in_torso := Basis(Vector3.UP, yaw).inverse() * local
	var pitch := atan2(in_torso.y, -in_torso.z)
	_shooter.torso_target = yaw
	_shooter.pitch_target = pitch
	_aim_seconds += get_physics_process_delta_time()
	_shooter.weapons[0].trigger = _aim_seconds > AIM_WARMUP_SECONDS   # the host's torso follows the tracked aim by then


func _find_host_herc_id() -> int:
	for h: Herc in _battle.vehicles.values():
		if h.owner_peer == 1 and not h.has_meta("ai"):
			return h.net_id
	return 0

