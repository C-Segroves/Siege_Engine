class_name InfantryNet
extends RefCounted
## A soldier's LAN state beyond the Herc snapshot (BattleNetSync): the extra controls a client sends
## [jet, jump, weapon slot] and the extra snapshot state the host sends, appended after the damage block
## (Infantry.SNAP_INFANTRY): [jetting, weapon slot, stowed, rounds per weapon, kit (InfantryKit.make_state)].

const CONTROL_FIELDS := 3


static func make_controls(s: Infantry) -> Array:
	return [s.jet_input, s.jump_input, s.weapon_slot]


static func apply_controls(s: Infantry, c: Array) -> void:
	if c.size() < CONTROL_FIELDS:
		return
	s.jet_input = bool(c[0])
	s.jump_input = bool(c[1])
	if int(c[2]) != s.weapon_slot:
		s.apply_weapon_slot(int(c[2]))


static func make_snapshot(s: Infantry) -> Array:
	return [s.jetting, s.weapon_slot, s.stowed, PackedInt32Array(s.weapons.map(func(w: Weapon) -> int: return w.ammo)),
		s.kit.make_state()]


## Applies the host's extra state to a puppet soldier (its own player keeps his weapon choice).
static func apply_snapshot(s: Infantry, extra: Array) -> void:
	s.jetting = bool(extra[0])
	if int(extra[1]) != s.weapon_slot and not s.is_local_player():
		s.apply_weapon_slot(int(extra[1]))
	if bool(extra[2]) != s.stowed:
		s.apply_stowed(bool(extra[2]), s.seat)
	var rounds: PackedInt32Array = extra[3] if extra.size() > 3 else PackedInt32Array()
	for i in mini(rounds.size(), s.weapons.size()):
		s.weapons[i].ammo = rounds[i]
	if extra.size() > 4:
		s.kit.apply_state(extra[4])
