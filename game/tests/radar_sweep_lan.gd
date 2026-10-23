extends Node
## Three-process LAN check of the team-shared radar sweep (call-in "radar_sweep", engine/extraction/callin/callin_sweep.gd):
## the host (team 0) calls a sweep with a faction soldier nearby, a teammate (team 0) sees the swept contact on its machine,
## an enemy player (team 1) gets nothing: no contacts, no swept mark. One command; the host role starts both clients as
## child processes.
##   godot --headless --audio-driver Dummy --path game res://tests/radar_sweep_lan.tscn
## Prints "radar_sweep_lan[ <role>]: OK|FAILED: <why>"; exit code 0 / 1.

const PORT := 47770
const MAP := "tribes2:Katabatic"
const SEED := 4242
const BATTLE_SCENE := "res://games/es1/battle.tscn"
const CONNECT_SECONDS := 30.0
const UNSTOW_SECONDS := 150.0
const FACTION_TEAM := 399
const LANDED_METRES := 3.0
const HOSTILE_OFFSET := Vector3(60.0, 0.0, 0.0)
const SWEEP_SECONDS := 12.0
const SWEEP_DELAY_SECONDS := 4.0
const SEE_SECONDS := 30.0
const WATCH_SECONDS := 30.0
const CHILD_SECONDS := 90.0
const SETTLE_SECONDS := 3.0
const TEAM_HOST := 0
const TEAM_OTHER := 1
const RAID_POINTS := 1000
const ROLE_HOST := "host"
const ROLE_MATE := "mate"
const ROLE_ENEMY := "enemy"

var _role := ROLE_HOST
var _battle: Battle


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.substr(7)
	Net.player_name = _role.capitalize()
	Net.game_starting.connect(_on_game_starting)
	match _role:
		ROLE_HOST:
			_run_host.call_deferred()
		ROLE_MATE:
			_run_mate.call_deferred()
		_:
			_run_enemy.call_deferred()


func _on_game_starting(config: Dictionary) -> void:
	_battle = load(BATTLE_SCENE).instantiate()
	_battle.config = config
	get_tree().root.add_child(_battle)


func _finish(ok: bool, why := "") -> void:
	print("radar_sweep_lan%s: %s" % ["" if _role == ROLE_HOST else " " + _role, "OK" if ok else "FAILED: " + why])
	get_tree().quit(0 if ok else 1)


