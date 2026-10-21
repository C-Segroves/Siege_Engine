class_name SiegeEnforcer
extends RefCounted
## Host: holds everyone to the safe area (SiegeZone). A unit outside takes damage that grows with every second it stays
## out (damage_share_per_s + growth_per_s * seconds, as a share of its full health) and the shared LeftAreaRule rules it
## lost after lethal_grace_s outside: it is destroyed. Players are warned every warn_every_s. Cybrids, transports and
## soldiers riding in a vehicle (the vehicle counts) are left alone.

const FAIL_CODE := 6

signal warned(unit: Herc)

var battle: Battle
var zone: SiegeZone
var _out := {}              # net id -> seconds outside
var _rule: LeftAreaRule
var _world := SiegeUnitWorld.new()
var _warn := {}             # net id -> seconds to the next warning
var cybrid_team := -1
var killed := 0


func _init(p_battle: Battle, p_zone: SiegeZone, p_cybrid_team: int) -> void:
	battle = p_battle
	zone = p_zone
	cybrid_team = p_cybrid_team
	_rule = LeftAreaRule.new(FAIL_CODE, "Caught outside the safe area.", float(CybridRules.section("safe_area").get("lethal_grace_s", 40.0)))


## True for a unit the safe area applies to.
func is_subject(h: Herc) -> bool:
	return is_instance_valid(h) and h.alive and not h.is_puppet and h.team != cybrid_team \
		and not h.has_meta("transport") and not h.has_meta("dormant") and not (h is Infantry and (h as Infantry).stowed)


## One host step of `dt` seconds, the siege clock at `seconds`.
func apply_tick(dt: float, seconds: float) -> void:
	var rules := CybridRules.section("safe_area")
	for h in battle.vehicles.values().duplicate():
		if not is_subject(h):
			continue
		var id := (h as Herc).net_id
		if zone.is_inside((h as Herc).global_position, seconds):
			_out.erase(id)
			_warn.erase(id)
			continue
		_out[id] = float(_out.get(id, 0.0)) + dt
		_world.out_seconds = float(_out[id])
		if _rule.make_verdict(_world, dt) != null:
			_destroy(h)
		else:
			_hurt(h, dt, rules)
			_apply_warning(h, dt, rules)


func make_seconds_outside(h: Herc) -> float:
	return float(_out.get(h.net_id, 0.0))


func _hurt(h: Herc, dt: float, rules: Dictionary) -> void:
	var rate := float(rules.get("damage_share_per_s", 0.03)) + float(rules.get("growth_per_s", 0.004)) * float(_out[h.net_id])
	h.apply_environment_damage(rate * dt, KillText.CAUSE_BOUNDS)


func _destroy(h: Herc) -> void:
	killed += 1
	h.apply_environment_damage(1.0, KillText.CAUSE_BOUNDS)


func _apply_warning(h: Herc, dt: float, rules: Dictionary) -> void:
	_warn[h.net_id] = float(_warn.get(h.net_id, 0.0)) - dt
	if float(_warn[h.net_id]) <= 0.0:
		_warn[h.net_id] = float(rules.get("warn_every_s", 6.0))
		warned.emit(h)
