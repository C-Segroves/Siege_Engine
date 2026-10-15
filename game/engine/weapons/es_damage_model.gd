class_name EsDamageModel
extends DamageModel
## Earthsiege 1 / 2 hit pipeline (Mech::onHit 0x13b44, docs/formats/gameplay.md section 5; ES2 the same rows):
## - the bank on the attacker's side absorbs the shield damage; while an EMP holds the shields down nothing is
##   absorbed;
## - the COL spheres pick the struck component (0x9064): the component whose sphere is nearest the hit point;
## - splash S = A x splash/1024 goes to the unit's components within the splash radius (0x13a7c: each existing
##   component, chance 0x802/0x1000, takes S x (r - d) / r, d = hit point to its sphere), A - S to the struck one;
## - an EMP hit switches both banks off for the game's shield-down time (ES1 BND emp_shield_down_time 6000 timer
##   units, ES2 the weapon's 6000 units = 2.93 s; 0x13c39 / 0x418c4a).
## - a hit fired by an AI unit is scaled by the mission mode / difficulty (0x1f82c, called from 0x13bcb for the armour
##   and shield damage when the attacker is not a human pilot).
## Not modelled yet (noted in docs/STANDARDIZATION_AUDIT.md): overflow into the linked systems, weapon-component
## knock-out.

## 0x13acd: a component in the splash takes damage with chance 0x802 / 0x1000.
const SPLASH_CHANCE := float(0x802) / float(0x1000)
## The in-unit splash radius when a weapon names none (500 original units, 0x13a7c).
const DEFAULT_SPLASH_UNITS := 500.0

## 0x922c4 (fixmul 10 bits): AI damage factor per difficulty 0..3; a campaign mission always uses entry 3.
const AI_DAMAGE_TABLE := [2800, 2000, 1400, 1000]
const AI_DAMAGE_CAMPAIGN_ENTRY := 3

## The running Earthsiege 1 mission's AI damage factor (MissionRuntime sets it; 1.0 outside a mission).
static var ai_damage_scale := 1.0

var pack := ""
var _shield_down_s := -1.0


func _init(p_pack: String) -> void:
	pack = p_pack


## 0x1f82c: table[difficulty] / 1024 in a single mission, table[3] / 1024 in a campaign (header: mode, difficulty).
static func make_ai_damage_scale(header: Dictionary) -> float:
	var entry := AI_DAMAGE_CAMPAIGN_ENTRY if str(header.get("mode", "single")) == "campaign" 		else clampi(int(header.get("difficulty", AI_DAMAGE_CAMPAIGN_ENTRY)), 0, AI_DAMAGE_TABLE.size() - 1)
	return float(AI_DAMAGE_TABLE[entry]) / 1024.0


## 0x13bbb: the attacker's damage scale (an AI-piloted unit only; players and unattributed hits are not scaled).
func make_hit_scaled(hit: Dictionary) -> Dictionary:
	var a = hit.get("attacker")
	if pack != "es1" or ai_damage_scale == 1.0 or not (a is Herc) or a.is_local_player() or a.is_puppet 			or not a.has_meta("group"):   # BattleSpawner marks every mission AI unit with its group
		return hit
	var out := hit.duplicate()
	out.shield = float(hit.shield) * ai_damage_scale
	out.armor = float(hit.armor) * ai_damage_scale
	return out


func make_shield_through(h: Herc, hit: Dictionary) -> float:
	if h.shields_down_s > 0.0:
		return 1.0
	return super.make_shield_through(h, hit)


func apply_armor(h: Herc, hit: Dictionary, amount: float) -> void:
	var pos: Vector3 = hit.pos
	var pick := pick_component(h, pos)
	if pick < 0:
		return
	var wdef: Dictionary = hit.get("weapon", {})
	var splash := amount * float(wdef.get("splash", 0.0))
	h.wound_component(pick, amount - splash)
	if splash > 0.0:
		apply_splash(h, pos, splash, make_splash_radius(wdef), pick)


## The struck component: the living hittable one whose COL sphere is nearest `pos` (the generic height pick for a
## unit without spheres).
func pick_component(h: Herc, pos: Vector3) -> int:
	var points: Array = h.def.get("component_points", [])
	var best := -1
	var best_d := INF
	for i in h.components.size():
		var c: Dictionary = h.components[i]
		if c.hp <= 0.0 or not bool(c.get("hittable", true)) or i >= points.size() or (points[i] as Array).is_empty():
			continue
		var d := pos.distance_squared_to(h.make_component_position(i))
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		return best
	return HercDamage.pick_component(h.components, h.global_transform.affine_inverse() * pos)


## 0x13a7c: `amount` spread from `pos` over `h`'s other living components within `radius` metres (Blast).
func apply_splash(h: Herc, pos: Vector3, amount: float, radius: float, struck: int) -> void:
	for hit in Blast.make_component_hits(h, pos, {"amount": amount, "radius": radius, "chance": SPLASH_CHANCE,
			"skip_index": struck}):
		h.wound_component(int(hit[0]), float(hit[1]))


static func make_splash_radius(wdef: Dictionary) -> float:
	var r := float(wdef.get("splash_radius", 0.0)) if wdef.get("splash_radius") != null else 0.0
	return r if r > 0.0 else DEFAULT_SPLASH_UNITS * Assets.UNIT


## Both banks off for the shield-down time (the drain is the whole bank, as the original zeroes them).
func apply_emp(h: Herc, _drain: float, fx: Dictionary) -> void:
	h.shield_front = 0.0
	h.shield_rear = 0.0
	var down := float(fx.get("disable_seconds", 0.0))
	h.shields_down_s = maxf(h.shields_down_s, down if down > 0.0 else make_shield_down_seconds())


## The game's EMP shield-down time from its imported tables (ES1: BND emp_shield_down_time x timer seconds).
func make_shield_down_seconds() -> float:
	if _shield_down_s < 0.0:
		var bnd = Assets.load_json("gameplay/bnd.json", pack)
		var units = Assets.load_json("units.json", pack)
		var ticks := 0.0
		if bnd is Dictionary:
			ticks = float(bnd.get("SIMVOL0", {}).get("MECH", {}).get("named", {}).get("emp_shield_down_time", {}).get("value", 0.0))
		var per_tick := float(units.get("timers", {}).get("to_seconds", 0.0)) if units is Dictionary else 0.0
		_shield_down_s = ticks * per_tick
	return _shield_down_s
