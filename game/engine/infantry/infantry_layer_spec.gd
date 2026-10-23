class_name InfantryLayerSpec
extends RefCounted
## Per game data for the additive layers of a soldier (InfantryAnimationLayers): which sequences the original game scrubs by the
## look pitch and yaw, which one plays when a weapon fires, and how the sequence keys relate to the rest pose. Keyed by the pack
## of the body shape ("tribes:larmor" -> "tribes"). A pack without an entry (Vengeance: its skeletons carry no look sequences)
## gets no layers.
##
## Fields of a spec:
##   mode        "add" = the keys are deltas composed onto the base pose (Torque blend sequences, Aerial Assault's additive
##               sequences); "replace" = the keys are a pose that takes over the nodes it keys (Tribes 1 "looks").
##   reference   how an additive key holds its delta: "identity" = the key itself is the delta, rotation and offset (Torque .dsq
##               blend keys, neutral = identity and no offset), "rest" = the node's rest pose with the delta composed on top
##               (tools/aa_soldier.py).
##   arm         the weapon-arm thread scrubbed by pitch: "unarmed" and "armed" candidate sequence names (first the shape has
##               wins), "by_weapon" the armed names of a weapon (Torque ShapeBaseImageData.armThread, default "look").
##   head        sequences scrubbed by pitch ("pitch") and by the head's yaw off the body ("yaw").
##   recoil      the sequence played once from a shot, for the weapons listed (empty = every weapon).
##   up_at       cycle position of the sequences at full look up (0.5 = level, the other end = full look down).
##   weight      how much of each layer is applied (1 = as authored).
## Sources: Tribes 2 scripts/weapons.cs (setArmThread: the image's armThread, else look), weapons/*.cs (stateRecoil = LightRecoil
## on the Fire state: disc, grenade launcher, missile launcher, mortar, plasma; NoRecoil: blaster; none: chaingun),
## missileLauncher.cs armThread = lookms, sniperRifle.cs armThread = looksn, player.cs min/maxLookAngle +-1.4 (the look
## sequences run over that range). Aerial Assault: tools/aa_soldier.py ADDITIVE (recoil, look, lookms, looksn, head, headside).

const SPECS := {
	"tribes": {
		"mode": "replace", "weight": 1.0, "up_at": 1.0,
		"arm": {"unarmed": ["looks"], "armed": ["looks"], "by_weapon": {}},
		"head": {"pitch": [], "yaw": []},
		"recoil": {"seq": [], "weapons": []},
	},
	"tribes2": {
		"mode": "add", "reference": "identity", "weight": 1.0, "up_at": 1.0,
		"arm": {"unarmed": ["looknw"], "armed": ["look"], "by_weapon": {"MISSILE_LAUNCHER": ["lookms"], "LASER_RIFLE": ["looksn"]}},
		"head": {"pitch": ["head"], "yaw": ["headside"]},
		"recoil": {"seq": ["light_recoil"], "weapons": ["SPINFUSOR", "GRENADE_LAUNCHER", "MISSILE_LAUNCHER", "MORTAR", "PLASMA_RIFLE"]},
	},
	"tribes_aa": {
		"mode": "add", "reference": "rest", "weight": 1.0, "up_at": 1.0,
		"arm": {"unarmed": ["look", "lookms"], "armed": ["look", "lookms"], "by_weapon": {"MISSILE_LAUNCHER": ["looksn", "lookms", "look"]}},
		"head": {"pitch": ["head"], "yaw": ["headside"]},
		"recoil": {"seq": ["recoil"], "weapons": []},
	},
}


## The spec for a body shape id ("tribes2:light_male"), {} when its game has none.
static func make_spec(shape_id: String) -> Dictionary:
	return SPECS.get(shape_id.get_slice(":", 0), {})
