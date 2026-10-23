class_name HercSnapshots
extends RefCounted
## Network puppet state of a Herc on a client: the two latest server snapshots of its pose and
## the interpolation between them, plus the compact encodings of its weapon triggers and damage.
## Snapshot layout: see Herc.snapshot() (SNAP_* indices; SNAP_DAMAGE is appended by BattleNetSync).

const SNAP_POS := 1
const SNAP_YAW := 2
const SNAP_TORSO := 3
const SNAP_PITCH := 4
## Weapon trigger bits (bit i = weapon i pulled): puppets show the other pilots' fire state.
const SNAP_TRIGGERS := 13
## Damage block (make_damage_block), or empty when unchanged (BattleNetSync sends it only around changes).
const SNAP_DAMAGE := 14
## Index 15 is a soldier's extra state (Infantry.SNAP_INFANTRY; null for vehicles). Then the pilot's missile
## steering stick (MissileSteering.stick, Vector2): other peers' copies of a steered EO missile follow it.
const SNAP_MISSILE_STEER := 16
## Then whether the unit is cloaked in effect (CloakState.make_flag).
const SNAP_CLOAK := 17
## Interval assumed until the second snapshot arrives.
const DEFAULT_INTERVAL := 0.05
const MIN_INTERVAL := 0.001
## Component health is sent as one byte (0 = destroyed, 1..255 = alive).
const HEALTH_STEPS := 255.0

var _from := {}
var _to := {}
var _t := 0.0


static func _pose(s: Array) -> Dictionary:
	return {"pos": s[SNAP_POS], "yaw": s[SNAP_YAW], "torso": s[SNAP_TORSO], "pitch": s[SNAP_PITCH],
		"dt": DEFAULT_INTERVAL}


func is_empty() -> bool:
	return _to.is_empty()


## A new snapshot `dt` seconds after the previous one: interpolation restarts from the last target.
func push(s: Array, dt: float) -> void:
	_from = _to if not _to.is_empty() else _pose(s)
	_to = _pose(s)
	_to["dt"] = maxf(dt, MIN_INTERVAL)
	_t = 0.0


## Jumps to the latest snapshot (respawn).
func snap_to_latest() -> void:
	_from = _to


## Advances by delta and returns the interpolated pose {pos, yaw, torso, pitch}.
func advance(delta: float) -> Dictionary:
	_t += delta
	var f := clampf(_t / float(_to.dt), 0.0, 1.0)
	return {"pos": (_from.pos as Vector3).lerp(_to.pos, f),
		"yaw": lerp_angle(float(_from.yaw), float(_to.yaw), f),
		"torso": lerp_angle(float(_from.torso), float(_to.torso), f),
		"pitch": lerpf(float(_from.pitch), float(_to.pitch), f)}


# ------------------------------------------------------------------ triggers

## Bit i set = weapon i's trigger is pulled.
static func make_trigger_bits(h: Herc) -> int:
	var bits := 0
	for i in h.weapons.size():
		if h.weapons[i].trigger:
			bits |= 1 << i
	return bits


static func apply_trigger_bits(h: Herc, bits: int) -> void:
	for i in h.weapons.size():
		h.weapons[i].trigger = (bits >> i) & 1 == 1


# ------------------------------------------------------------------ damage

## Per-component health bytes followed by per-cell state bytes (about 30 bytes for a Herc).
static func make_damage_block(h: Herc) -> PackedByteArray:
	var n := h.components.size()
	var cells := h.shape.cell_count() if h.shape != null else 0
	var out := PackedByteArray()
	out.resize(n + cells)
	for i in n:
		out[i] = int(ceilf(DamageLevels.component_health(h.components[i]) * HEALTH_STEPS))
	for ci in cells:
		out[n + ci] = h.shape.get_cell_state(ci)
	return out


## Applies a damage block to a puppet: component health (a component destroyed since the last block plays its
## explosion), integrity and the shape's cell states.
static func apply_damage_block(h: Herc, block: PackedByteArray) -> void:
	var n := h.components.size()
	if block.size() < n:
		push_error("damage block of %d bytes for %d components" % [block.size(), n])
		return
	h.begin_damage_application()
	for i in n:
		var c: Dictionary = h.components[i]
		var was_alive := float(c.hp) > 0.0
		c.hp = float(c.max) * block[i] / HEALTH_STEPS
		if was_alive and c.hp <= 0.0:
			h.play_component_destroyed(i)
	h.integrity = HercDamage.integrity_of(h.components)
	if h.shape == null:
		return
	for ci in mini(h.shape.cell_count(), block.size() - n):
		if h.shape.get_cell_state(ci) != block[n + ci]:
			h.shape.set_cell_state(ci, block[n + ci])
