class_name LobbyPing
extends RefCounted
## The round trip time shown on a lobby card or row. ENet knows it for the peers one is connected to: the host for
## every client, a client for the host only; other pilots show nothing.


## "32 ms" for `peer` as seen from `my_id`, "" when unknown.
static func make_text(peer: int, my_id: int) -> String:
	var enet := Net.multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if enet == null or peer == my_id:
		return ""
	var host_view: bool = my_id == MatchFlow.HOST_ID
	if not host_view and peer != MatchFlow.HOST_ID:
		return ""
	if not Net.multiplayer.get_peers().has(peer):
		return ""
	var p := enet.get_peer(peer)
	if p == null or not p.is_active():
		return ""
	return "%d ms" % int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
