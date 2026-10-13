class_name VideoShots
extends RefCounted
## The trailer's shot catalogue for VideoDirector. Each shot is a parameter object:
##   kind      "hangar" | "battle" | "lineup"
##   seconds   length of the action (after the warm-up, which gets trimmed)
## hangar:  hercs [vehicle id, ...] shown in turn (per_herc s each) with weapons from other games
## battle:  herc, config (merged over the default skirmish), ai [{vehicle, team, skill}],
##          view "cockpit" | "chase" | "game" (the game's own views and HUD; view_toggle switches them),
##          pilot "ai" (the player Herc fights by itself) | "inputs",
##          inputs [[from s, to s, [action, ...]], ...] (SiegeInput actions held in that window),
##          taps [[at s, action], ...] (one press of a discrete action: view_toggle, vehicle_enter_exit),
##          stage [[metres ahead, metres right], ...] for the enemies (allies: stage_allies),
##          enemy_health [0..1 per staged enemy] (short fights), settle (s of warm-up), chase {distance, height, side}
## lineup:  dolly {from, to} as fractions of the row width

const DEFAULT_SECONDS := 6.0
## Runs after the battle's own camera code, so the cinematic rig has the last word.
const DIRECTOR_PRIORITY := 100

const ARENA := {"size": 2, "obstacles": "SEVERAL", "turrets": "FEW", "lighting": "BRIGHT"}

## Walk the Raptor in the chase view, then the cockpit; stop, get out (first person), run a lap
## round it in the third person, then walk back to the hatch in first person, board and walk off.
const EXIT_WALKAROUND_INPUTS := [
	[0.0, 2.0, ["throttle_up"]], [4.0, 5.5, ["turn_left"]], [8.0, 9.0, ["turn_right"]], [14.0, 14.8, ["turn_left"]],
	[19.6, 20.86, ["aim_left:0.7"]], [21.3, 21.42, ["aim_up"]], [21.3, 22.15, ["throttle_down"]],
	[23.6, 30.5, ["turn_right"]], [23.7, 30.6, ["aim_left:0.564"]],
	[31.0, 31.5, ["throttle_up"]],
	[32.6, 35.0, ["throttle_up"]],
]
const EXIT_WALKAROUND_TAPS := [[0.0, "view_toggle"], [12.0, "view_toggle"], [17.0, "throttle_stop"],
	[19.0, "vehicle_enter_exit"], [23.2, "view_toggle"], [30.3, "view_toggle"], [31.6, "vehicle_enter_exit"],
	[34.2, "view_toggle"]]

