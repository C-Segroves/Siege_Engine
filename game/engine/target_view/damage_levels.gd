class_name DamageLevels
extends RefCounted
## The original Earthsiege damage colour scheme of the cockpit damage diagrams (docs/formats/cockpit.md
## section 4.1), shared by every target / damage readout so all games show damage the same way.
##
## DBSIM 0x30dc4: health % = (256 - damage) * 100 >> 8 with damage = accumulated * 256 / hp
## (0x109bc; 256 when destroyed); >= 90 % green, >= 74 % yellow, >= 51 % orange, >= 1 % red, else
## destroyed (dark grey). Each level is a 3-shade ramp of COCKPIT.DPL starting at RAMP_BASES[level].

const INTACT := 0
const LIGHT := 1
const MEDIUM := 2
const HEAVY := 3
const DESTROYED := 4
const LEVEL_COUNT := 5
## Lowest health % of levels INTACT, LIGHT, MEDIUM, HEAVY (DBSIM 0x30df1: 0x5a, 0x4a, 0x33, 1).
const MIN_PERCENT := [90, 74, 51, 1]
## COCKPIT.DPL ramp bases (DBSIM 0x30df6..0x30e38: 0x36, 0x39, 0x5c, 0x33, 0x3e); shade k = base + k,
## k = 2 brightest.
const RAMP_BASES := [0x36, 0x39, 0x5c, 0x33, 0x3e]
const SHADES := 3
const DAMAGE_SCALE := 256
## Middle shade of each ramp in the ES1 COCKPIT.DPL (palette entries 0x37, 0x3a, 0x5d, 0x34, 0x3f):
## the full-colour readouts (plain HUD) use these without the cockpit palette.
const COLORS := [Color8(12, 97, 12), Color8(134, 134, 36), Color8(182, 85, 12), Color8(117, 8, 0), Color8(69, 69, 69)]


## Damage level (INTACT..DESTROYED) of a part with `health` (0..1) left, by the original's integer rule.
static func level_of(health: float) -> int:
	var damage := DAMAGE_SCALE - int(ceilf(clampf(health, 0.0, 1.0) * DAMAGE_SCALE))
	var percent := ((DAMAGE_SCALE - damage) * 100) >> 8
	for level in MIN_PERCENT.size():
		if percent >= MIN_PERCENT[level]:
			return level
	return DESTROYED


## Health (0..1) of component `c` ({hp, max}).
static func component_health(c: Dictionary) -> float:
	return clampf(float(c.hp) / maxf(float(c.max), 1.0), 0.0, 1.0)


## Lowest health of the listed components of `components` (1.0 when the list names none of them).
static func worst_health(components: Array, indices: Array) -> float:
	var worst := 1.0
	for i in indices:
		if int(i) >= 0 and int(i) < components.size():
			worst = minf(worst, component_health(components[int(i)]))
	return worst


## Mean health of the listed components (the original averages a diagram region's components).
static func mean_health(components: Array, indices: Array) -> float:
	var sum := 0.0
	var n := 0
	for i in indices:
		if int(i) >= 0 and int(i) < components.size():
			sum += component_health(components[int(i)])
			n += 1
	return sum / n if n > 0 else 1.0
