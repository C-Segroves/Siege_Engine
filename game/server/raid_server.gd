class_name RaidServer
extends Node
## The lifecycle of a dedicated extraction server (server.json mode "extraction"; docs/SERVER_DEPLOY.md "Extraction servers"): one
## persistent raid on one map. Pilots and parties join at any time, drop in by transport, extract or die and get their results; the
## world goes on without them. Child of the DedicatedServer, which calls update() every frame.
##
## Lifecycle of the world:
##   IDLE      no battle (nothing is simulated while nobody wants in). The first pilot who is Ready opens the world.
##   OPEN      the map, caches, factions and bots run. A Ready pilot is admitted: his client builds the battle (Net.begin_for),
##             reports it loaded, is sent the world as it is (RaidReplay) and is dropped in with his party on one transport.
##   CLOSING   `raid_reset_minutes` after it opened (0 = never) no new drop-ins are admitted; the world closes when the last
##             raider is out, or `raid_reset_grace_seconds` later (the rest are sent away: their kit is lost, as when they quit).
## The world also closes `raid_empty_seconds` after the last raider left and nobody waits to drop in, so the next pilot finds fresh caches.
## A pilot is Ready when he pressed Ready in the server's lobby or came with a party Go (PartyFlow). Parties: pilots with the same
## roster "party" id share one team (RaidTeams) and are dropped in together on one transport: once the first member has built his battle
## the server waits for every member who is connected and still building, and up to `party_wait_seconds` for those who are not connected yet.

enum Phase { IDLE, OPEN, CLOSING }
enum Stage { LOADING, WAITING, IN }

## A closed world is freed at the end of the frame: the next one starts a moment later (its node would otherwise get another name).
const REOPEN_DELAY_SECONDS := 1.0
const SECONDS_PER_MINUTE := 60.0
const RESET_TEXT := "The world resets. Extract now: no new drop-ins until it has."
const KICK_TEXT := "The world was reset."
## A pilot whose client has not built the battle (or whose party has not come) this long after he was admitted is sent away.
const JOIN_TIMEOUT_SECONDS := 300.0
const TIMEOUT_TEXT := "Joining the raid took too long."

var cfg := {}
var phase := Phase.IDLE
var battle: Battle
var teams := RaidTeams.new()
## peer -> {group, entry (the raid roster entry), stage}
var pilots := {}
## group key -> {loaded: [peer], expected, since}
var _groups := {}
## Pilots just sent away: still in the roster until their connection closes, and not to be admitted again.
var _barred := {}
var _clock := 0.0
var _open_seconds := 0.0
var _empty_seconds := 0.0
var _closing_seconds := 0.0
var _reopen_wait := 0.0


func _init(p_cfg: Dictionary) -> void:
	cfg = p_cfg
	name = "RaidServer"


func _ready() -> void:
	Net.pilot_loaded.connect(apply_loaded)
	Net.player_left.connect(apply_left)


## The battle the DedicatedServer built for the world that just opened.
func attach_battle(p_battle: Battle) -> void:
	battle = p_battle


func update(delta: float) -> void:
	_clock += delta
	_reopen_wait = maxf(_reopen_wait - delta, 0.0)
	match phase:
		Phase.IDLE:
			if _reopen_wait <= 0.0 and not make_waiting_peers().is_empty():
				_open_world()
		Phase.OPEN:
			_update_open(delta)
			apply_admissions()
		Phase.CLOSING:
			_update_closing(delta)
	if phase != Phase.IDLE and is_instance_valid(battle):
		_update_groups(delta)
		_drop_slow_joiners()


## Pilots who are Ready in the lobby and not yet in the raid.
func make_waiting_peers() -> Array:
	var out := []
	for peer in Net.roster:
		if bool(Net.roster[peer].get("ready", false)) and not pilots.has(int(peer)) and not _barred.has(int(peer)):
			out.append(int(peer))
	return out


# ------------------------------------------------------------------ the world

func _open_world() -> void:
	phase = Phase.OPEN
	_open_seconds = 0.0
	_empty_seconds = 0.0
	var config := MatchFlow.make_extraction_config(Net.settings)
	config[ExtractionRules.FAST_CONFIG_KEY] = int(cfg.raid_fast) == 1
	if int(cfg.raid_seed) != 0:
		config["extraction_seed"] = int(cfg.raid_seed)
	config["results_hold_s"] = float(cfg.results_hold_seconds)
	print("SERVER world open: %s" % str(Net.settings.get("map", "")))
	Net.start_persistent_world(config)


## Closes the world (`why` is logged). Pilots still inside are sent away; those waiting in the lobby keep their place.
func close_world(why: String) -> void:
	if phase == Phase.IDLE:
		return
	print("SERVER world closed: %s" % why)
	for peer in pilots.keys():
		_send_away(int(peer), KICK_TEXT)
	if is_instance_valid(battle):
		battle.end_persistent_world()
	battle = null
	pilots.clear()
	_groups.clear()
	teams = RaidTeams.new()
	phase = Phase.IDLE
	_reopen_wait = REOPEN_DELAY_SECONDS


