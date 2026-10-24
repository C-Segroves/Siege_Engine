class_name RaidReplay
extends RefCounted
## A pilot joins a persistent raid that is already running: his client has built the map (Battle) but knows none of the
## units, seats or loot that appeared since the raid began. The host sends him, once and in this order, what every other
## client received live: the living units (Battle.spawn_log), who sits where (OccupancyDirector), the raid's caches, zones,
## relations and exfil calls and the pilots' current weapons (ExtractionDirector.replay_to). From then on he gets the
## snapshots and the live messages like everybody else (Battle.admitted_peers).
## Not replayed: parts of the map that were destroyed before he came (a base's generators and turrets are as new for him).
##   RaidReplay.send(battle, peer)


static func send(battle: Battle, peer: int) -> void:
	for id in battle.spawn_log:
		var unit: Herc = battle.vehicles.get(id)
		if is_instance_valid(unit) and unit.alive:   # a wreck lying about is not worth a spawn: nobody could tell it from a ghost
			battle._spawn.rpc_id(peer, battle.spawn_log[id])
	battle.occupancy.replay_to(peer)
	if battle.extraction != null:
		battle.extraction.replay_to(peer)
	battle.admitted_peers[peer] = true
