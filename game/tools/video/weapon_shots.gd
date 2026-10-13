class_name WeaponShots
extends RefCounted
## The weapon-effects trailer's shots (WeaponDuelShot, kind "duel"): one per game, each a shooter firing
## that game's signature weapons at a target dummy that blows up at the end. Spec keys: see WeaponDuelShot.

## Over the shooter's shoulder, out to the side of the line of fire, then up close to the target.
const HERC_CAMERA := [[0.0, -0.32, 10.0, 7.5, 0.7, 4.5], [1.6, -0.05, 16.0, 6.0, 0.7, 4.5],
	[3.4, 0.45, 18.0, 5.0, 0.85, 4.5], [5.0, 0.78, 12.0, 3.5, 1.0, 5.0], [6.5, 0.82, 11.0, 3.5, 1.0, 5.0]]
const SOLDIER_CAMERA := [[0.0, -0.20, 2.5, 2.6, 0.55, 2.2], [1.8, -0.08, 5.0, 2.5, 0.6, 2.5],
	[3.6, 0.40, 12.0, 3.5, 0.85, 3.5], [5.0, 0.72, 11.0, 4.0, 1.0, 4.5], [6.5, 0.76, 10.0, 4.0, 1.0, 4.5]]
## Big Cybrid targets: the close-up stays further out.
const WIDE_HERC_CAMERA := [[0.0, -0.32, 10.0, 7.5, 0.7, 4.5], [1.6, -0.05, 16.0, 6.0, 0.7, 4.5],
	[3.4, 0.40, 20.0, 6.0, 0.85, 5.0], [5.0, 0.62, 21.0, 6.0, 1.0, 5.5], [6.5, 0.64, 21.0, 6.0, 1.0, 5.5]]
const ARENA := {"size": 2, "obstacles": "SEVERAL", "turrets": "NONE", "lighting": "BRIGHT"}