func _wait_for(cond: Callable, seconds: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()


func _is_up(soldier: Infantry) -> bool:
	return soldier != null and is_instance_valid(soldier) and soldier.alive and not soldier.stowed


## True once this process's own soldier is out of the dropship.
func _wait_unstowed() -> bool:
	if not await _wait_for(func() -> bool: return _battle != null and _battle.extraction != null and _battle.player != null, CONNECT_SECONDS * 2.0):
		return false
	await get_tree().create_timer(SETTLE_SECONDS).timeout   # the drop-in stows the soldiers a moment after the spawn
	return await _wait_for(func() -> bool: return _is_up(_battle.player as Infantry), UNSTOW_SECONDS)


## The swept contacts of this machine that are faction soldiers (not me, not a player).
func _hostile_contacts() -> Array:
	var c := _battle.extraction.callins
	return c.sweep_contacts.filter(func(k: Dictionary) -> bool:
		var unit = _battle.vehicles.get(int(k.id))
		return unit != null and unit is Infantry and (unit as Infantry).team == FACTION_TEAM)


# ------------------------------------------------------------------ host

func _run_host() -> void:
	if Net.host(PORT) != OK:
		_finish(false, "cannot host on port %d" % PORT)
		return
	var pids := []
	for role in [ROLE_MATE, ROLE_ENEMY]:
		pids.append(OS.create_process(OS.get_executable_path(), ["--headless", "--audio-driver", "Dummy", "--log-file", _log_path(role), "--path",
			ProjectSettings.globalize_path("res://"), "res://tests/radar_sweep_lan.tscn", "--", "--role=" + role]))
	if not await _wait_for(func() -> bool: return Net.roster.size() >= 3, CONNECT_SECONDS):
		_kill(pids)
		_finish(false, "the clients never joined (%d in the roster)" % Net.roster.size())
		return
	var peers := _assign_teams()
	Net.start_game(_make_config())
	var verdict := await _run_sweep(peers)
	var clients_ok := await _wait_for(func() -> bool: return pids.all(func(pid: int) -> bool: return not OS.is_process_running(pid)), CHILD_SECONDS)
	clients_ok = clients_ok and pids.all(func(pid: int) -> bool: return OS.get_process_exit_code(pid) == 0)
	_kill(pids)
	if verdict == "" and not clients_ok:
		verdict = "a client failed: " + _client_report()
	_finish(verdict == "", verdict)


static func _kill(pids: Array) -> void:
	for pid in pids:
		if OS.is_process_running(pid):
			OS.kill(pid)


## {role: peer id}; the host and the mate are on team 0, the enemy on team 1.
func _assign_teams() -> Dictionary:
	var peers := {}
	for id in Net.roster:
		var role := str(Net.roster[id].name).to_lower()
		peers[role] = int(id)
		Net.assign_team(int(id), TEAM_OTHER if role == ROLE_ENEMY else TEAM_HOST)
	return peers


func _make_config() -> Dictionary:
	MatchFlow.apply_extraction_roster(true)
	var cfg := MatchFlow.make_extraction_config({"world_idx": 0, "teams": true, "ai": 0, InfantryBots.CONFIG_KEY: 0})
	cfg.merge({"map": MAP, "respawn": true, ExtractionRules.FAST_CONFIG_KEY: true, "extraction_seed": SEED}, true)
	return cfg


## "" when the sweep reached the teammate and nobody else.
func _run_sweep(peers: Dictionary) -> String:
	if not await _wait_unstowed():
		return "the host's soldier never left the dropship"
	var mate := int(peers.get(ROLE_MATE, 0))
	var enemy := int(peers.get(ROLE_ENEMY, 0))
	var up := func() -> bool:
		return _is_up(_battle.occupancy.soldier_of(mate)) and _is_up(_battle.occupancy.soldier_of(enemy))
	await get_tree().create_timer(SETTLE_SECONDS).timeout
	if not await _wait_for(up, UNSTOW_SECONDS):
		return "the clients' soldiers never left the dropship"
	await get_tree().create_timer(SWEEP_DELAY_SECONDS).timeout
	var c := _battle.extraction.callins
	ExtractionRules.data().callins.kinds.radar_sweep.duration_s = SWEEP_SECONDS
	c.points.balances[1] = RAID_POINTS
	var me := _battle.player as Infantry
	# Out of the dropship is not yet on the ground (it opens high up): the sweep reaches 300 m from the caller, so he must have landed
	# before the hostile is put on the ground 60 m away
	var landed := func() -> bool: return me.global_position.y - _battle.infantry.make_on_ground(me.global_position + HOSTILE_OFFSET).y < LANDED_METRES
	if not await _wait_for(landed, UNSTOW_SECONDS):
		return "the host's soldier never landed (at %s)" % me.global_position
	_spawn_hostile(me.global_position + HOSTILE_OFFSET)
	var told := {}
	c.tap = func(peer: int, method: String, args: Array) -> void:
		if method == "_sweep" and not (args[0] as Array).is_empty():
			told[peer] = true
	var order := c.apply_request(1, "radar_sweep", "")
	if order == null:
		return "the host's sweep was refused: %s (alive %s, stowed %s, at %s)" % [c.make_refusal(1, "radar_sweep", ""), me.alive, me.stowed, me.global_position]
	await _wait_for(func() -> bool: return not order.is_open(), SWEEP_SECONDS * 3.0)
	c.tap = Callable()
	print("radar_sweep_lan: contacts told to peers %s (mate %d, enemy %d)" % [told.keys(), mate, enemy])
	if not told.has(1) or not told.has(mate):
		return "the host did not tell the caller and the teammate"
	if told.has(enemy):
		return "the host told the enemy player the contacts"
	return ""


func _spawn_hostile(at: Vector3) -> void:
	var xf := Transform3D(Basis(), _battle.infantry.make_on_ground(at))
	var spec := _battle.infantry.make_soldier_spec(_battle.infantry.bots.allocate_bot_id(), FACTION_TEAM, "QA Hostile", xf)
	spec["bot"] = true
	spec["protection"] = 0.0
	_battle.send_spawn(spec)
	_battle.extraction.watch(_battle.vehicles.get(int(spec.net_id)))


# ------------------------------------------------------------------ the teammate

func _run_mate() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_unstowed():
		_finish(false, "no raid with this soldier up")
		return
	var c := _battle.extraction.callins
	var seen := await _wait_for(func() -> bool: return c.sweep_left > 0.0 and not _hostile_contacts().is_empty(), UNSTOW_SECONDS + SEE_SECONDS)
	if not seen:
		_finish(false, "the teammate never saw the swept faction soldier")
		return
	var unit := _battle.vehicles.get(int(_hostile_contacts()[0].id)) as Infantry
	var marked := await _wait_for(func() -> bool: return ContactTable.is_swept(unit), 3.0)
	_finish(marked, "the contact reached the teammate but is not marked on its radar")


# ------------------------------------------------------------------ the enemy

func _run_enemy() -> void:
	if Net.join("127.0.0.1", PORT) != OK:
		_finish(false, "cannot join")
		return
	if not await _wait_unstowed():
		_finish(false, "no raid with this soldier up")
		return
	var c := _battle.extraction.callins
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < WATCH_SECONDS * 1000.0:
		if not c.sweep_contacts.is_empty() or c.sweep_left > 0.0:
			_finish(false, "the enemy got %d sweep contacts" % c.sweep_contacts.size())
			return
		if _battle.vehicles.values().any(func(u: Node) -> bool: return is_instance_valid(u) and ContactTable.is_swept(u)):
			_finish(false, "the enemy has a unit marked swept on its radar")
			return
		await get_tree().physics_frame
	_finish(true)


# ------------------------------------------------------------------ the clients' logs

static func _log_path(role: String) -> String:
	return OS.get_cache_dir().path_join("radar_sweep_lan_%s.log" % role)


## What each client said (its verdict line and any script error), from the logs the host had them write.
static func _client_report() -> String:
	var out := []
	for role in [ROLE_MATE, ROLE_ENEMY]:
		for line in FileAccess.get_file_as_string(_log_path(role)).split("\n"):
			if line.begins_with("radar_sweep_lan") or line.contains("ERROR"):
				out.append(line.strip_edges())
	return " | ".join(out)
