class_name CloakState
extends RefCounted
## One unit's cloak: the shared mechanic of every game that has one (docs/formats/cloaking.md). A soldier's cloaking
## pack (Tribes 2) and a Herc's cloak component (Starsiege) are both a CloakProfile installed on this state; the pilot's
## key, the worn pack, a mission order or a game script switches it on (apply_wanted), and the state decides whether
## the unit is actually cloaked right now (is_cloaked):
##   * it costs profile.energy_per_s of the unit's capacitor while on;
##   * a shot or a hit takes it off for recloak_delay_s (apply_fired / apply_damaged), and with no delay until it is
##     switched on again; a shot breaks it only while the energy is above recloak_min_energy;
##   * a timed cloak (a respawn, a new vehicle: apply_forced) runs on its own and a shot ends it for good;
##   * a badly damaged unit's cloak glitches and fails (profile glitch_health / fail_health);
##   * a puppet on a client follows the host's flag (apply_remote), the host being authoritative.
## CloakRules answers who can see a cloaked unit; CloakVisual draws it. Everything here is a no-op until a profile is installed.

signal toggled(cloaked: bool)

var profile: CloakProfile = CloakProfile.NONE
## 0 plain .. 1 fully cloaked: the shimmer's fade (the shader's `amount`).
var fade := 0.0

var _wanted := false
var _scripted := false
var _followed := false
var _forced_off := false
var _forced_s := 0.0
var _suppressed_s := 0.0
var _time := 0.0
var _cloaked := false
var _remote := false
var _visual := CloakVisual.new()


## Installs `p` (CloakProfile.NONE removes the cloak).
func apply_profile(p: CloakProfile) -> void:
	profile = p
	if not p.is_real():
		_wanted = false
		_forced_s = 0.0
		_suppressed_s = 0.0


func is_equipped() -> bool:
	return profile.is_real()


## True while the unit is cloaked in effect (not during a break, a glitch or a failure).
func is_cloaked() -> bool:
	return _cloaked


func is_wanted() -> bool:
	return _wanted


## True when the cloak gear makes its wearer invisible to sensors that do not detect jammed units, cloak on or off.
func is_passive_jammed() -> bool:
	return profile.jams_sensors_when_worn


## Switches the cloak on or off. It starts only with at least min_energy in `unit`'s capacitor.
func apply_wanted(on: bool, unit: Node) -> void:
	if on and _is_jammed(unit):
		_forced_off = true   # onActivate: "Jamming field prevents cloaking", the pack switches itself off
		return
	if on and (not profile.is_real() or float(unit.get("capacitor")) < profile.min_energy):
		return
	_wanted = on and profile.is_real()


## Follows a switch kept elsewhere (the worn pack's on / off): acts when the switch changes, so the cloak's own
## breaks (a shot without a delay, a failed battery) are not undone while the switch stays on.
func apply_follow(on: bool, unit: Node) -> void:
	if on != _followed:
		_followed = on
		apply_wanted(on, unit)


func apply_toggle(unit: Node) -> void:
	apply_wanted(not _wanted, unit)


## A timed cloak of `seconds` that needs no key (a respawn, a vehicle leaving its pad).
func apply_forced(seconds: float) -> void:
	if profile.is_real():
		_forced_s = maxf(_forced_s, seconds)


## A script's setCloaked (Tribes 2 `%obj.setCloaked(true)`): on until the script (or a shot) turns it off.
func apply_scripted(on: bool) -> void:
	_scripted = on and profile.is_real()


## The unit fired: the cloak breaks (profile breaks_on_fire) as the original's weapon image does.
func apply_fired(unit: Node) -> void:
	if not _cloaked or not profile.breaks_on_fire:
		return
	if _forced_s > 0.0 or _scripted:
		_forced_s = 0.0
		_scripted = false
		return
	if profile.recloak_min_energy > 0.0 and float(unit.get("capacitor")) <= profile.recloak_min_energy:
		return
	_apply_break()


## The unit took a hit of `amount`: a hard enough one breaks the cloak (profile breaks_on_damage).
func apply_damaged(amount: float) -> void:
	if _cloaked and profile.breaks_on_damage and amount > profile.damage_break_min:
		_apply_break()


## True once, after a jammer's field switched the cloak off (the pack then switches off too: onForceUncloak).
func take_forced_off() -> bool:
	var was := _forced_off
	_forced_off = false
	return was


## A puppet shows the host's flag.
func apply_remote(cloaked: bool) -> void:
	_remote = cloaked


## One frame: timers, the energy drain, the cloak's state and its fade. `unit` is the Herc / soldier carrying it.
func apply_step(unit: Node, delta: float) -> void:
	if _is_idle():
		return
	_time += delta
	var before := _cloaked
	if bool(unit.get("is_puppet")):
		_cloaked = _remote
	else:
		_apply_local_step(unit, delta)
	if _cloaked != before:
		toggled.emit(_cloaked)
	fade = move_toward(fade, 1.0 if _cloaked else 0.0, delta / maxf(0.01, profile.fade_in_s if _cloaked else profile.fade_out_s))
	_visual.apply_amount(unit, fade, profile.reveal_range_m)


## The state of the cloak as the snapshot carries it.
func make_flag() -> bool:
	return _cloaked


## Nothing to do: no cloak asked for, none showing, no timer running.
func _is_idle() -> bool:
	return fade <= 0.0 and not (_cloaked or _wanted or _scripted or _remote) and _forced_s <= 0.0 and _suppressed_s <= 0.0


func _apply_local_step(unit: Node, delta: float) -> void:
	_forced_s = maxf(0.0, _forced_s - delta)
	_suppressed_s = maxf(0.0, _suppressed_s - delta)
	if not bool(unit.get("alive")):
		_wanted = false
		_scripted = false
		_forced_s = 0.0
	if _wanted and _is_jammed(unit):
		_wanted = false
		_forced_off = true
	if _wanted and profile.energy_per_s > 0.0:
		unit.set("capacitor", maxf(0.0, float(unit.get("capacitor")) - profile.energy_per_s * delta))
	_cloaked = profile.is_real() and (_wanted or _scripted or _forced_s > 0.0) and _suppressed_s <= 0.0 and not _is_glitching(unit)


func _is_jammed(unit: Node) -> bool:
	return profile.blocked_by_jam_field and CloakRules.is_in_jam_field(unit)


func _apply_break() -> void:
	if profile.recloak_delay_s > 0.0:
		_suppressed_s = profile.recloak_delay_s
	else:
		_wanted = false


## Starsiege: below fail_health the cloak is dead, below glitch_health it drops out for half of every 1 / glitch_coef seconds.
func _is_glitching(unit: Node) -> bool:
	var health := float(unit.get("integrity"))
	if profile.fail_health > 0.0 and health < profile.fail_health:
		return true
	if profile.glitch_health > 0.0 and profile.glitch_coef > 0.0 and health < profile.glitch_health:
		var period := 1.0 / profile.glitch_coef
		return fmod(_time, period) > period * 0.5
	return false
