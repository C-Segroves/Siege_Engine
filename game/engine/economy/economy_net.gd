class_name EconomyNet
extends Node
## Carries the host's credit awards to their owners (docs/design/lobby_loadout_economy.md section 7.2). Put one under the
## same path on every peer (the lobby or the battle root); the host calls send_award, the owner's ProfileAuthority pays
## it and `award_received` tells the results screen to show the lines.

signal award_received(award: Dictionary)

var authority: ProfileAuthority = LocalProfileAuthority.new()


## Host: pays `award` to `peer` (its owner applies it; the host's own award is applied at once).
func send_award(peer: int, award: Dictionary) -> void:
	if not multiplayer.has_multiplayer_peer() or peer == multiplayer.get_unique_id() or multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		_apply(award)
	else:
		_award.rpc_id(peer, award)


@rpc("authority", "reliable")
func _award(award: Dictionary) -> void:
	_apply(award)


func _apply(award: Dictionary) -> void:
	authority.apply_award(multiplayer.get_unique_id(), award)
	award_received.emit(award)