const SHOTS := {
	"hangar": {"kind": "hangar", "seconds": 7.2, "per_herc": 1.8,
		"hercs": ["es1:RAPTOR", "bd:THOR", "es2:OGRE", "starsiege:kn_basl"]},
	"es1_cockpit": {"kind": "battle", "seconds": 8.0, "herc": "es1:RAPTOR", "view": "cockpit", "pilot": "ai",
		"config": {"world": 2, "zone": 0},
		"ai": [{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.4}, {"vehicle": "es1:MONGOOSE", "team": 1, "skill": 0.4},
			{"vehicle": "es1:BULLDOG", "team": 1, "skill": 0.4}],
		"stage": [[120, -15], [165, 35], [205, -45]], "enemy_health": [0.12, 0.25, 0.3], "settle": 1.0},
	"tribes_chase": {"kind": "battle", "seconds": 6.0, "herc": "bd:THOR", "view": "chase", "pilot": "ai",
		"config": {"mode": "vs", "map": "tribes:TheRedSands", "respawn": false},
		"ai": [{"vehicle": "es1:RAPTOR", "team": 0, "skill": 0.8}, {"vehicle": "es2:OGRE", "team": 1, "skill": 0.6},
			{"vehicle": "starsiege:tr_basl", "team": 1, "skill": 0.6}, {"vehicle": "es1:SCORPION", "team": 1, "skill": 0.6}],
		"stage": [[100, -25], [130, 20], [160, -5]], "stage_allies": [[30, -40]], "enemy_health": [0.15, 0.35, 0.5], "settle": 1.0,
		"chase": {"distance": 26.0, "height": 9.0, "side": 9.0}},
	"starsiege_chase": {"kind": "battle", "seconds": 6.0, "herc": "starsiege:kn_basl", "view": "chase", "pilot": "ai",
		"config": {"mode": "vs", "map": "starsiege:DM_Requiem_for_Gen_Lanz", "respawn": false},
		"ai": [{"vehicle": "starsiege:tr_apoc", "team": 0, "skill": 0.8}, {"vehicle": "starsiege:cy_exec", "team": 1, "skill": 0.6},
			{"vehicle": "starsiege:cy_adju", "team": 1, "skill": 0.6}, {"vehicle": "starsiege:cy_goad", "team": 1, "skill": 0.6}],
		"stage": [[70, 25], [95, -30], [120, 5]], "stage_allies": [[30, 40]], "enemy_health": [0.15, 0.35, 0.5], "settle": 1.0,
		"chase": {"distance": 18.0, "height": 6.0, "side": -7.0}},
	"razor_cockpit": {"kind": "battle", "seconds": 5.0, "herc": "es2:RAZOR", "view": "cockpit", "pilot": "inputs",
		"config": {"world_pack": "es2", "world": 0, "zone": 123}, "ai": [], "settle": 0.5,
		"inputs": [[0.0, 5.0, ["throttle_up"]], [0.4, 1.1, ["turn_right"]], [2.0, 2.7, ["turn_left"]], [2.9, 3.5, ["descend"]], [3.0, 5.0, ["fire_group_1"]]]},
	"banshee_chase": {"kind": "battle", "seconds": 5.0, "herc": "starsiege:tr_bans", "view": "chase", "pilot": "inputs",
		"config": {"mode": "vs", "map": "starsiege:DM_Cold_Titan_Night", "respawn": false}, "ai": [], "settle": 0.5,
		"inputs": [[0.0, 5.0, ["ascend"]], [0.8, 5.0, ["throttle_up"]], [2.5, 4.5, ["turn_left"]]],
		"chase": {"distance": 16.0, "height": 5.0, "side": 4.0}},
	"arena": {"kind": "battle", "seconds": 5.0, "herc": "bd:VNDICTR", "view": "chase", "pilot": "ai",
		"config": {"mode": "vs", "respawn": false, "arena": ARENA},
		"ai": [{"vehicle": "bd:THOR", "team": 101, "skill": 0.6}, {"vehicle": "es1:PANTHER", "team": 102, "skill": 0.6},
			{"vehicle": "bd:STRYDER", "team": 103, "skill": 0.6}],
		"stage": [[90, -20], [120, 35], [150, -50]], "enemy_health": [0.15, 0.35, 0.5], "settle": 1.0,
		"chase": {"distance": 22.0, "height": 8.0, "side": 7.0}},
	"exit_walkaround": {"kind": "battle", "seconds": 39.5, "herc": "es1:RAPTOR", "view": "game", "pilot": "inputs",
		"config": {"mode": "vs", "map": "tribes:Raindance", "respawn": false}, "ai": [], "settle": 1.0,
		"rig_windows": [[0.0, 12.0], [32.6, 99.0]], "chase": {"distance": 15.0, "height": 5.5, "side": 6.5},
		"inputs": EXIT_WALKAROUND_INPUTS, "taps": EXIT_WALKAROUND_TAPS},
	"lineup": {"kind": "lineup", "seconds": 6.0, "dolly": {"from": 0.05, "to": 0.5}},
}


static func names() -> PackedStringArray:
	return PackedStringArray(SHOTS.keys() + WeaponShots.SHOTS.keys())


## A copy of shot `shot_name` ({} when unknown); the weapon-effects trailer's shots included.
static func make_spec(shot_name: String) -> Dictionary:
	var spec: Dictionary = SHOTS.get(shot_name, WeaponShots.SHOTS.get(shot_name, {}))
	return spec.duplicate(true)


## A loadout for `vehicle_id` with, on every hardpoint, the strongest fitting weapon from another
## game (the games take turns), to show that weapons from any game are sized to fit.
static func make_foreign_loadout(vehicle_id: String) -> Array:
	var v := Packs.vehicle(vehicle_id)
	var own := String(v.get("pack", ""))
	var loadout := []
	var masks := WeaponFit.hardpoint_masks(v)
	for i in masks.size():
		loadout.append(_make_foreign_pick(Packs.weapons_for_mask(int(masks[i])), own, i))
	return loadout


static func _make_foreign_pick(candidates: Array, own_pack: String, turn: int) -> String:
	var by_pack := {}
	for w in candidates:
		if String(w.pack) == own_pack or (w.get("model", {}) as Dictionary).is_empty() and (w.get("shapes", []) as Array).is_empty():
			continue
		var best: Dictionary = by_pack.get(w.pack, {})
		if best.is_empty() or Packs.weapon_rating(w) > Packs.weapon_rating(best):
			by_pack[w.pack] = w
	if by_pack.is_empty():
		return ""
	var packs := by_pack.keys()
	packs.sort()
	return String(by_pack[packs[turn % packs.size()]].id)
