class_name RadarProxy
extends Node3D
## The radar contact of a far bot that has no scene node (docs/DEDICATED_SERVER_SCALING.md chunk L): a bare Node3D in
## group GROUP carrying what the radars, the command map and T-targeting read (position, team, alive, name), so
## RadarContacts.is_on_scope works on it like on the unit. Targeting one promotes the bot to a full node
## (Targeting.promote). Not in group "vehicles": nothing else sees it.

const GROUP := "radar_proxies"

var net_id := 0
var team := 0
var alive := true
var display_name := ""
var is_soldier := false


func _init(p_id := 0, p_team := 0, p_soldier := false) -> void:
	net_id = p_id
	team = p_team
	is_soldier = p_soldier
	name = "RadarProxy%d" % p_id
	add_to_group(GROUP)
