class_name SiegeWaves
extends RefCounted
## The escalating waves of the siege, from the rules (cybrid_siege.waves): what wave `n` brings and when it arrives.
## The waves are SpawnWaves of a WaveDirector, all listening to the trigger "siege_start", wave n arriving at
## make_arrival(n); the unit counts below are the wave's `count` (its number) turned into a composition.

const TRIGGER_START := "siege_start"
const GROUP := "siege"


static func rules() -> Dictionary:
	return CybridRules.section("waves")


## Seconds after the siege starts that wave `n` (1-based) arrives: the first at first_s, then gaps shrinking from
## interval_s[0] by interval_decay each wave down to interval_s[1].
static func make_arrival(n: int) -> float:
	var r := rules()
	var pair: Array = r.get("interval_s", [40.0, 14.0])
	var t := float(r.get("first_s", 12.0))
	var gap := float(pair[0])
	for i in range(1, n):
		t += gap
		gap = maxf(gap * float(r.get("interval_decay", 0.94)), float(pair[1]))
	return t


## {infantry, hercs, flyers}: the unit counts of wave `n`.
static func make_composition(n: int) -> Dictionary:
	var r := rules()
	return {"infantry": _make_count(r.get("infantry", {}), n), "hercs": _make_count(r.get("hercs", {}), n),
		"flyers": _make_count(r.get("flyers", {}), n)}


static func _make_count(kind: Dictionary, n: int) -> int:
	var from := int(kind.get("from_wave", 1))
	if n < from:
		return 0
	return mini(roundi(float(kind.get("base", 0)) + float(kind.get("per_wave", 0.0)) * float(n - from)), int(kind.get("cap", 999)))


## The armour size of the k-th soldier of a wave: every heavy_every-th heavy, every medium_every-th medium.
static func make_size(k: int, infantry_rules: Dictionary) -> String:
	var heavy := int(infantry_rules.get("heavy_every", 0))
	var medium := int(infantry_rules.get("medium_every", 0))
	if heavy > 0 and k % heavy == heavy - 1:
		return "HEAVY"
	if medium > 0 and k % medium == medium - 1:
		return "MEDIUM"
	return "LIGHT"


## Adds every wave of the rules to `director` (trigger "siege_start", count = its number, arrival as above).
static func apply_to(director: WaveDirector) -> void:
	for n in range(1, int(rules().get("max_waves", 60)) + 1):
		director.apply_add(SpawnWave.make_wave(GROUP, TRIGGER_START, n, make_arrival(n)))
