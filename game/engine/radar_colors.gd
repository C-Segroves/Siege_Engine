class_name RadarColors
extends RefCounted
## The colours of every radar and the command map: green = the viewer's team (and allies), red = enemies, blue =
## everything else (waypoints, nav points, exfil zones and transports, objectives, neutral units and structures).
## No original-game exception is kept: docs/formats/cockpit.md lists the original's radar blip colours as unknown,
## so nothing proves the original cockpits drew different ones.

const FRIEND := Color(0.35, 1.0, 0.45)
const ENEMY := Color(1.0, 0.3, 0.25)
const OTHER := Color(0.35, 0.65, 1.0)


## The colour of unit/structure `t` on `viewer`'s radar.
static func make_unit_color(viewer: Node, t: Node) -> Color:
	if TargetInfo.is_friendly(viewer, t):
		return FRIEND
	return ENEMY if TargetInfo.is_hostile(viewer, t) else OTHER
