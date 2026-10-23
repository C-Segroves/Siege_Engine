class_name ScriptedDamage
extends RefCounted
## Damage a mission script deals (Tribes damage_level / applyDamage / calcRadiusDamage, Starsiege damageObject /
## damageArea, Aerial Assault DestroyItem, the Vengeance script damage): each game's script call becomes one of these
## and reaches the target as a `DamageEvent`, so a death by the mission reads "destroyed by the mission" and credits nobody.


## `amount` armour points on `target`, no attacker (KillText.CAUSE_SCRIPTED).
static func apply(target: Object, amount: float) -> void:
	if target == null or not target.has_method("apply_hit"):
		return
	var at: Vector3 = (target as Node3D).global_position if target is Node3D else Vector3.ZERO
	KillText.apply_caused_hit(target, [0.0, amount, null, at], KillText.CAUSE_SCRIPTED)


## A scripted destruction of a base object or structure: lethal whatever its shield or scale.
static func apply_lethal(target: Object) -> void:
	if target != null and target.has_method("apply_damage_event"):
		target.apply_damage_event(DamageEvent.make_lethal())


## `amount` on each node of `nodes` within `radius` of `center`; with `linear_falloff` the damage fades with the distance
## (Starsiege damageArea, a remake approximation), else every node in reach takes all of it (Tribes calcRadiusDamage).
## `applier` (node, amount) lands the damage; empty: `apply`.
static func apply_area(nodes: Array, center: Vector3, radius: float, amount: float, linear_falloff: bool, applier := Callable()) -> void:
	var hit: Array = []
	for n in nodes:
		if n is Node3D and is_instance_valid(n) and n.has_method("apply_hit") and n.global_position.distance_to(center) <= radius:
			hit.append(n)
	for n in hit:
		var share := 1.0
		if linear_falloff:
			share = clampf(1.0 - n.global_position.distance_to(center) / maxf(radius, 1.0), 0.0, 1.0)
		if applier.is_valid():
			applier.call(n, amount * share)
		else:
			apply(n, amount * share)


## Starsiege scripted damage on a Herc: spread over all components in proportion to their hit points (a heavy hit
## wounds, only damage >= the total destroys), then the engine's death check.
static func apply_spread(h: Herc, amount: float) -> void:
	var total := 0.0
	for c in h.components:
		total += float(c.hp)
	if total <= 0.0:
		return
	var f := clampf(amount / total, 0.0, 1.0)
	var mx := 0.0
	var sum := 0.0
	for c in h.components:
		c.hp = 0.0 if f >= 1.0 else float(c.hp) * (1.0 - f)
		sum += float(c.hp)
		mx += float(c.max)
	h.integrity = sum / maxf(mx, 1.0)
	KillText.apply_caused_hit(h, [0.0, 0.0, null, h.global_position], KillText.CAUSE_SCRIPTED)


## `share` (0..1) of a unit's full health (Vengeance script damage).
static func apply_share(target: Object, share: float) -> void:
	if target != null and target.has_method("apply_environment_damage"):
		target.apply_environment_damage(clampf(share, 0.0, 1.0))


## How hurt `h` is: 0 unhurt, 1 destroyed (Tribes getDamageLevel as a share of its health).
static func make_level(h: Herc) -> float:
	return 1.0 - h.integrity if h != null else 0.0


## Sets a unit's health so it has `level` (0..1) damage (Tribes setDamageLevel).
static func apply_level(h: Herc, level: float) -> void:
	var c: Dictionary = h.components[0]
	c.hp = float(c.max) * clampf(1.0 - level, 0.0, 1.0)
	h.integrity = HercDamage.integrity_of(h.components)
