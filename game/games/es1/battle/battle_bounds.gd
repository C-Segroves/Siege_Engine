class_name BattleBounds
extends Node
## Host: keeps everyone on the battlefield (MapBounds). A vehicle or soldier outside the playable area is warned,
## then damaged until it comes back or dies; one that fell out of the world dies at once. The dead respawn per
## the mode (BattleRules, BattleInfantry). Every peer has this node ("Bounds"): the host sends a player his
## warnings by RPC.
##
## Out-of-bounds rule: Tribes' (base/dm.cs Player::leaveMissionArea / alertPlayer / leaveMissionAreaDamage):
## "You have left the mission area.", the warning sound three times 1.5 s apart, a second later 0.05 damage
## level every second until the player is back or dead (light armour maxDamage 0.66). The remake applies it to
## every vehicle and soldier as a share of its full health (DAMAGE_SHARE_PER_TICK). Tribes 2 only warns
## (defaultGame.cs DefaultGame::leaveMissionArea); its training missions (Training3 starts outside its area) and
## Tribes 1 missions keep their own scripts' rule, so Tribes missions are left to their runtime.

const NODE_NAME := "Bounds"
const WARNING_COUNT := 3
const WARNING_INTERVAL := 1.5
## alertPlayer's last warning schedules the first damage 1 s later.
const DAMAGE_DELAY := WARNING_COUNT * WARNING_INTERVAL - WARNING_INTERVAL + 1.0
const DAMAGE_INTERVAL := 1.0
## GameBase::setDamageLevel(+0.05) of light armour (maxDamage 0.66).
const DAMAGE_SHARE_PER_TICK := 0.05 / 0.66
const LEFT_TEXT := "You have left the mission area."
const WARNING_TEXT := "Return to the mission area!"
const BACK_TEXT := "You are back in the mission area."
const MESSAGE_SECONDS := 2.0
const WARNING_SOUND := "target_unlock"
## A vehicle is left alone this long after it first appears or respawns: missions and spawners may still be
## moving it to its start (a Starsiege player Herc is built at the origin and placed by the mission script).
const SETTLE_SECONDS := 2.0
## A dedicated server applies the rules to each unit every this many ticks (with the time they covered): the world-floor
## test walks every building box.
const SERVER_STRIDE := 4

## Area rules (MissionKinds.make_area_rule): Tribes' warnings and damage (matches, Starsiege missions), warnings only
## while the mission's own rules decide (Earthsiege 1 / 2: the mission ends), or none (Tribes missions: their
## scripts own the area). The world-floor rule applies to every battle.
const AREA_DAMAGE := "damage"
const AREA_MISSION := "mission"
const AREA_NONE := "none"

var battle: Battle
var bounds: MapBounds
var area_rule := AREA_DAMAGE
## Area rule on (off for Tribes missions, whose scripts own it).
var checks_area: bool:
	get: return area_rule != AREA_NONE
var _out_seconds := {}     # net_id -> seconds outside
var _ticks := 0
var _settle := {}          # net_id -> seconds left before the rules apply (refilled when it is dead)


func _init(p_battle: Battle, p_bounds: MapBounds) -> void:
	battle = p_battle
	bounds = p_bounds
	name = NODE_NAME


func _physics_process(delta: float) -> void:
	if not battle.multiplayer.is_server() or battle.is_over():
		return
	_ticks += 1
	var stride := SERVER_STRIDE if ServerProfile.is_collision_only() else 1   # a server checks each unit every few ticks
	for v in battle.vehicles.values():
		if not is_instance_valid(v) or v.is_puppet:
			continue
		if not v.alive:
			_settle[v.net_id] = SETTLE_SECONDS
		elif _is_settled(v, delta) and v.is_in_group("vehicles") and (v.net_id + _ticks) % stride == 0:
			_apply_rules(v, delta * stride)


## Counts down `v`'s settling time (SETTLE_SECONDS); true once it is over.
func _is_settled(v: Herc, delta: float) -> bool:
	var left := float(_settle.get(v.net_id, SETTLE_SECONDS)) - delta
	_settle[v.net_id] = maxf(left, 0.0)
	return left <= 0.0


func _apply_rules(v: Herc, delta: float) -> void:
	if bounds.is_below_floor(battle, v.global_position):
		_out_seconds.erase(v.net_id)
		if not v.is_spawn_protected():
			v.apply_environment_damage(1.0, KillText.CAUSE_FELL_THROUGH)
		return
	if is_out_of_area(v):
		_apply_outside(v, delta)
	elif _out_seconds.has(v.net_id):
		_out_seconds.erase(v.net_id)
		_warn(v, BACK_TEXT)


## One frame outside: the warnings at 0, 1.5 and 3 s, damage every second from DAMAGE_DELAY.
func _apply_outside(v: Herc, delta: float) -> void:
	var before := float(_out_seconds.get(v.net_id, -1.0))
	var now := maxf(before, 0.0) + delta
	_out_seconds[v.net_id] = now
	if before < 0.0:
		_warn(v, LEFT_TEXT)
	elif _crossed(before, now, WARNING_INTERVAL) and now < DAMAGE_DELAY:
		_warn(v, WARNING_TEXT)
	if area_rule == AREA_DAMAGE and now >= DAMAGE_DELAY and (before < DAMAGE_DELAY or _crossed(before - DAMAGE_DELAY, now - DAMAGE_DELAY, DAMAGE_INTERVAL)):
		v.apply_environment_damage(DAMAGE_SHARE_PER_TICK)
		if not v.alive:
			_out_seconds.erase(v.net_id)


## True when a multiple of `step` lies in (before, now].
static func _crossed(before: float, now: float, step: float) -> bool:
	return floorf(now / step) > floorf(before / step)


## True when `v` is outside the area by the rule: the one test of the damage and of the local player's tint (BoundsTint).
## AI support craft and their riders are exempt.
func is_out_of_area(v: Node3D) -> bool:
	return checks_area and bounds.is_outside(v.global_position) and not SupportCraft.is_exempt(v)


## How far `p` lies outside the area (metres; 0 inside or without an area).
func make_outside_distance(p: Vector3) -> float:
	if not bounds.is_outside(p):
		return 0.0
	var r := bounds.area
	var dx := maxf(maxf(r.position.x - p.x, p.x - r.end.x), 0.0)
	var dz := maxf(maxf(r.position.y - p.z, p.z - r.end.y), 0.0)
	return Vector2(dx, dz).length()


## Seconds `v` has been outside the area (0 inside).
func make_out_seconds(v: Herc) -> float:
	return float(_out_seconds.get(v.net_id, 0.0))


func _warn(v: Herc, text: String) -> void:
	if v.has_meta("ai"):
		return
	if v.owner_peer == battle.multiplayer.get_unique_id():
		_show_warning(text)
	elif Net.is_online():
		_show_warning.rpc_id(v.owner_peer, text)


@rpc("authority", "call_remote", "reliable")
func _show_warning(text: String) -> void:
	battle.overlay.show_message(text, MESSAGE_SECONDS)
	Sfx.play_ui(WARNING_SOUND)
