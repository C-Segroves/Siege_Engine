class_name DedicatedFixture
extends RefCounted
## A dedicated extraction server inside a test process (tests/dedicated_extraction_check.gd, tests/party_check.gd): Katabatic with fast
## timers and a few faction soldiers; `overrides` replace any ServerConfig key.


## A long protection for every soldier of `raid`'s pilots in the world (so the world's own dangers - turrets, faction squads - never end
## a test before the test decides to); `seconds` 0 takes it away again.
static func apply_protection(raid: RaidServer, seconds: float) -> void:
	if not is_instance_valid(raid.battle):
		return
	for peer in raid.pilots:
		var soldier := raid.battle.occupancy.soldier_of(int(peer))
		if soldier != null and soldier.spawn_protection != seconds:
			soldier.spawn_protection = seconds
			soldier.apply_spawn_protection()


## Starts the server as a child of `parent` (its start() has run: it listens) and returns it.
static func start_extraction_server(parent: Node, overrides: Dictionary) -> DedicatedServer:
	var server: DedicatedServer = load("res://server/dedicated_server.tscn").instantiate()
	server.autostart = false
	server.cfg = ServerConfig.DEFAULTS.duplicate()
	server.cfg.merge({"name": "Test raid", "mode": ExtractionRules.MODE, "map": "Katabatic", "max_players": 8, "bots": 2, "ai": 0,
		"raid_fast": 1, "raid_empty_seconds": 8.0, "party_wait_seconds": 6.0, "results_hold_seconds": 2.0, "stats_seconds": 0.0}, true)
	server.cfg.merge(overrides, true)
	parent.add_child(server)
	server.start()
	return server
