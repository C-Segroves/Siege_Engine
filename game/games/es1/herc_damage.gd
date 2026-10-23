class_name HercDamage
extends RefCounted
## The Herc damage model's rules (original: front/rear shield banks, components with hit points):
## which component a hit wounds, the leg-damage speed cap, the integrity summary and the death test.
## Component record: {name, hp, max, fatal, parent, big_explosion (3Space DMG flag 4: its destruction is the
## big death blast), shape_part (3Space: the cell slot shown damaged when it breaks; absent for other games)}.

## Leg component names contain one of these (quadriceps, shin, foot).
const LEG_PARTS := ["QUAD", "SHIN", "FOOT"]
## Leg damage caps the speed (original speed factors out of 1024): destroyed leg / leg below half.
const LEG_DESTROYED_SPEED := 400.0 / 1024.0
const LEG_DAMAGED_SPEED := 750.0 / 1024.0
## Hits above this height (metres, Herc frame) are "high": legs are unlikely, and vice versa.
const HIGH_HIT_Y := 5.0
const HIGH_HIT_LEG_WEIGHT := 0.2
const LOW_HIT_BODY_WEIGHT := 0.4
## A Herc whose integrity falls below this is destroyed.
const DEATH_INTEGRITY := 0.15
## Chance per damage cell to show the damaged state when a component of a unit without shape parts is destroyed.
const CELL_DAMAGE_CHANCE := 0.3
## Cell state of a damaged part (3Space: 0 intact, 1 damaged, 2 destroyed placeholder).
const DAMAGED_CELL_STATE := 1
## DMG shape_part of a component with no part of its own (brackets, crotch, placeholder rows).
const NO_SHAPE_PART := -1
const DEFAULT_HULL_HP := 6000.0
## 3Space DMG rows a unit does not use (the rear legs 13..18 of a biped) keep 1 hit point
## (docs/formats/gameplay.md section 5); they are named by index but are not real parts.
const PLACEHOLDER_HP := 1.0


## Mission pre-damage (ES1 DBSIM 0x12f20 / 0x13078, ES2 0x4178e8 / 0x417a04; docs/formats/gameplay.md section 5):
## record health -> damage level: 80+ (or below 0) none, 60-79 50, 40-59 80, 20-39 120, under 20 150.
const START_LEVELS := [[80, 0], [60, 50], [40, 80], [20, 120], [0, 150]]
const START_LEG_LOSS_HEALTH := 20
## 0x7d00: the blown-off quad's damage.
const START_LEG_DAMAGE := 32000.0
## rand & 0xff against level + 25; damage share in 1/256.
const START_DAMAGE_ROLL := 256
const START_DAMAGE_CHANCE_BONUS := 25
## DMG rows: front quads 7 / 8, rear quads 13 / 14 (four-legged units; DAT 0x48 leg count > 2).
const FRONT_QUADS := [7, 8]
const REAR_QUADS := [13, 14]


## The pre-damage level of record health `health` (0 = undamaged).
static func make_start_level(health: int) -> int:
	if health < 0:
		return 0
	for row in START_LEVELS:
		if health >= int(row[0]):
			return int(row[1])
	return 0


## The quad pairs one of which is blown off below START_LEG_LOSS_HEALTH: always the front quads, and the rear quads
## when the unit has real rear legs (the remake's stand-in for DAT 0x48 leg count > 2).
static func make_start_lost_legs(components: Array) -> Array:
	var out := []
	if FRONT_QUADS[1] < components.size():
		out.append(FRONT_QUADS)
	if REAR_QUADS[1] < components.size() and float(components[REAR_QUADS[0]].max) > PLACEHOLDER_HP:
		out.append(REAR_QUADS)
	return out


## True for a real leg part (its name names a leg; 3Space placeholder rows excluded).
static func is_leg(c: Dictionary) -> bool:
	if float(c.get("max", c.get("hp", 0.0))) <= PLACEHOLDER_HP:
		return false
	var n: String = c.name
	for part in LEG_PARTS:
		if n.contains(part):
			return true
	return false


## Components of a vehicle definition (a single fatal hull when it lists none).
static func make_components(vdef: Dictionary) -> Array:
	var out := []
	var points: Array = vdef.get("component_points", [])
	for c in vdef.get("damage", {}).get("components", []):
		var comp := {"name": c.get("name", ""), "hp": float(c.hp), "max": float(c.hp),
			"fatal": c.get("fatal", false), "parent": int(c.get("parent", -1)),
			"big_explosion": bool(c.get("big_explosion", false))}
		if c.has("shape_part"):
			comp["shape_part"] = int(c.shape_part)
		if not points.is_empty():
			comp["hittable"] = _has_point(points, out.size())
		out.append(comp)
	if out.is_empty():
		out.append({"name": "HULL", "hp": DEFAULT_HULL_HP, "max": DEFAULT_HULL_HP, "fatal": true, "parent": -1})
	return out


## True when component `i` has collision spheres (COL; catalog "component_points"): a shot can strike it.
## 3Space placeholder rows and the weapon rows have none here (DBSIM 0x9064 picks the struck component from the COL
## spheres only), so a hit never lands on them and wastes itself on a 1 hp stub.
static func _has_point(points: Array, i: int) -> bool:
	return i < points.size() and not (points[i] as Array).is_empty()


static func leg_speed_factor(components: Array) -> float:
	var worst := 1.0
	for c in components:
		if is_leg(c):
			var f: float = c.hp / maxf(c.max, 1.0)
			if f <= 0.0:
				worst = minf(worst, LEG_DESTROYED_SPEED)
			elif f < 0.5:
				worst = minf(worst, LEG_DAMAGED_SPEED)
	return worst


## Random living component for a hit at `local_hit` (high hits favour the body, low hits the legs);
## -1 if every component is destroyed.
static func pick_component(components: Array, local_hit: Vector3) -> int:
	var high := local_hit.y > HIGH_HIT_Y
	var candidates := []
	var total := 0.0
	for i in components.size():
		var c: Dictionary = components[i]
		if c.hp <= 0.0 or not bool(c.get("hittable", true)):
			continue
		var w := 1.0
		if high and is_leg(c):
			w = HIGH_HIT_LEG_WEIGHT
		elif not high and not is_leg(c):
			w = LOW_HIT_BODY_WEIGHT
		candidates.append([i, w])
		total += w
	if candidates.is_empty():
		return -1
	var r := randf() * total
	for c in candidates:
		r -= c[1]
		if r <= 0.0:
			return c[0]
	return candidates[0][0]


static func integrity_of(components: Array) -> float:
	var sum := 0.0
	var mx := 0.0
	for c in components:
		sum += c.hp
		mx += c.max
	return sum / maxf(mx, 1.0)


## True when a standing component is hurt: field repair mends those (a component at 0 is a lost part).
static func needs_repair(components: Array) -> bool:
	for c in components:
		if c.hp > 0.0 and c.hp < c.max:
			return true
	return false


## Heals the hurt standing components in order with `amount` points (a lost part is not brought back); returns the
## integrity afterwards.
static func apply_repair(components: Array, amount: float) -> float:
	var left := amount
	for c in components:
		if left <= 0.0:
			break
		if c.hp > 0.0 and c.hp < c.max:
			var given := minf(left, float(c.max) - float(c.hp))
			c.hp += given
			left -= given
	return integrity_of(components)


## Destroyed: a fatal top-level component is gone or the integrity is too low.
static func is_destroyed(components: Array, integrity: float) -> bool:
	for c in components:
		if c.fatal and c.hp <= 0.0 and c.parent < 0:
			return true
	return integrity < DEATH_INTEGRITY
