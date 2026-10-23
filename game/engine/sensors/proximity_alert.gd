class_name ProximityAlert
extends RefCounted
## Proximity detection of the Earthsiege mission rules (ES1 SIM@e722 / SIM@1f496 and DBSIM 0xf744, ES2 DBSIM 0x4137b4 and
## the +0xc flag): "noticed" (an enemy came close, targets the unit, or it was hit) and "unsafe" (an aware enemy within
## the safe range). The ranges are the game's SensorProfile.


## True when an enemy among `vehicles` is within the profile's detect range of `u` or targets it, or `u` (a Herc)
## was already hit.
static func is_noticed(u: Node3D, vehicles: Array, profile: SensorProfile) -> bool:
	for v in vehicles:
		if v.team != u.team and (v.global_position.distance_to(u.global_position) < profile.detect_range_m or v.target == u):
			return true
	return u is Herc and u.integrity < 1.0


## True when enemy `v` is close enough to make `u` unsafe (closer still counts when `v` targets `u`).
static func is_unsafe_from(v: Node3D, u: Node3D, profile: SensorProfile) -> bool:
	var reach := profile.safe_range_targeting_m if v.target == u else profile.safe_range_m
	return v.global_position.distance_to(u.global_position) < reach