func _update_open(delta: float) -> void:
	_open_seconds += delta
	var anyone := not pilots.is_empty() or not make_waiting_peers().is_empty()
	_empty_seconds = 0.0 if anyone else _empty_seconds + delta
	var empty_limit := float(cfg.raid_empty_seconds)
	if empty_limit > 0.0 and _empty_seconds >= empty_limit:
		close_world("nobody was in it for %d s" % int(empty_limit))
	elif float(cfg.raid_reset_minutes) > 0.0 and _open_seconds >= float(cfg.raid_reset_minutes) * SECONDS_PER_MINUTE:
		_begin_closing()


func _begin_closing() -> void:
	phase = Phase.CLOSING
	_closing_seconds = 0.0
	print("SERVER world closing: reset time reached, %d pilots inside" % pilots.size())
	if is_instance_valid(battle) and battle.extraction != null:
		battle.extraction.notify_all(RESET_TEXT)


func _update_closing(delta: float) -> void:
	_closing_seconds += delta
	if pilots.is_empty():
		close_world("reset time reached and the raid is empty")
	elif _closing_seconds >= float(cfg.raid_reset_grace_seconds):
		close_world("reset time reached, %d pilots were still inside" % pilots.size())


# ------------------------------------------------------------------ admission

## Opens the battle on the client of every Ready pilot (called by the DedicatedServer each frame while the world is OPEN).
func apply_admissions() -> void:
	if phase != Phase.OPEN or not is_instance_valid(battle):
		return
	for peer in make_waiting_peers():
		_admit(int(peer))


func _admit(peer: int) -> void:
	var entry: Dictionary = (Net.roster[peer] as Dictionary).duplicate(true)
	var group := RaidTeams.make_group_key(peer, entry)
	MatchFlow.apply_extraction_entry(entry, 0, false)
	entry["team"] = teams.allocate(group)
	RosterValidator.apply({peer: entry}, Net.settings)
	pilots[peer] = {"group": group, "entry": entry, "stage": Stage.LOADING, "since": _clock}
	var config := battle.initial_config.duplicate(true)
	config["roster"] = {peer: entry}
	print("SERVER admit %s (peer %d, %s, team %d)" % [str(entry.get("name", "?")), peer, group, int(entry.team)])
	Net.begin_for(peer, config)


## The client of `peer` has built the battle: it is sent the world and waits for the rest of its party.
func apply_loaded(peer: int) -> void:
	var pilot: Dictionary = pilots.get(peer, {})
	if pilot.is_empty() or int(pilot.stage) != Stage.LOADING or not is_instance_valid(battle):
		return
	pilot.stage = Stage.WAITING
	RaidReplay.send(battle, peer)
	var group: Dictionary = _groups.get(pilot.group, {"loaded": [], "expected": PartyRoster.make_party_size(pilot.entry), "since": 0.0})
	group.loaded.append(peer)
	_groups[pilot.group] = group


func _update_groups(delta: float) -> void:
	for key in _groups.keys():
		var group: Dictionary = _groups[key]
		group.since = float(group.since) + delta
		var all_here: bool = (group.loaded as Array).size() >= int(group.expected)
		# a party member who is connected and still building his battle is waited for (JOIN_TIMEOUT_SECONDS at most); one who has
		# not even connected `party_wait_seconds` after the first member is built is not
		var gave_up: bool = float(group.since) >= float(cfg.party_wait_seconds) and not _has_loading_member(key)
		if (all_here or gave_up) and _is_raid_ready():
			_drop_in(key)


func _has_loading_member(group_key: String) -> bool:
	return pilots.values().any(func(p: Dictionary) -> bool: return str(p.group) == group_key and int(p.stage) == Stage.LOADING)


func _is_raid_ready() -> bool:
	var x := battle.extraction
	return x != null and x.transports != null and x.map != null


## Spawns the soldiers of the group's pilots and flies them in together.
func _drop_in(key: String) -> void:
	var peers: Array = (_groups[key].loaded as Array).filter(func(p: int) -> bool: return pilots.has(p))
	_groups.erase(key)
	for peer: int in peers:
		battle.spawner.spawn_player(peer, pilots[peer].entry)
		pilots[peer].stage = Stage.IN
	battle.extraction.start_late_players(peers)
	battle.extraction.transports.start_drop_in(peers)
	print("SERVER drop-in: %s" % str(peers.map(func(p: int) -> String: return str(pilots[p].entry.get("name", "?")))))


func _drop_slow_joiners() -> void:
	for peer in pilots.keys():
		var pilot: Dictionary = pilots[peer]
		if int(pilot.stage) != Stage.IN and _clock - float(pilot.since) > JOIN_TIMEOUT_SECONDS:
			print("SERVER %s took too long to join" % str(pilot.entry.get("name", "?")))
			_send_away(int(peer), TIMEOUT_TEXT)
			apply_left(int(peer))


func _send_away(peer: int, reason: String) -> void:
	_barred[peer] = true
	Net.kick(peer, reason)


func apply_left(peer: int) -> void:
	if not Net.roster.has(peer):
		_barred.erase(peer)
	if not pilots.has(peer):
		return
	pilots.erase(peer)
	for key in _groups:
		(_groups[key].loaded as Array).erase(peer)
	if is_instance_valid(battle):
		battle.admitted_peers.erase(peer)
	teams.release_unused(pilots.values().map(func(p: Dictionary) -> String: return str(p.group)))