const SHOTS := {
	"fx_es1": {"kind": "duel", "seconds": 6.5, "herc": "es1:PANTHER", "settle": 0.8,
		"config": {"world": 2, "zone": 0},
		"loadout": ["es1:LAS300", "es1:ATC50", "es1:EMP", "es1:MLRS8", "es1:MLRS8", "es1:LAS300"],
		"ai": [{"vehicle": "es1:SCORPION", "team": 1, "skill": 0.4}],
		"stage": [[45, 0]], "target_shield": 1.0, "kill_at": 4.9,
		"death_fx": [["explo_16", "es1", 0.0, [0, 0.5, 0]], ["explo_17", "es1", 0.3, [2, 0.5, 1]], ["explo_9", "es1", 0.6, [-2, 0.5, -1]]],
		"slowmo": [[4.85, 5.8, 0.5]],
		"fire": [[0.0, 1.6, [0, 5]], [1.0, 3.0, [1]], [2.0, 3.4, [2]], [3.0, 3.6, [3, 4]], [4.0, 5.0, [0, 5]]],
		"camera": HERC_CAMERA},
	"fx_bd": {"kind": "duel", "seconds": 6.5, "herc": "bd:THOR", "settle": 0.8,
		"config": {"mode": "vs", "respawn": false, "arena": ARENA},
		"loadout": ["bd:LASER5", "bd:PLASMA3", "bd:LASER5", "bd:PLASMA3", "bd:CHARLIE_20", "bd:CHARLIE_20"],
		"ai": [{"vehicle": "bd:STRYDER", "team": 1, "skill": 0.4}],
		"stage": [[45, 0]], "target_shield": 1.0, "kill_at": 4.9,
		"death_fx": [["expl1_EXPLD2", "bd", 0.0, [0, 5, 0]], ["expl7_SHROOM", "bd", 0.2, [0, 0.5, 0]], ["expl1_EXPLD1", "bd", 0.45, [2, 6, 1]]],
		"fire": [[0.0, 2.0, [0, 2]], [1.2, 3.4, [1, 3]], [3.0, 3.6, [4, 5]], [4.0, 5.0, [0, 2]]],
		"camera": HERC_CAMERA},
	"fx_es2": {"kind": "duel", "seconds": 6.5, "herc": "es2:APOCA", "settle": 0.8,
		"config": {"world_pack": "es2", "world": 0, "zone": 123},
		"loadout": ["es2:LAS500", "es2:ELF2", "es2:LAS500", "es2:PBW2", "es2:ATC100", "es2:MSL8_ARH", "es2:EMP", "es2:MSL8_ARH"],
		"ai": [{"vehicle": "es2:OGRE", "team": 1, "skill": 0.4}],
		"stage": [[45, 0]], "target_shield": 1.0, "kill_at": 4.9,
		"death_fx": [["explo_20", "es2", 0.0, [0, 5, 0]], ["explo_19", "es2", 0.25, [2, 3, 1]], ["explo_10", "es2", 0.5, [-2, 6, -1]]],
		"fire": [[0.0, 1.6, [0, 2]], [1.0, 2.4, [1]], [1.6, 3.0, [3, 4]], [2.6, 3.4, [6]], [3.0, 3.6, [5, 7]], [4.0, 5.0, [0, 2]]],
		"camera": HERC_CAMERA},
	"fx_starsiege": {"kind": "duel", "seconds": 6.5, "herc": "starsiege:kn_apoc", "settle": 0.8,
		"config": {"mode": "vs", "map": "starsiege:DM_Requiem_for_Gen_Lanz", "respawn": false},
		"loadout": ["starsiege:BLAS", "starsiege:ELF", "starsiege:HATC", "starsiege:HATC", "starsiege:SWRM", "starsiege:VIP12"],
		"ai": [{"vehicle": "starsiege:cy_exec", "team": 1, "skill": 0.4}],
		"stage": [[45, 0]], "target_shield": 1.0, "kill_at": 5.0,
		"death_fx": [["exp_l", "starsiege", 0.0, [0, 4, 0]], ["fball_m", "starsiege", 0.25, [0, 7, 0]], ["exp_l", "starsiege", 0.5, [0, 2, 0]]],
		"fire": [[0.0, 1.8, [2, 3]], [0.8, 2.2, [0]], [1.6, 3.0, [1]], [2.4, 3.0, [4, 5]], [4.0, 5.0, [0, 2, 3]]],
		"camera": WIDE_HERC_CAMERA},
	"fx_tribes": {"kind": "duel", "seconds": 6.5, "herc": "es1:ROADRUNN", "settle": 0.8,
		"config": {"mode": "vs", "map": "tribes:Raindance", "respawn": false, "start": "on_foot", "infantry_bots": 0},
		"armor": "tribes:HEAVY",
		"loadout": ["tribes:DISC_LAUNCHER", "tribes:CHAINGUN", "tribes:PLASMA_GUN", "tribes:MORTAR", "tribes:GRENADE_LAUNCHER"],
		"ai": [{"vehicle": "starsiege:cy_goad", "team": 1, "skill": 0.4}],
		"stage": [[35, 0]], "stage_allies": [[-30, -25]], "advance": [60, 0], "target_shield": 0.3, "kill_at": 5.0,
		"death_fx": [["mortarExp", "tribes", 0.0, [0, 4, 0]], ["debrisExpLarge", "tribes", 0.3, [0, 2, 0]]],
		"fire": [[0.0, 1.2, [0]], [1.2, 2.4, [1]], [2.4, 3.4, [2]], [3.4, 4.6, [3]], [4.6, 5.4, [0]]],
		"camera": SOLDIER_CAMERA},
	"fx_tribes2": {"kind": "duel", "seconds": 6.5, "herc": "es1:ROADRUNN", "settle": 0.8,
		"config": {"mode": "vs", "map": "tribes2:Katabatic", "respawn": false, "start": "on_foot", "infantry_bots": 0},
		"armor": "tribes2:HEAVY",
		"loadout": ["tribes2:MORTAR", "tribes2:GRENADE_LAUNCHER", "tribes2:SPINFUSOR", "tribes2:ELF_PROJECTOR", "tribes2:CHAINGUN"],
		"ai": [{"vehicle": "starsiege:cy_goad", "team": 1, "skill": 0.4}],
		"stage": [[35, 0]], "stage_allies": [[-30, -25]], "target_shield": 0.3, "kill_at": 5.0,
		"death_fx": [["MortarExplosion", "tribes2", 0.0, [0, 4, 0]], ["GrenadeExplosion", "tribes2", 0.3, [2, 3, 1]]],
		"slowmo": [[4.95, 5.9, 0.5]],
		"fire": [[0.0, 1.3, [0]], [1.3, 2.4, [1]], [2.4, 3.4, [2]], [3.4, 4.4, [3]], [4.4, 5.4, [4]]],
		"camera": SOLDIER_CAMERA},
}
