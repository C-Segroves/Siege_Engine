class_name CallinHud
extends RefCounted
## What the raid HUD shows of the call-ins (CallinDirector hands it to ExtractionHud): the text lines (the balance, the laser
## designation in progress with its verdict, the caller's orders) and the world
## markers of the caller's own zones. The radar sweep's contacts are not markers: they are real radar contacts
## (CallinSweep, RadarContacts.apply_swept).


## The call-in lines of the raid HUD: the balance, the caller's own orders and a running sweep ([text]).
static func make_lines(callins: CallinDirector) -> Array:
	var points := callins.points
	var out := [points.make_hud_text() + ("   " + points.last_gain if points.last_gain_left > 0.0 else "")]
	out.append_array(callins.designator.make_hud_lines())
	var me := callins.multiplayer.get_unique_id()
	for v in callins.views.values():
		if int(v.get("peer", -1)) == me:
			out.append(CallinOrder.make_hud_line(v))
	if callins.sweep.left > 0.0:
		out.append("RADAR SWEEP %d:%02d  (%d contacts)" % [int(callins.sweep.left) / 60, int(callins.sweep.left) % 60, callins.sweep.contacts.size()])
	return out


## World markers: the caller's zones with their countdown: [{pos, label, contact}].
static func make_markers(callins: CallinDirector) -> Array:
	var out := []
	for v in callins.views.values():
		if int(v.state) <= CallinOrder.State.EXPIRING and v.has("peer"):
			out.append({"pos": v.lz, "label": CallinOrder.make_hud_line(v), "contact": false})
	return out
