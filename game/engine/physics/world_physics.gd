class_name WorldPhysics
extends RefCounted
## The world's physics constants per game, from each pack's imported units.json (docs/formats/units.md):
## gravity_mps2 = the game's own gravity (Tribes 1 contGravity "0 0 -20", Torque's default -20 for Tribes 2); a pack
## without one (Earthsiege 1 / 2 and Battledrome, whose Hercs follow the terrain; Starsiege, whose per-planet value
## is not decoded) falls at the Earth value.

const DEFAULT_GRAVITY := 9.8

static var _gravity := {}


## Gravity (m/s^2) a body of game `pack` falls with.
static func gravity_of_pack(pack: String) -> float:
	if not _gravity.has(pack):
		var u = Assets.load_json("units.json", pack)
		var g = u.get("gravity_mps2") if u is Dictionary else null
		_gravity[pack] = float(g) if g != null and float(g) > 0.0 else DEFAULT_GRAVITY
	return _gravity[pack]


## Gravity of the game catalog definition `def` (vehicle, armour, item) belongs to.
static func gravity_of(def: Dictionary) -> float:
	return gravity_of_pack(DamageModel.pack_of(def))
