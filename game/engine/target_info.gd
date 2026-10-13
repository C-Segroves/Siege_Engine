class_name TargetInfo
extends RefCounted
## What every target display reads from a target, whatever it is: a vehicle or soldier (Herc), or a targetable
## structure (group "targetables": display_name, team, alive, integrity 0..1). Also the remake's friend-or-foe
## marking (playtest 2026-10-11 A5): one colour and one IFF word per relation, shared by the cockpit target boxes,
## the plain HUD, the radars and the name plates over teammates' heads.

const IFF_FRIEND := "FRIEND"
const IFF_ENEMY := "ENEMY"
const IFF_NEUTRAL := "NEUTRAL"
## Friend-or-foe colours (remake: the originals mark only hostiles).
const FRIEND_COLOR := Color(0.35, 1.0, 0.55)
const ENEMY_COLOR := Color(1.0, 0.32, 0.25)
const NEUTRAL_COLOR := Color(1.0, 0.85, 0.3)
## Height (m) of a target without a model height (a structure's aim point sits at half of it).
const DEFAULT_HEIGHT := 8.0


## True for a living, valid target.
static func is_live(t: Object) -> bool:
	return t != null and is_instance_valid(t) and t is Node3D and bool(t.get("alive"))


## True when `t` is on `viewer`'s team or an allied one.
static func is_friendly(viewer: Node, t: Node) -> bool:
	return TeamRelations.is_allied(int(viewer.get("team")), int(t.get("team")))


static func is_hostile(viewer: Node, t: Node) -> bool:
	return TeamRelations.is_hostile(int(viewer.get("team")), int(t.get("team")))


## FRIEND / ENEMY / NEUTRAL of `t` as `viewer` sees it.
static func make_iff_text(viewer: Node, t: Node) -> String:
	if is_friendly(viewer, t):
		return IFF_FRIEND
	return IFF_ENEMY if is_hostile(viewer, t) else IFF_NEUTRAL


## In a match of more than two teams an opposing unit shows its team's colour (MapTeams), so the teams are told apart.
static func make_iff_color(viewer: Node, t: Node) -> Color:
	if is_friendly(viewer, t):
		return FRIEND_COLOR
	if not is_hostile(viewer, t):
		return NEUTRAL_COLOR
	return MapTeams.make_team_color(int(t.get("team"))) if MapTeams.shows_team_colors else ENEMY_COLOR


## The name a display shows: the pilot's / building's name.
static func make_name(t: Node) -> String:
	var n := str(t.get("display_name")) if t.get("display_name") != null else ""
	return n if n != "" else str(t.name)


## The model's type name ("RAPTOR"; a structure's own name).
static func make_type_name(t: Node) -> String:
	if t is Herc:
		return str((t as Herc).def.get("name", (t as Herc).vehicle_id))
	return make_name(t)


## Health 0..1: a vehicle's integrity, a structure's integrity (else hp / max_hp).
static func make_integrity(t: Node) -> float:
	if t.get("integrity") != null:
		return clampf(float(t.get("integrity")), 0.0, 1.0)
	if t.get("hp") != null and t.get("max_hp") != null:
		return clampf(float(t.get("hp")) / maxf(float(t.get("max_hp")), 1.0), 0.0, 1.0)
	return 1.0


## Shield charge 0..1 (structures have none: 0).
static func make_shield_share(t: Node) -> float:
	if not (t is Herc) or (t as Herc).shield_max <= 0.0:
		return 0.0
	var h := t as Herc
	return clampf((h.shield_front + h.shield_rear) / h.shield_max, 0.0, 1.0)


## Height of the target's model (m).
static func make_height(t: Node3D) -> float:
	if t is Herc:
		var h := t as Herc
		var catalog := float(h.def.get("height_m", 0.0))
		if catalog > 0.0:
			return catalog
		if h.shape != null:
			return h.make_body_size().y
	return DEFAULT_HEIGHT


## World velocity (m/s; zero for a structure).
static func make_velocity(t: Node3D) -> Vector3:
	return (t as CharacterBody3D).velocity if t is CharacterBody3D else Vector3.ZERO
