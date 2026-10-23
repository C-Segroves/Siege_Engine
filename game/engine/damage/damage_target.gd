class_name DamageTarget
extends RefCounted
## Hit points of one thing that can be hurt, destroyed and repaired (a base object, a turret, a door, a structure): the
## one place a `DamageEvent` is turned into lost hit points, whichever game it belongs to. Its `DamageProfile` holds
## the game's rules (shield, type scale, team cap, disabled level, invincible).
## Order of an event: a lethal event skips the rest; shield energy first, then the type scale, then the team cap, then
## the hit points. `damaged` is emitted for every hit that took points (a burn is a drain, not a hit: only `killed`), `killed` once when they ran out (the owner
## then destroys itself, plays the death and credits the kill: `event.attacker`).
## The damage states are Tribes GameBase::getDamageState: Enabled, Disabled (damage taken >= profile.disabled_damage), Destroyed.

signal damaged(event: DamageEvent, dealt: float)
signal killed(event: DamageEvent)

const STATE_ENABLED := "Enabled"
const STATE_DISABLED := "Disabled"
const STATE_DESTROYED := "Destroyed"

## Hit points of a target built without data (a Structure's default).
const DEFAULT_HP := 15000.0

var hp := DEFAULT_HP
var max_hp := DEFAULT_HP
var alive := true
## hp / max_hp, the value every peer has (the host sends it with each hit).
var integrity := 1.0
var profile := DamageProfile.new()
## Shield energy (a shielded Tribes object); the owner recharges it.
var shield_energy := 0.0
## Returns whether the shield works now (powered); empty: always.
var shield_online := Callable()
## Returns the team of the owner, for the team-damage cap; empty: no team.
var team_of_owner := Callable()


## Applies `event`; returns the hit points it took (0: absorbed, capped, invincible, indestructible or already destroyed).
func apply_event(event: DamageEvent) -> float:
	if not alive or profile.invincible:
		return 0.0
	var dealt := event.amount if event.is_lethal() else make_effective(event)
	if dealt <= 0.0 or (profile.indestructible and event.kind in [DamageEvent.KIND_WEAPON, DamageEvent.KIND_RAM]):
		return 0.0
	hp -= dealt
	integrity = make_ratio()
	if event.kind != DamageEvent.KIND_BURN:
		damaged.emit(event, dealt)
	if hp <= 0.0:
		killed.emit(event)
	return dealt


## The hit points `event` takes after shield, type scale and team cap (spends the shield energy).
func make_effective(event: DamageEvent) -> float:
	var dmg := event.amount
	if profile.shield_cost > 0.0 and (not shield_online.is_valid() or bool(shield_online.call())):
		var left := ShieldAbsorb.make_through_energy(shield_energy, profile.shield_cost, dmg)
		dmg = left[0]
		shield_energy = left[1]
	dmg *= profile.make_scale(event.type)
	return profile.make_team_capped(dmg, make_damage_taken(), is_friendly(event.attacker))


## True when `attacker` is on the owner's team (a team's own hit).
func is_friendly(attacker: Node) -> bool:
	if attacker == null or not team_of_owner.is_valid() or not ("team" in attacker):
		return false
	return int(attacker.team) == int(team_of_owner.call())


func make_ratio() -> float:
	return clampf(hp / maxf(max_hp, 1.0), 0.0, 1.0)


## Damage taken so far (points), from the integrity every peer has.
func make_damage_taken() -> float:
	return max_hp * (1.0 - integrity)


## True when alive and below the profile's disabled damage (always, when it has none).
func is_enabled() -> bool:
	return alive and (profile.disabled_damage < 0.0 or make_damage_taken() < profile.disabled_damage)


func make_state() -> String:
	if not alive:
		return STATE_DESTROYED
	return STATE_ENABLED if is_enabled() else STATE_DISABLED


## Adds `amount` hit points (never above the maximum; a destroyed target counts from 0); returns the integrity after.
func apply_repair(amount: float) -> float:
	hp = minf(max_hp, maxf(hp, 0.0) + amount)
	integrity = make_ratio()
	return integrity


## A client follows the host's repair: `ratio` of the maximum; a destroyed target with hit points again is alive.
func apply_synced_ratio(ratio: float) -> void:
	integrity = ratio
	hp = max_hp * ratio
	if not alive and hp > 0.0:
		alive = true
